const std = @import("std");
const Io = std.Io;

const config = @import("config.zig");
const debug = @import("debug.zig");
const extract = @import("extract.zig");
const index = @import("index.zig");
const lock = @import("lock.zig");
const minisign = @import("minisign.zig");
const net = @import("net.zig");
const retry = @import("retry.zig");

const Config = config.Config;
const Paths = @import("paths.zig").Paths;

const download = @import("download.zig").download;
const fetchMirrors = @import("mirrors.zig").fetchMirrors;
const findMinimumZigVersion = @import("zon_scan.zig").findMinimumZigVersion;
const mirrorUrl = @import("mirrors.zig").mirrorUrl;
const validateVersion = @import("version.zig").validate;

//

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: Io,
    paths: Paths,
    skip_verification: bool = false,
};

pub const Source = enum {
    override,
    project,
    default,
    recent,
};

pub const Resolution = struct {
    version: []const u8,
    source: Source,
    project_file: ?[]const u8 = null,
};

pub const InstallResult = struct {
    version: []const u8,
    /// `false` when an interactive user explicitly accepts a download for which
    /// neither the official index nor a Minisign signature was available.
    verified: bool,
    /// `true` when this version was already cached and nothing was downloaded.
    already_installed: bool,
};

pub const UseResult = struct {
    install: InstallResult,
    version_lock: lock.Held,
};

/// Version resolution order: explicit override > nearest build.zig.zon
/// (walking up from cwd) > configured default > most recently used
/// installed version > error.
pub fn resolveVersion(ctx: *Context, override: ?[]const u8) !Resolution {
    var project: ?ProjectVersion = null;
    var cfg = Config{};
    if (override == null) {
        project = try findProjectVersion(ctx);
        cfg = config.load(ctx.gpa, ctx.io, ctx.paths.config_file) catch Config{};
    }

    const resolution = try resolutionFromSources(override, project, cfg);
    switch (resolution.source) {
        .override => debug.log("version source: override ({s})", .{resolution.version}),
        .project => debug.log(
            "version source: project {s} ({s})",
            .{ resolution.version, resolution.project_file.? },
        ),
        .default => debug.log("version source: configured default ({s})", .{resolution.version}),
        .recent => debug.log("version source: most recently used ({s})", .{resolution.version}),
    }

    return resolution;
}

fn resolutionFromSources(
    override: ?[]const u8,
    project: ?ProjectVersion,
    cfg: Config,
) !Resolution {
    if (override) |version| {
        try validateVersion(version);

        return .{
            .version = version,
            .source = .override,
        };
    }

    if (project) |found| {
        try validateVersion(found.version);

        return .{
            .version = found.version,
            .source = .project,
            .project_file = found.path,
        };
    }

    if (cfg.default_version) |version| {
        try validateVersion(version);

        return .{
            .version = version,
            .source = .default,
        };
    }
    if (cfg.last_used_version) |version| {
        try validateVersion(version);

        return .{
            .version = version,
            .source = .recent,
        };
    }

    return error.NoVersionFound;
}

pub fn recordUse(ctx: *Context, version: []const u8) void {
    config.recordUse(ctx.gpa, ctx.io, ctx.paths, version) catch {};
}

const ProjectVersion = struct {
    version: []const u8,
    path: []const u8,
};

fn findProjectVersion(ctx: *Context) !?ProjectVersion {
    return findProjectVersionFrom(
        ctx.gpa,
        ctx.io,
        try Io.Dir.cwd().openDir(ctx.io, ".", .{}),
    );
}

fn findProjectVersionFrom(
    gpa: std.mem.Allocator,
    io: Io,
    initial_dir: Io.Dir,
) !?ProjectVersion {
    var dir = initial_dir;
    defer dir.close(io);

    var depth: usize = 0;
    while (depth < 128) : (depth += 1) {
        const text = dir.readFileAllocOptions(
            io,
            "build.zig.zon",
            gpa,
            .limited(1 << 20),
            .of(u8),
            0,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const parent = dir.openDir(io, "..", .{}) catch
                    return null;
                dir.close(io);
                dir = parent;

                continue;
            },
            else => return err,
        };

        if (findMinimumZigVersion(text)) |v| {
            const path = displayPath(gpa, io, dir);

            return .{
                .version = v,
                .path = path,
            };
        }

        return null;
    }

    return null;
}

fn displayPath(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) []const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buf) catch
        return "build.zig.zon";

    return std.fs.path.join(gpa, &.{ buf[0..n], "build.zig.zon" }) catch "build.zig.zon";
}

pub fn ensureInstalled(
    ctx: *Context,
    requested_version: []const u8,
    progress: std.Progress.Node,
) !InstallResult {
    const result = try ensureInstalledInner(
        ctx,
        requested_version,
        progress,
        false,
    );

    return result.install;
}

pub fn ensureInstalledForUse(
    ctx: *Context,
    requested_version: []const u8,
    progress: std.Progress.Node,
) !UseResult {
    const result = try ensureInstalledInner(
        ctx,
        requested_version,
        progress,
        true,
    );

    return .{
        .install = result.install,
        .version_lock = result.version_lock.?,
    };
}

const EnsureResult = struct {
    install: InstallResult,
    version_lock: ?lock.Held,
};

fn ensureInstalledInner(
    ctx: *Context,
    requested_version: []const u8,
    progress: std.Progress.Node,
    retain_lock: bool,
) !EnsureResult {
    try validateVersion(requested_version);
    const resolve_label = try std.fmt.allocPrint(
        ctx.gpa,
        "resolve zig {s}",
        .{requested_version},
    );
    const resolve_node = progress.start(resolve_label, 0);

    const resolved = index.resolve(
        ctx.gpa,
        ctx.io,
        ctx.paths,
        requested_version,
    ) catch |err| {
        resolve_node.end();

        return err;
    };

    const final_dir = try ctx.paths.versionDir(ctx.gpa, resolved.version);
    var version_lock: ?lock.Held = null;
    var install_lock: ?lock.Held = null;
    var holding_exclusive_lock = false;
    errdefer if (version_lock) |*held| held.release(ctx.io);
    defer if (install_lock) |*held| held.release(ctx.io);

    // Check for an existing installation while holding a shared lock.
    // If another process is installing this version, this waits for it and then
    // rechecks before requesting an exclusive install lock.
    version_lock = try lock.acquireShared(ctx.gpa, ctx.io, ctx.paths.locks, resolved.version);
    if (!isInstalled(ctx, final_dir)) {
        version_lock.?.release(ctx.io);
        version_lock = null;
    }

    if (version_lock == null) {
        // Only one process may change this version from absent to
        // installed. Once selected, recheck under the version lock because
        // another installer may have completed while we were waiting.
        const install_lock_name = try std.fmt.allocPrint(
            ctx.gpa,
            "{s}.install",
            .{resolved.version},
        );
        install_lock = try lock.acquire(ctx.gpa, ctx.io, ctx.paths.locks, install_lock_name);
        version_lock = try lock.acquireShared(ctx.gpa, ctx.io, ctx.paths.locks, resolved.version);

        if (!isInstalled(ctx, final_dir)) {
            version_lock.?.release(ctx.io);
            version_lock = null;
            version_lock = try lock.acquire(ctx.gpa, ctx.io, ctx.paths.locks, resolved.version);
            holding_exclusive_lock = true;
        }
    }

    // Another zvm instance may have installed this version while this one was
    // waiting for the lock.
    if (isInstalled(ctx, final_dir)) {
        debug.log("{s} already installed at {s}", .{ resolved.version, final_dir });

        resolve_node.end();

        if (retain_lock) {
            if (holding_exclusive_lock) {
                // The version was either installed while waiting for an
                // exclusive lock, or we installed it ourselves. Let other Zig
                // processes use it concurrently while still excluding `remove`.
                try version_lock.?.downgrade(ctx.io);
            }
        } else if (version_lock) |*held| {
            held.release(ctx.io);
            version_lock = null;
        }

        return .{
            .install = .{
                .version = resolved.version,
                .verified = ctx.skip_verification or resolved.shasum != null,
                .already_installed = true,
            },
            .version_lock = version_lock,
        };
    }

    const minisign_signature: ?[]const u8 = if (!ctx.skip_verification and resolved.shasum == null) blk: {
        const signature_url = try std.fmt.allocPrint(
            ctx.gpa,
            "{s}.minisig",
            .{resolved.tarball_url},
        );
        const signature = net.get(ctx.gpa, ctx.io, signature_url) catch {
            if (!confirmUnverified(ctx, resolved.version))
                return error.SignatureUnavailable;

            break :blk null;
        };
        if (signature.status != .ok) {
            if (!confirmUnverified(ctx, resolved.version))
                return error.SignatureUnavailable;

            break :blk null;
        }

        break :blk signature.body;
    } else null;
    const verified = ctx.skip_verification or resolved.shasum != null or minisign_signature != null;

    const install_tmp = try std.fs.path.join(ctx.gpa, &.{ ctx.paths.tmp, resolved.version });
    const scratch = try std.fs.path.join(ctx.gpa, &.{ install_tmp, "extract" });
    const archive_name = urlBasename(resolved.tarball_url);
    const archive_path = try std.fs.path.join(ctx.gpa, &.{ install_tmp, archive_name });
    try Io.Dir.cwd().createDirPath(ctx.io, install_tmp);
    errdefer retry.deleteTree(ctx.io, Io.Dir.cwd(), install_tmp) catch {};

    var urls: std.ArrayList([]const u8) = .empty;
    const mirror_list = fetchMirrors(ctx.gpa, ctx.io, ctx.paths);
    for (mirror_list) |m| {
        try urls.append(ctx.gpa, try mirrorUrl(ctx.gpa, m, archive_name));
    }
    try urls.append(ctx.gpa, resolved.tarball_url);

    debug.log(
        "{d} download source(s) for {s} ({d} mirror(s) + direct)",
        .{
            urls.items.len,
            resolved.version,
            mirror_list.len,
        },
    );

    resolve_node.end();

    const download_label = try std.fmt.allocPrint(ctx.gpa, "zig {s}", .{resolved.version});
    try download(
        ctx.gpa,
        ctx.io,
        urls.items,
        archive_path,
        if (ctx.skip_verification) null else resolved.shasum,
        minisign_signature,
        .zig,
        download_label,
        progress,
    );

    const extract_label = try std.fmt.allocPrint(ctx.gpa, "extract zig {s}", .{resolved.version});
    try extract.installFromArchive(
        ctx.gpa,
        ctx.io,
        archive_path,
        scratch,
        final_dir,
        extract_label,
        progress,
    );

    const cleanup_node = progress.start("cleaning up", 0);
    retry.deleteTree(ctx.io, Io.Dir.cwd(), install_tmp) catch {};
    cleanup_node.end();

    if (retain_lock) {
        try version_lock.?.downgrade(ctx.io);
    } else if (version_lock) |*held| {
        held.release(ctx.io);
        version_lock = null;
    }

    return .{
        .install = .{
            .version = resolved.version,
            .verified = verified,
            .already_installed = false,
        },
        .version_lock = version_lock,
    };
}

pub fn installErrorHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.VersionNotFound => "that version doesn't exist, or has been removed, this eventually happens to old, unlisted dev/master snapshots",
        error.SignatureUnavailable => "its Minisign signature could not be retrieved; refusing an unverified download without interactive confirmation",
        error.InvalidArchiveSignature, error.InvalidGlobalSignature => "the download did not match Zig's official Minisign signature",
        else => null,
    };
}

pub fn isInstalled(ctx: *Context, final_dir: []const u8) bool {
    Io.Dir.cwd().access(ctx.io, final_dir, .{}) catch
        return false;

    return true;
}

fn confirmUnverified(ctx: *Context, version: []const u8) bool {
    const stdin = Io.File.stdin();
    if (!(stdin.isTty(ctx.io) catch return false))
        return false;

    var stderr_buf: [1024]u8 = undefined;
    var stderr = Io.File.Writer.init(.stderr(), ctx.io, &stderr_buf);
    stderr.interface.print(
        \\zvm: Zig {s} has no checksum in the official index and its Minisign
        \\signature could not be retrieved. The downloaded compiler cannot be verified.
    , .{version}) catch
        return false;
    stderr.interface.print("Install it anyway? [y/n] ", .{}) catch
        return false;
    stderr.interface.flush() catch
        return false;

    var stdin_buf: [64]u8 = undefined;
    var reader = stdin.reader(ctx.io, &stdin_buf);
    const maybe_answer = reader.interface.takeDelimiter('\n') catch
        return false;
    const answer = maybe_answer orelse
        return false;
    return isAffirmative(answer);
}

fn isAffirmative(input: []const u8) bool {
    const answer = std.mem.trim(u8, input, " \t\r\n");

    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

pub fn urlBasename(url: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const path_part = url[0..q];
    const slash = std.mem.lastIndexOfScalar(u8, path_part, '/') orelse
        return path_part;

    return path_part[slash + 1 ..];
}

//

test "interactive confirmation accepts only y or yes" {
    const accepted = [_][]const u8{ "y", "Y", "yes", "YES", "  Yes\r\n" };
    for (accepted) |answer|
        try std.testing.expect(isAffirmative(answer));

    const rejected = [_][]const u8{ "", "n", "no", "yeah", "yeee" };
    for (rejected) |answer|
        try std.testing.expect(!isAffirmative(answer));
}

test "urlBasename removes query parameters from download URLs" {
    try std.testing.expectEqualStrings(
        "zig-x86_64-windows-0.16.0.zip",
        urlBasename("https://mirror.invalid/zig-x86_64-windows-0.16.0.zip?source=zvm"),
    );
    try std.testing.expectEqualStrings("archive.tar.xz", urlBasename("archive.tar.xz"));
}

test "resolutionFromSources follows the documented precedence" {
    const project = ProjectVersion{
        .version = "0.16.0",
        .path = "project/build.zig.zon",
    };
    const cfg = Config{
        .default_version = "0.15.2",
        .last_used_version = "0.14.1",
    };

    const override = try resolutionFromSources("0.17.0", project, cfg);
    try std.testing.expectEqual(.override, override.source);
    try std.testing.expectEqualStrings("0.17.0", override.version);

    const from_project = try resolutionFromSources(null, project, cfg);
    try std.testing.expectEqual(.project, from_project.source);
    try std.testing.expectEqualStrings("0.16.0", from_project.version);
    try std.testing.expectEqualStrings("project/build.zig.zon", from_project.project_file.?);

    const from_default = try resolutionFromSources(null, null, cfg);
    try std.testing.expectEqual(.default, from_default.source);
    try std.testing.expectEqualStrings("0.15.2", from_default.version);

    const from_recent = try resolutionFromSources(null, null, .{ .last_used_version = "0.14.1" });
    try std.testing.expectEqual(.recent, from_recent.source);
    try std.testing.expectEqualStrings("0.14.1", from_recent.version);

    try std.testing.expectError(error.NoVersionFound, resolutionFromSources(null, null, .{}));
}

test "findProjectVersionFrom searches parent directories" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.createDirPath(io, "project/src/deep");
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/build.zig.zon",
        .data = ".{ .minimum_zig_version = \"0.16.0\" }",
    });
    const nested_dir = try tmp.dir.openDir(io, "project/src/deep", .{});
    const found = (try findProjectVersionFrom(allocator, io, nested_dir)) orelse
        return error.TestExpectedEqual;

    try std.testing.expectEqualStrings("0.16.0", found.version);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const expected = try std.fs.path.join(allocator, &.{ path_buf[0..path_len], "project", "build.zig.zon" });
    try std.testing.expectEqualStrings(expected, found.path);
}

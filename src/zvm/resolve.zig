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

/// Version resolution order: explicit override > nearest build.zig.zon
/// (walking up from cwd) > configured default > most recently used
/// installed version > error.
pub fn resolveVersion(ctx: *Context, override: ?[]const u8) !Resolution {
    if (override) |o| {
        try validateVersion(o);

        debug.log("version source: override ({s})", .{o});

        return .{
            .version = o,
            .source = .override,
        };
    }

    if (try findProjectVersion(ctx)) |found| {
        try validateVersion(found.version);

        debug.log("version source: project {s} ({s})", .{ found.version, found.path });

        return .{
            .version = found.version,
            .source = .project,
            .project_file = found.path,
        };
    }

    const cfg = config.load(ctx.gpa, ctx.io, ctx.paths.config_file) catch Config{};
    if (cfg.default_version) |d| {
        try validateVersion(d);

        debug.log("version source: configured default ({s})", .{d});

        return .{
            .version = d,
            .source = .default,
        };
    }
    if (cfg.last_used_version) |r| {
        try validateVersion(r);

        debug.log("version source: most recently used ({s})", .{r});

        return .{
            .version = r,
            .source = .recent,
        };
    }

    return error.NoVersionFound;
}

pub fn recordUse(ctx: *Context, version: []const u8) void {
    var cfg = config.load(ctx.gpa, ctx.io, ctx.paths.config_file) catch Config{};
    cfg.last_used_version = version;
    config.save(ctx.gpa, ctx.io, ctx.paths.config_file, cfg) catch {};
}

const ProjectVersion = struct {
    version: []const u8,
    path: []const u8,
};

fn findProjectVersion(ctx: *Context) !?ProjectVersion {
    var dir = try Io.Dir.cwd().openDir(ctx.io, ".", .{});
    defer dir.close(ctx.io);

    var depth: usize = 0;
    while (depth < 128) : (depth += 1) {
        const text = dir.readFileAllocOptions(
            ctx.io,
            "build.zig.zon",
            ctx.gpa,
            .limited(1 << 20),
            .of(u8),
            0,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const parent = dir.openDir(ctx.io, "..", .{}) catch return null;
                dir.close(ctx.io);
                dir = parent;

                continue;
            },
            else => return err,
        };

        if (findMinimumZigVersion(text)) |v| {
            const path = displayPath(ctx, dir);

            return .{
                .version = v,
                .path = path,
            };
        }

        return null;
    }

    return null;
}

fn displayPath(ctx: *Context, dir: Io.Dir) []const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.realPath(ctx.io, &buf) catch return "build.zig.zon";

    return std.fs.path.join(ctx.gpa, &.{ buf[0..n], "build.zig.zon" }) catch "build.zig.zon";
}

pub fn ensureInstalled(ctx: *Context, requested_version: []const u8, progress: std.Progress.Node) !InstallResult {
    try validateVersion(requested_version);
    const resolve_label = try std.fmt.allocPrint(ctx.gpa, "resolve zig {s}", .{requested_version});
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
    if (isInstalled(ctx, final_dir)) {
        debug.log("{s} already installed at {s}", .{ resolved.version, final_dir });
        resolve_node.end();

        return .{
            .version = resolved.version,
            .verified = ctx.skip_verification or resolved.shasum != null,
            .already_installed = true,
        };
    }

    const minisign_signature: ?[]const u8 = if (!ctx.skip_verification and resolved.shasum == null) blk: {
        const signature_url = try std.fmt.allocPrint(ctx.gpa, "{s}.minisig", .{resolved.tarball_url});
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

    const scratch = try std.fs.path.join(ctx.gpa, &.{ ctx.paths.tmp, resolved.version });
    const archive_name = urlBasename(resolved.tarball_url);
    const archive_path = try std.fs.path.join(ctx.gpa, &.{ ctx.paths.tmp, archive_name });

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
    retry.deleteTree(ctx.io, Io.Dir.cwd(), ctx.paths.tmp) catch {};
    Io.Dir.cwd().createDirPath(ctx.io, ctx.paths.tmp) catch {};
    cleanup_node.end();

    return .{
        .version = resolved.version,
        .verified = verified,
        .already_installed = false,
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
    Io.Dir.cwd().access(ctx.io, final_dir, .{}) catch return false;

    return true;
}

fn confirmUnverified(ctx: *Context, version: []const u8) bool {
    const stdin = Io.File.stdin();
    if (!(stdin.isTty(ctx.io) catch return false)) return false;

    var stderr_buf: [1024]u8 = undefined;
    var stderr = Io.File.Writer.init(.stderr(), ctx.io, &stderr_buf);
    stderr.interface.print(
        \\zvm: Zig {s} has no checksum in the official index and its Minisign
        \\signature could not be retrieved. The downloaded compiler cannot be verified.
    , .{version}) catch
        return false;
    stderr.interface.print("Install it anyway? [y/n] ", .{}) catch
        return false;
    stderr.interface.flush() catch return false;

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

fn urlBasename(url: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const path_part = url[0..q];
    const slash = std.mem.lastIndexOfScalar(u8, path_part, '/') orelse return path_part;

    return path_part[slash + 1 ..];
}

//

const Config = config.Config;
const Paths = @import("paths.zig").Paths;

const download = @import("download.zig").download;
const fetchMirrors = @import("mirrors.zig").fetchMirrors;
const findMinimumZigVersion = @import("zon_scan.zig").findMinimumZigVersion;
const mirrorUrl = @import("mirrors.zig").mirrorUrl;
const validateVersion = @import("version.zig").validate;

//

const config = @import("config.zig");
const debug = @import("debug.zig");
const extract = @import("extract.zig");
const index = @import("index.zig");
const minisign = @import("minisign.zig");
const net = @import("net.zig");
const retry = @import("retry.zig");

const std = @import("std");
const Io = std.Io;

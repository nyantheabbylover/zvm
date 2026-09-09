//! ZLS (the Zig language server) release metadata and installation,
//! paired with the Zig version being installed.
//!
//! Release metadata comes from the zigtools release API, which maps a Zig
//! version to the matching ZLS build:
//! https://releases.zigtools.org/v1/zls/select-version?zig_version=<v>&compatibility=only-runtime

const std = @import("std");
const Io = std.Io;

const cached_fetch = @import("cached_fetch.zig");
const debug = @import("debug.zig");
const download = @import("download.zig").download;
const extract = @import("extract.zig");
const lock = @import("lock.zig");
const minisign = @import("minisign.zig");
const net = @import("net.zig");
const retry = @import("retry.zig");
const target = @import("target.zig");
const validateVersion = @import("version.zig").validate;

const Paths = @import("paths.zig").Paths;
const Context = @import("resolve.zig").Context;
const urlBasename = @import("resolve.zig").urlBasename;

const api_url = "https://releases.zigtools.org/v1/zls/select-version";
const ttl_seconds: i64 = 60 * 60;

pub const Resolved = struct {
    version: []const u8,
    tarball_url: []const u8,
    shasum: ?[]const u8,
    size: ?u64,
};

pub const InstallResult = struct {
    /// The Zig version this ZLS build was selected for.
    zig_version: []const u8,
    /// The actual ZLS release selected by the resolver. This is null when a
    /// previously installed ZLS was reused without querying the API.
    zls_version: ?[]const u8,
    /// `true` when this ZLS was already cached and nothing was downloaded.
    already_installed: bool,
};

/// Resolves the ZLS build matching `zig_version` via the zigtools release
/// API. The response is cached under `cache/zls-<version>.json`.
pub fn resolve(gpa: std.mem.Allocator, io: Io, paths: Paths, zig_version: []const u8) !Resolved {
    try validateVersion(zig_version);
    if (!target.zls_supported)
        return error.ZlsTargetUnsupported;

    const url = try apiUrl(gpa, zig_version);
    defer gpa.free(url);

    const cache_name = try std.fmt.allocPrint(gpa, "zls-{s}.json", .{zig_version});
    defer gpa.free(cache_name);
    const cache_path = try std.fs.path.join(gpa, &.{ paths.cache, cache_name });
    defer gpa.free(cache_path);
    // One path component: joined as separate components, Windows would parse
    // `zls-<v>.json\.meta` as a file inside a directory named `zls-<v>.json`.
    const meta_name = try std.fmt.allocPrint(gpa, "{s}.meta", .{cache_name});
    defer gpa.free(meta_name);
    const meta_path = try std.fs.path.join(gpa, &.{ paths.cache, meta_name });
    defer gpa.free(meta_path);
    const lock_name = try std.fmt.allocPrint(gpa, "zls-{s}", .{zig_version});
    defer gpa.free(lock_name);

    const body = try cached_fetch.fetch(
        gpa,
        io,
        url,
        cache_path,
        meta_path,
        paths.locks,
        lock_name,
        ttl_seconds,
    );

    return parseResponse(gpa, body);
}

fn apiUrl(gpa: std.mem.Allocator, zig_version: []const u8) ![]const u8 {
    const encoded = try encodeQueryValue(gpa, zig_version);
    defer gpa.free(encoded);

    return std.fmt.allocPrint(
        gpa,
        "{s}?zig_version={s}&compatibility=only-runtime",
        .{ api_url, encoded },
    );
}

const hex = "0123456789ABCDEF";

/// Percent-encodes `version` for use as a query string value. Versions are
/// validated before they get here, but semver build metadata like
/// `1.0.0+build.1` still needs encoding: in queries, `+` means a space.
fn encodeQueryValue(gpa: std.mem.Allocator, version: []const u8) ![]const u8 {
    var len: usize = 0;
    for (version) |c| len += if (isUnreserved(c)) 1 else 3;

    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);

    var end: usize = 0;
    for (version) |c| {
        if (isUnreserved(c)) {
            buf[end] = c;
            end += 1;
        } else {
            buf[end] = '%';
            buf[end + 1] = hex[(c >> 4) & 0x0F];
            buf[end + 2] = hex[c & 0x0F];
            end += 3;
        }
    }

    return buf;
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// Downloads and installs the ZLS build matching `zig_version` into
/// `versions/<zig_version>/zls`, next to the toolchain it belongs to.
pub fn install(ctx: *Context, zig_version: []const u8, progress: std.Progress.Node) !InstallResult {
    try validateVersion(zig_version);
    if (!target.zls_supported)
        return error.ZlsTargetUnsupported;

    // Serialize with zig installs and removals of the same version.
    var version_lock = try lock.acquire(ctx.gpa, ctx.io, ctx.paths.locks, zig_version);
    defer version_lock.release(ctx.io);

    return installLocked(ctx, zig_version, progress);
}

/// Like `install`, but for callers that already hold the version lock for
/// `zig_version`. The `zls` shim holds the version lock while the language
/// server runs. A separate installation lock serializes the mutation of the
/// ZLS directory when multiple shims start at the same time.
pub fn installLocked(ctx: *Context, zig_version: []const u8, progress: std.Progress.Node) !InstallResult {
    try validateVersion(zig_version);

    const zls_install_lock_name = try std.fmt.allocPrint(
        ctx.gpa,
        "{s}.zls.install",
        .{zig_version},
    );
    defer ctx.gpa.free(zls_install_lock_name);
    var zls_install_lock = try lock.acquire(
        ctx.gpa,
        ctx.io,
        ctx.paths.locks,
        zls_install_lock_name,
    );
    defer zls_install_lock.release(ctx.io);

    const zls_dir = try ctx.paths.zlsDir(ctx.gpa, zig_version);

    // An installed ZLS needs no API access at all.
    if (isZlsInstalled(ctx, zls_dir)) {
        debug.log("zls for {s} already installed at {s}", .{ zig_version, zls_dir });

        return .{
            .zig_version = zig_version,
            .zls_version = null,
            .already_installed = true,
        };
    }

    const resolved = try resolve(ctx.gpa, ctx.io, ctx.paths, zig_version);

    debug.log(
        "installing zls {s} for zig {s} from {s}",
        .{ resolved.version, zig_version, resolved.tarball_url },
    );

    const zls_tmp_name = try std.fmt.allocPrint(ctx.gpa, "zls-{s}", .{zig_version});
    defer ctx.gpa.free(zls_tmp_name);
    const install_tmp = try std.fs.path.join(ctx.gpa, &.{ ctx.paths.tmp, zls_tmp_name });
    const scratch = try std.fs.path.join(ctx.gpa, &.{ install_tmp, "extract" });
    const archive_name = urlBasename(resolved.tarball_url);
    const archive_path = try std.fs.path.join(ctx.gpa, &.{ install_tmp, archive_name });
    try Io.Dir.cwd().createDirPath(ctx.io, install_tmp);
    errdefer retry.deleteTree(ctx.io, Io.Dir.cwd(), install_tmp) catch {};

    const minisign_signature: ?[]u8 = if (!ctx.skip_verification and resolved.shasum == null) blk: {
        const signature_url = try std.fmt.allocPrint(
            ctx.gpa,
            "{s}.minisig",
            .{resolved.tarball_url},
        );
        defer ctx.gpa.free(signature_url);

        const signature = net.get(ctx.gpa, ctx.io, signature_url) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.ZlsVerificationUnavailable,
        };
        if (signature.status != .ok) {
            ctx.gpa.free(signature.body);
            return error.ZlsVerificationUnavailable;
        }

        break :blk signature.body;
    } else null;
    defer if (minisign_signature) |signature| ctx.gpa.free(signature);

    if (!ctx.skip_verification and resolved.shasum == null and minisign_signature == null)
        return error.ZlsVerificationUnavailable;

    const urls = &[_][]const u8{resolved.tarball_url};
    const download_label = try std.fmt.allocPrint(ctx.gpa, "zls {s}", .{zig_version});
    try download(
        ctx.gpa,
        ctx.io,
        urls,
        archive_path,
        if (ctx.skip_verification) null else resolved.shasum,
        minisign_signature,
        .zls,
        download_label,
        progress,
    );

    const extract_label = try std.fmt.allocPrint(ctx.gpa, "extract zls {s}", .{zig_version});
    try extract.installFromArchive(
        ctx.gpa,
        ctx.io,
        archive_path,
        scratch,
        zls_dir,
        extract_label,
        progress,
    );

    const cleanup_node = progress.start("cleaning up", 0);
    retry.deleteTree(ctx.io, Io.Dir.cwd(), install_tmp) catch {};
    cleanup_node.end();

    return .{
        .zig_version = zig_version,
        .zls_version = resolved.version,
        .already_installed = false,
    };
}

fn isZlsInstalled(ctx: *Context, zls_dir: []const u8) bool {
    const executable = std.fs.path.join(
        ctx.gpa,
        &.{ zls_dir, target.zlsExeName() },
    ) catch
        return false;
    defer ctx.gpa.free(executable);

    var file = Io.Dir.cwd().openFile(ctx.io, executable, .{}) catch
        return false;
    file.close(ctx.io);
    return true;
}

pub fn isInstalled(ctx: *Context, zig_version: []const u8) bool {
    const zls_dir = ctx.paths.zlsDir(ctx.gpa, zig_version) catch return false;
    defer ctx.gpa.free(zls_dir);

    return isInstalledAt(ctx, zls_dir);
}

pub fn isInstalledAt(ctx: *Context, zls_dir: []const u8) bool {
    return isZlsInstalled(ctx, zls_dir);
}

pub fn installErrorHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ZlsTargetUnsupported => "no prebuilt ZLS is available for this target",
        error.ZlsVersionUnsupported => "no compatible ZLS release is available for this Zig version",
        error.ZlsApiError, error.ZlsIndexInvalid => "the ZLS release service returned invalid metadata",
        error.ZlsVerificationUnavailable => "the ZLS download could not be verified; use --no-verify to override",
        error.ChecksumMismatch,
        error.InvalidMinisignSignature,
        error.UnknownMinisignKey,
        error.InvalidArchiveSignature,
        error.InvalidGlobalSignature,
        => "the ZLS download failed verification",
        else => null,
    };
}

/// The returned slices are allocated from `gpa`; free them with the same
/// allocator once the result is no longer needed.
fn parseResponse(gpa: std.mem.Allocator, body: []const u8) !Resolved {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        body,
        .{},
    );
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.ZlsIndexInvalid,
    };

    if (root.get("code")) |code| {
        const code_number = switch (code) {
            .integer => |number| number,
            else => return error.ZlsIndexInvalid,
        };
        _ = root.get("message") orelse
            return error.ZlsIndexInvalid;

        return if (code_number == 4)
            error.ZlsVersionUnsupported
        else
            error.ZlsApiError;
    }

    if (root.get("error")) |_|
        return error.ZlsApiError;

    const version = root.get("version") orelse
        return error.ZlsIndexInvalid;
    const version_str: []const u8 = switch (version) {
        .string => |s| s,
        else => return error.ZlsIndexInvalid,
    };

    const entry = root.get(target.native_target_string) orelse
        return error.ZlsTargetUnsupported;
    const entry_obj = switch (entry) {
        .object => |object| object,
        else => return error.ZlsIndexInvalid,
    };

    const tarball = entry_obj.get("tarball") orelse
        return error.ZlsIndexInvalid;
    const tarball_str: []const u8 = switch (tarball) {
        .string => |s| s,
        else => return error.ZlsIndexInvalid,
    };

    const shasum: ?[]const u8 = blk: {
        const s = entry_obj.get("shasum") orelse break :blk null;
        break :blk switch (s) {
            .string => |str| str,
            else => null,
        };
    };

    const size: ?u64 = blk: {
        const s = entry_obj.get("size") orelse break :blk null;
        break :blk switch (s) {
            .integer => |i| if (i >= 0) @intCast(i) else null,
            .string => |str| std.fmt.parseInt(u64, str, 10) catch null,
            else => null,
        };
    };

    return .{
        .version = try gpa.dupe(u8, version_str),
        .tarball_url = try gpa.dupe(u8, tarball_str),
        .shasum = if (shasum) |s| try gpa.dupe(u8, s) else null,
        .size = size,
    };
}

//

test "parseResponse selects the native artifact and its verification metadata" {
    const fixture = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "version": "0.16.0",
        \\  "date": "2026-04-16",
        \\  "{s}": {{
        \\    "tarball": "https://builds.zigtools.org/zls.tar.xz",
        \\    "shasum": "abc123",
        \\    "size": "1234"
        \\  }}
        \\}}
    , .{target.native_target_string});
    defer std.testing.allocator.free(fixture);

    const resolved = try parseResponse(std.testing.allocator, fixture);
    defer {
        std.testing.allocator.free(resolved.version);
        std.testing.allocator.free(resolved.tarball_url);
        if (resolved.shasum) |s| std.testing.allocator.free(s);
    }

    try std.testing.expectEqualStrings("0.16.0", resolved.version);
    try std.testing.expectEqualStrings("https://builds.zigtools.org/zls.tar.xz", resolved.tarball_url);
    try std.testing.expectEqualStrings("abc123", resolved.shasum.?);
    try std.testing.expectEqual(@as(?u64, 1234), resolved.size);
}

test "parseResponse rejects responses without a native artifact" {
    const fixture =
        \\{
        \\  "version": "0.16.0",
        \\  "unsupported-target": {
        \\    "tarball": "https://builds.zigtools.org/zls.tar.xz",
        \\    "shasum": "abc123",
        \\    "size": "1234"
        \\  }
        \\}
    ;
    try std.testing.expectError(
        error.ZlsTargetUnsupported,
        parseResponse(std.testing.allocator, fixture),
    );
}

test "parseResponse rejects API error payloads" {
    const fixture =
        \\{"error":"Query component 'zig_version' with value 'master' is not a valid version!"}
    ;
    try std.testing.expectError(
        error.ZlsApiError,
        parseResponse(std.testing.allocator, fixture),
    );
}

test "parseResponse maps unsupported Zig API errors" {
    const fixture =
        \\{"code":4,"message":"Zig 0.15.0 is unsupported by ZLS"}
    ;
    try std.testing.expectError(
        error.ZlsVersionUnsupported,
        parseResponse(std.testing.allocator, fixture),
    );
}

test "parseResponse rejects non-object API responses" {
    try std.testing.expectError(
        error.ZlsIndexInvalid,
        parseResponse(std.testing.allocator, "[]"),
    );
}

test "apiUrl percent-encodes the version for the query string" {
    const url = try apiUrl(std.testing.allocator, "0.16.0+build.1");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://releases.zigtools.org/v1/zls/select-version?zig_version=0.16.0%2Bbuild.1&compatibility=only-runtime",
        url,
    );
}

test "encodeQueryValue leaves plain versions untouched" {
    const encoded = try encodeQueryValue(std.testing.allocator, "0.16.0");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("0.16.0", encoded);
}

test "encodeQueryValue encodes reserved characters" {
    const encoded = try encodeQueryValue(std.testing.allocator, "1.0.0-rc.1+build.1");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("1.0.0-rc.1%2Bbuild.1", encoded);
}

test "installLocked reports an installed ZLS without resolving" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base = path_buf[0..path_len];

    const versions = try std.fs.path.join(allocator, &.{ base, "versions" });
    const zls_dir = try std.fs.path.join(allocator, &.{ versions, "0.16.0", "zls" });
    try tmp.dir.createDirPath(std.testing.io, zls_dir);
    const zls_executable = try std.fs.path.join(
        allocator,
        &.{ zls_dir, target.zlsExeName() },
    );

    const paths = Paths{
        .base = base,
        .versions = versions,
        .cache = base,
        .tmp = base,
        .locks = base,
        .bin = base,
        .config_file = base,
        .index_file = base,
        .index_meta_file = base,
        .mirrors_file = base,
        .mirrors_meta_file = base,
    };

    var ctx = Context{
        .gpa = allocator,
        .io = std.testing.io,
        .paths = paths,
    };

    try std.testing.expect(!isInstalledAt(&ctx, zls_dir));
    try Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = zls_executable,
        .data = "placeholder",
    });
    try std.testing.expect(isInstalledAt(&ctx, zls_dir));

    const progress = std.Progress.start(std.testing.io, .{ .root_name = "test" });
    defer progress.end();

    const result = try installLocked(&ctx, "0.16.0", progress);
    try std.testing.expect(result.already_installed);
    try std.testing.expectEqualStrings("0.16.0", result.zig_version);
}

const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;

const debug = @import("debug.zig");

//

/// The zvm directory layout, rooted at a per-user base directory:
///
///   versions/<version>/   extracted, installed toolchain
///   versions/<version>/zls/  matching ZLS, installed with `zvm install --with-zls`
///   cache/index.json      cached download index + cache/index.meta fetch timestamp
///   cache/mirrors.txt     cached mirror list + cache/mirrors.meta fetch timestamp
///   cache/tmp/            in-progress downloads/extracts
///   cache/locks/          per-version install locks
///   config.json           default_version, last_used_version
///   bin/                  where the zig/zls/zvm binaries are meant to live once on PATH
pub const Paths = struct {
    base: []const u8,
    versions: []const u8,
    cache: []const u8,
    tmp: []const u8,
    locks: []const u8,
    bin: []const u8,
    config_file: []const u8,
    index_file: []const u8,
    index_meta_file: []const u8,
    mirrors_file: []const u8,
    mirrors_meta_file: []const u8,

    /// `ZVM_HOME` overrides everything. Otherwise per-user: LOCALAPPDATA
    /// on Windows, XDG_DATA_HOME (or ~/.local/share) elsewhere.
    pub fn discover(gpa: std.mem.Allocator, environ: std.process.Environ.Map) !Paths {
        const base = try baseDir(gpa, environ);

        debug.log("zvm home: {s}", .{base});

        return .{
            .base = base,
            .versions = try std.fs.path.join(gpa, &.{ base, "versions" }),
            .cache = try std.fs.path.join(gpa, &.{ base, "cache" }),
            .tmp = try std.fs.path.join(gpa, &.{ base, "cache", "tmp" }),
            .locks = try std.fs.path.join(gpa, &.{ base, "cache", "locks" }),
            .bin = try std.fs.path.join(gpa, &.{ base, "bin" }),
            .config_file = try std.fs.path.join(gpa, &.{ base, "config.json" }),
            .index_file = try std.fs.path.join(gpa, &.{ base, "cache", "index.json" }),
            .index_meta_file = try std.fs.path.join(gpa, &.{ base, "cache", "index.meta" }),
            .mirrors_file = try std.fs.path.join(gpa, &.{ base, "cache", "mirrors.txt" }),
            .mirrors_meta_file = try std.fs.path.join(gpa, &.{ base, "cache", "mirrors.meta" }),
        };
    }

    pub fn versionDir(self: Paths, gpa: std.mem.Allocator, version: []const u8) ![]const u8 {
        try @import("version.zig").validate(version);

        return std.fs.path.join(gpa, &.{ self.versions, version });
    }

    /// Where the ZLS language server for a version lives, next to the
    /// toolchain it belongs to, so `zvm remove` cleans both up together.
    pub fn zlsDir(self: Paths, gpa: std.mem.Allocator, version: []const u8) ![]const u8 {
        try @import("version.zig").validate(version);

        return std.fs.path.join(gpa, &.{ self.versions, version, "zls" });
    }

    /// Creates the directory layout. Recursive, so creating `versions`,
    /// `tmp`, `locks`, and `bin` also creates `base` and `cache`.
    pub fn ensureLayout(self: Paths, io: Io) !void {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, self.versions);
        try cwd.createDirPath(io, self.tmp);
        try cwd.createDirPath(io, self.locks);
        try cwd.createDirPath(io, self.bin);
    }
};

fn baseDir(gpa: std.mem.Allocator, environ: std.process.Environ.Map) ![]const u8 {
    if (environ.get("ZVM_HOME")) |v|
        return gpa.dupe(u8, v);

    if (builtin.target.os.tag == .windows) {
        const local = environ.get("LOCALAPPDATA") orelse
            return error.EnvironmentVariableMissing;

        return std.fs.path.join(gpa, &.{ local, "zvm" });
    }

    if (environ.get("XDG_DATA_HOME")) |v| {
        return std.fs.path.join(gpa, &.{ v, "zvm" });
    }

    const home = environ.get("HOME") orelse
        return error.EnvironmentVariableMissing;

    return std.fs.path.join(gpa, &.{ home, ".local", "share", "zvm" });
}

//

test "ZVM_HOME overrides the platform default" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZVM_HOME", "custom-zvm-home");
    try environ.put("LOCALAPPDATA", "ignored-local-app-data");
    try environ.put("XDG_DATA_HOME", "ignored-xdg-data-home");
    try environ.put("HOME", "ignored-home");

    const result = try baseDir(std.testing.allocator, environ);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("custom-zvm-home", result);
}

test "baseDir follows the native platform data directory convention" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    if (builtin.target.os.tag == .windows) {
        try environ.put("LOCALAPPDATA", "local-app-data");

        const result = try baseDir(std.testing.allocator, environ);
        defer std.testing.allocator.free(result);
        const expected = try std.fs.path.join(std.testing.allocator, &.{ "local-app-data", "zvm" });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, result);
    } else {
        try environ.put("XDG_DATA_HOME", "xdg-data-home");
        try environ.put("HOME", "ignored-home");

        const xdg_result = try baseDir(std.testing.allocator, environ);
        defer std.testing.allocator.free(xdg_result);
        const xdg_expected = try std.fs.path.join(std.testing.allocator, &.{ "xdg-data-home", "zvm" });
        defer std.testing.allocator.free(xdg_expected);
        try std.testing.expectEqualStrings(xdg_expected, xdg_result);

        _ = environ.swapRemove("XDG_DATA_HOME");
        try environ.put("HOME", "home");
        const home_result = try baseDir(std.testing.allocator, environ);
        defer std.testing.allocator.free(home_result);
        const home_expected = try std.fs.path.join(std.testing.allocator, &.{ "home", ".local", "share", "zvm" });
        defer std.testing.allocator.free(home_expected);
        try std.testing.expectEqualStrings(home_expected, home_result);
    }
}

/// The zvm directory layout, rooted at a per-user base directory:
///
///   versions/<version>/   extracted, installed toolchain
///   cache/index.json      cached download index + cache/index.meta fetch timestamp
///   cache/mirrors.txt     cached mirror list + cache/mirrors.meta fetch timestamp
///   cache/tmp/            in-progress downloads/extracts
///   cache/locks/          per-version install locks
///   config.json           default_version, last_used_version
///   bin/                  where the zig/zvm binaries are meant to live once on PATH
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

const Io = std.Io;

const debug = @import("debug.zig");

const std = @import("std");
const builtin = @import("builtin");

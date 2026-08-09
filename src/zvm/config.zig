const std = @import("std");
const Io = std.Io;

const atomic_write = @import("atomic_write.zig");
const lock = @import("lock.zig");

const Paths = @import("paths.zig").Paths;

//

pub const Config = struct {
    default_version: ?[]const u8 = null,
    last_used_version: ?[]const u8 = null,
};

pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !Config {
    const cwd = Io.Dir.cwd();
    const text = cwd.readFileAlloc(
        io,
        path,
        gpa,
        .limited(1 << 16),
    ) catch |err| switch (err) {
        error.FileNotFound => return Config{},
        else => return err,
    };
    const parsed = std.json.parseFromSlice(
        Config,
        gpa,
        text,
        .{ .ignore_unknown_fields = true },
    ) catch
        return Config{};

    return parsed.value;
}

pub fn setDefault(gpa: std.mem.Allocator, io: Io, paths: Paths, version: ?[]const u8) !void {
    try update(gpa, io, paths, .default_version, version);
}

pub fn recordUse(gpa: std.mem.Allocator, io: Io, paths: Paths, version: []const u8) !void {
    try update(gpa, io, paths, .last_used_version, version);
}

fn update(gpa: std.mem.Allocator, io: Io, paths: Paths, field: Field, value: ?[]const u8) !void {
    var config_lock = try lock.acquire(gpa, io, paths.locks, "config");
    defer config_lock.release(io);

    var cfg = try load(gpa, io, paths.config_file);
    switch (field) {
        .default_version => cfg.default_version = value,
        .last_used_version => cfg.last_used_version = value,
    }

    try save(gpa, io, paths.config_file, cfg);
}

const Field = enum {
    default_version,
    last_used_version,
};

fn save(gpa: std.mem.Allocator, io: Io, path: []const u8, cfg: Config) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try std.json.Stringify.value(
        cfg,
        .{
            .whitespace = .indent_2,
        },
        &out.writer,
    );

    try atomic_write.writeFile(io, path, out.written());
}

//

test "load treats missing or malformed configuration as empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const config_path = try std.fs.path.join(allocator, &.{ path_buf[0..path_len], "config.json" });

    const missing = try load(allocator, io, config_path);
    try std.testing.expect(missing.default_version == null);
    try std.testing.expect(missing.last_used_version == null);

    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = "whatever" });
    const malformed = try load(allocator, io, config_path);
    try std.testing.expect(malformed.default_version == null);
    try std.testing.expect(malformed.last_used_version == null);
}

test "configuration updates preserve the other version setting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, "locks");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..path_len];
    const lock_path = try std.fs.path.join(allocator, &.{ base, "locks" });
    const config_path = try std.fs.path.join(allocator, &.{ base, "config.json" });
    const test_paths: Paths = .{
        .base = base,
        .versions = "",
        .cache = "",
        .tmp = "",
        .locks = lock_path,
        .bin = "",
        .config_file = config_path,
        .index_file = "",
        .index_meta_file = "",
        .mirrors_file = "",
        .mirrors_meta_file = "",
    };

    try setDefault(allocator, io, test_paths, "0.16.0");
    try recordUse(allocator, io, test_paths, "0.15.2");

    const configured = try load(allocator, io, config_path);
    try std.testing.expectEqualStrings("0.16.0", configured.default_version.?);
    try std.testing.expectEqualStrings("0.15.2", configured.last_used_version.?);

    try setDefault(allocator, io, test_paths, null);
    const cleared = try load(allocator, io, config_path);
    try std.testing.expect(cleared.default_version == null);
    try std.testing.expectEqualStrings("0.15.2", cleared.last_used_version.?);
}

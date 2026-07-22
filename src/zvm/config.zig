pub const Config = struct {
    default_version: ?[]const u8 = null,
    last_used_version: ?[]const u8 = null,
};

pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !Config {
    const cwd = Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, path, gpa, .limited(1 << 16)) catch |err| switch (err) {
        error.FileNotFound => return Config{},
        else => return err,
    };
    const parsed = std.json.parseFromSlice(Config, gpa, text, .{ .ignore_unknown_fields = true }) catch return Config{};

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

const atomic_write = @import("atomic_write.zig");
const lock = @import("lock.zig");
const Paths = @import("paths.zig").Paths;

const std = @import("std");
const Io = std.Io;

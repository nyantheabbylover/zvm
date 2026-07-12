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

pub fn save(gpa: std.mem.Allocator, io: Io, path: []const u8, cfg: Config) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try std.json.Stringify.value(
        cfg,
        .{
            .whitespace = .indent_2,
        },
        &out.writer,
    );

    const cwd = Io.Dir.cwd();
    var file = try cwd.createFile(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.writeAll(out.written());
    try fw.interface.flush();
}

const std = @import("std");
const Io = std.Io;

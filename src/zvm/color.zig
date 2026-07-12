pub fn detectMode(io: Io, file: Io.File, gpa: std.mem.Allocator, environ: std.process.Environ) Io.Terminal.Mode {
    const no_color = envFlag(gpa, environ, "NO_COLOR");
    const force = envFlag(gpa, environ, "CLICOLOR_FORCE");

    return Io.Terminal.Mode.detect(io, file, no_color, force) catch .no_color;
}

fn envFlag(gpa: std.mem.Allocator, environ: std.process.Environ, key: []const u8) bool {
    const val = environ.getAlloc(gpa, key) catch return false;

    return val.len > 0;
}

pub fn print(t: Io.Terminal, color: Io.Terminal.Color, comptime fmt: []const u8, args: anytype) !void {
    t.setColor(color) catch {};
    try t.writer.print(fmt, args);
    t.setColor(.reset) catch {};
}

const std = @import("std");
const Io = std.Io;

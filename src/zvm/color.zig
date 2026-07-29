pub fn detectMode(io: Io, file: Io.File, environ: std.process.Environ.Map) Io.Terminal.Mode {
    const no_color = envFlag(environ, "NO_COLOR");
    const force = envFlag(environ, "CLICOLOR_FORCE");

    return Io.Terminal.Mode.detect(io, file, no_color, force) catch .no_color;
}

fn envFlag(environ: std.process.Environ.Map, key: []const u8) bool {
    return if (environ.get(key)) |val| val.len > 0 else false;
}

pub fn print(
    t: Io.Terminal,
    color: Io.Terminal.Color,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    t.setColor(color) catch {};
    try t.writer.print(fmt, args);
    t.setColor(.reset) catch {};
}

//

const Io = std.Io;

const std = @import("std");

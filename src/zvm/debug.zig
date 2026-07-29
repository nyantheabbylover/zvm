/// Toggled on by `ZVM_DEBUG=1` (both binaries) or `zvm --verbose` (the
/// CLI only, the `zig` shim can't spend an argv slot on a flag
/// since everything after it must pass through to the real compiler
/// unchanged).
pub var enabled: bool = false;

pub fn initFromEnv(gpa: std.mem.Allocator, environ: std.process.Environ) void {
    const val = environ.getAlloc(gpa, "ZVM_DEBUG") catch
        return;
    enabled = val.len > 0 and !std.mem.eql(u8, val, "0");
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!enabled)
        return;

    var buf: [256]u8 = undefined;
    const t = std.debug.lockStderr(&buf).terminal();
    defer std.debug.unlockStderr();

    t.setColor(.dim) catch {};
    t.writer.print("[zvm] " ++ fmt ++ "\n", args) catch {};
    t.setColor(.reset) catch {};
    t.writer.flush() catch {};
}

//

const std = @import("std");

pub fn nativeTargetString() []const u8 {
    return std.fmt.comptimePrint("{t}-{t}", .{
        builtin.target.cpu.arch,
        builtin.target.os.tag,
    });
}

pub fn archiveExt() []const u8 {
    return if (builtin.target.os.tag == .windows) ".zip" else ".tar.xz";
}

pub fn exeName() []const u8 {
    return if (builtin.target.os.tag == .windows) "zig.exe" else "zig";
}

//

const builtin = @import("builtin");
const std = @import("std");

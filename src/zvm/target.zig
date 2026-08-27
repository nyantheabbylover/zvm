pub const native_target_string: []const u8 = std.fmt.comptimePrint("{t}-{t}", .{
    builtin.target.cpu.arch,
    builtin.target.os.tag,
});

pub const archive_ext: []const u8 =
    if (builtin.target.os.tag == .windows) ".zip" else ".tar.xz";

pub const exe_name: []const u8 =
    if (builtin.target.os.tag == .windows) "zig.exe" else "zig";

pub fn zlsExeName() []const u8 {
    return if (builtin.target.os.tag == .windows) "zls.exe" else "zls";
}

//

const builtin = @import("builtin");
const std = @import("std");

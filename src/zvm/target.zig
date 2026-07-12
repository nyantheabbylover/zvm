pub fn nativeTargetString() []const u8 {
    return switch (builtin.target.os.tag) {
        .windows => switch (builtin.target.cpu.arch) {
            .aarch64 => "aarch64-windows",
            else => "x86_64-windows",
        },
        else => switch (builtin.target.cpu.arch) {
            .aarch64 => "aarch64-linux",
            else => "x86_64-linux",
        },
    };
}

pub fn archiveExt() []const u8 {
    return if (builtin.target.os.tag == .windows) ".zip" else ".tar.xz";
}

pub fn exeName() []const u8 {
    return if (builtin.target.os.tag == .windows) "zig.exe" else "zig";
}

const builtin = @import("builtin");

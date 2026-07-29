/// Runs the real zig compiler with `argv` (argv[0] is its path).
///
/// On POSIX this replaces the current process image via `std.process.replace`.
/// It never returns on success, so there is no wrapper process left behind.
///
/// Windows has no equivalent syscall, so there we spawn, inherit
/// stdio, wait, and return the child's exact exit code for the caller to
/// pass to `std.process.exit`.
pub fn run(io: Io, argv: []const []const u8) !u8 {
    if (comptime std.process.can_replace) {
        const err = std.process.replace(io, .{ .argv = argv });

        return err;
    }

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);

    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

//

const Io = std.Io;

const std = @import("std");

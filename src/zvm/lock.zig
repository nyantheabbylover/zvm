/// A process-scoped, advisory lock. The operating system releases it when the
/// holder exits, including after a crash.
pub const Held = struct {
    file: Io.File,

    pub fn downgrade(self: *Held, io: Io) !void {
        try self.file.downgradeLock(io);
    }

    /// POSIX files opened by Zig normally have `FD_CLOEXEC` set. Clear it so
    /// this lock remains held after the shim replaces itself with `zig`.
    pub fn inheritAcrossExec(self: *Held) !void {
        if (comptime builtin.target.os.tag == .windows) return;

        while (true) {
            const rc = std.posix.system.fcntl(self.file.handle, std.posix.F.SETFD, 0);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    pub fn release(self: *Held, io: Io) void {
        self.file.unlock(io);
        self.file.close(io);
    }
};

pub fn acquire(gpa: std.mem.Allocator, io: Io, lock_dir: []const u8, name: []const u8) !Held {
    return (try acquireWithMode(gpa, io, lock_dir, name, .exclusive, true)) orelse unreachable;
}

pub fn tryAcquireExclusive(gpa: std.mem.Allocator, io: Io, lock_dir: []const u8, name: []const u8) !?Held {
    return acquireWithMode(gpa, io, lock_dir, name, .exclusive, false);
}

fn acquireWithMode(
    gpa: std.mem.Allocator,
    io: Io,
    lock_dir: []const u8,
    name: []const u8,
    mode: Io.File.Lock,
    wait: bool,
) !?Held {
    const filename = try std.fmt.allocPrint(gpa, "{s}.lock", .{name});
    const path = try std.fs.path.join(gpa, &.{ lock_dir, filename });
    var file = try Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
    });
    errdefer file.close(io);

    if (try file.tryLock(io, mode)) {
        return .{ .file = file };
    }
    if (!wait) {
        file.close(io);

        return null;
    }

    {
        debug.log("waiting for lock: {s}", .{name});
        try file.lock(io, mode);
    }

    return .{ .file = file };
}

const debug = @import("debug.zig");

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

/// A process-scoped, advisory lock. The operating system releases it when the
/// holder exits, including after a crash.
pub const Held = struct {
    file: Io.File,

    pub fn release(self: *Held, io: Io) void {
        self.file.unlock(io);
        self.file.close(io);
    }
};

pub fn acquire(gpa: std.mem.Allocator, io: Io, lock_dir: []const u8, name: []const u8) !Held {
    const filename = try std.fmt.allocPrint(gpa, "{s}.lock", .{name});
    const path = try std.fs.path.join(gpa, &.{ lock_dir, filename });
    var file = try Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
    });
    errdefer file.close(io);

    if (!try file.tryLock(io, .exclusive)) {
        debug.log("waiting for lock: {s}", .{name});
        try file.lock(io, .exclusive);
    }

    return .{ .file = file };
}

const debug = @import("debug.zig");

const std = @import("std");
const Io = std.Io;

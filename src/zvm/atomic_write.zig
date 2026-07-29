/// Replaces `path` only after its complete new contents have been written.
/// Readers therefore see either the previous file or the complete new file.
pub fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    var atomic_file = try Io.Dir.cwd().createFileAtomic(
        io,
        path,
        .{ .replace = true },
    );
    defer atomic_file.deinit(io);

    var buf: [4096]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
    try atomic_file.replace(io);
}

//

const Io = std.Io;

const std = @import("std");

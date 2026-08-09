const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;

const retry = @import("retry.zig");

//

pub fn installFromArchive(
    gpa: std.mem.Allocator,
    io: Io,
    archive_path: []const u8,
    scratch_dir: []const u8,
    final_dir: []const u8,
    label: []const u8,
    progress_parent: std.Progress.Node,
) !void {
    const node = progress_parent.start(label, 0);
    defer node.end();

    const cwd = Io.Dir.cwd();
    retry.deleteTree(io, cwd, scratch_dir) catch {};
    try cwd.createDirPath(io, scratch_dir);

    var dest = try cwd.openDir(io, scratch_dir, .{});
    defer dest.close(io);

    if (builtin.target.os.tag == .windows) {
        try extractZip(io, dest, archive_path);
    } else {
        try extractTarXz(gpa, io, dest, archive_path);
    }

    const inner = try findSingleTopLevelDir(gpa, io, scratch_dir);
    defer gpa.free(inner);

    if (std.fs.path.dirname(final_dir)) |parent| {
        try cwd.createDirPath(io, parent);
    }

    retry.deleteTree(io, cwd, final_dir) catch {};
    try retry.rename(io, cwd, inner, cwd, final_dir);
    retry.deleteTree(io, cwd, scratch_dir) catch {};
}

fn extractTarXz(gpa: std.mem.Allocator, io: Io, dest: Io.Dir, archive_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var file = try cwd.openFile(io, archive_path, .{});
    defer file.close(io);

    var f_buf: [1 << 16]u8 = undefined;
    var fr = file.reader(io, &f_buf);

    const d_buf = try gpa.alloc(u8, 1 << 16);
    var decompress: std.compress.xz.Decompress = try .init(&fr.interface, gpa, d_buf);
    defer decompress.deinit();

    try std.tar.extract(
        io,
        dest,
        &decompress.reader,
        .{ .mode_mode = .executable_bit_only },
    );
}

fn extractZip(io: Io, dest: Io.Dir, archive_path: []const u8) !void {
    const zip_file = try Io.Dir.cwd().openFile(io, archive_path, .{});
    defer zip_file.close(io);
    var r_buf: [1 << 16]u8 = undefined;
    var fr = zip_file.reader(io, &r_buf);
    try std.zip.extract(dest, &fr, .{});
}

fn findSingleTopLevelDir(gpa: std.mem.Allocator, io: Io, scratch_dir: []const u8) ![]const u8 {
    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, scratch_dir, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    var only: ?[]const u8 = null;
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        count += 1;
        if (count == 1 and entry.kind == .directory) {
            only = try gpa.dupe(u8, entry.name);
        } else {
            only = null;
        }
        if (count > 1)
            break;
    }

    if (count == 1 and only != null) {
        return std.fs.path.join(gpa, &.{ scratch_dir, only.? });
    }

    return gpa.dupe(u8, scratch_dir);
}

//

test "findSingleTopLevelDir selects one directory and otherwise keeps the scratch directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const root = path_buf[0..path_len];

    const one_dir = try std.fs.path.join(allocator, &.{ root, "one-dir" });
    try tmp.dir.createDirPath(io, "one-dir/zig");
    const found = try findSingleTopLevelDir(allocator, io, one_dir);
    defer allocator.free(found);
    const expected = try std.fs.path.join(allocator, &.{ one_dir, "zig" });
    try std.testing.expectEqualStrings(expected, found);

    const multiple = try std.fs.path.join(allocator, &.{ root, "multiple" });
    try tmp.dir.createDirPath(io, "multiple/zig");
    try tmp.dir.writeFile(io, .{ .sub_path = "multiple/README.txt", .data = "test" });
    const multiple_found = try findSingleTopLevelDir(allocator, io, multiple);
    defer allocator.free(multiple_found);
    try std.testing.expectEqualStrings(multiple, multiple_found);

    const file_only = try std.fs.path.join(allocator, &.{ root, "file-only" });
    try tmp.dir.createDirPath(io, "file-only");
    try tmp.dir.writeFile(io, .{ .sub_path = "file-only/zig", .data = "not a directory" });
    const file_found = try findSingleTopLevelDir(allocator, io, file_only);
    defer allocator.free(file_found);
    try std.testing.expectEqualStrings(file_only, file_found);
}

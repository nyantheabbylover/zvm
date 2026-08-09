const std = @import("std");
const Io = std.Io;

const atomic_write = @import("atomic_write.zig");
const debug = @import("debug.zig");
const lock = @import("lock.zig");
const net = @import("net.zig");

//

pub fn fetch(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    cache_path: []const u8,
    meta_path: []const u8,
    lock_dir: []const u8,
    lock_name: []const u8,
    ttl_seconds: i64,
) ![]u8 {
    if (try readFresh(
        gpa,
        io,
        cache_path,
        meta_path,
        ttl_seconds,
    )) |cached| {
        debug.log("cache hit: {s}", .{cache_path});

        return cached;
    }

    var cache_lock = try lock.acquire(gpa, io, lock_dir, lock_name);
    defer cache_lock.release(io);

    // Another zvm instance may have refreshed this cache while this one was
    // waiting for the lock.
    if (try readFresh(
        gpa,
        io,
        cache_path,
        meta_path,
        ttl_seconds,
    )) |cached| {
        debug.log("cache refreshed by another process: {s}", .{cache_path});

        return cached;
    }

    debug.log("fetching {s}", .{url});
    const result = net.get(gpa, io, url) catch |err| {
        if (err == error.Canceled)
            return error.Canceled;

        debug.log(
            "fetch failed ({t}), falling back to any stale cache",
            .{err},
        );

        return readAny(
            gpa,
            io,
            cache_path,
        ) catch |fallback_err| switch (fallback_err) {
            error.Canceled => return error.Canceled,
            else => return err,
        };
    };

    if (result.status != .ok) {
        debug.log(
            "fetch returned HTTP {d}, falling back to any stale cache",
            .{@intFromEnum(result.status)},
        );

        return readAny(
            gpa,
            io,
            cache_path,
        ) catch |fallback_err| switch (fallback_err) {
            error.Canceled => return error.Canceled,
            else => return error.HttpRequestFailed,
        };
    }

    writeCache(
        io,
        cache_path,
        meta_path,
        result.body,
    ) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };

    return result.body;
}

fn readAny(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        .limited(net.max_body_bytes),
    );
}

fn readFresh(
    gpa: std.mem.Allocator,
    io: Io,
    cache_path: []const u8,
    meta_path: []const u8,
    ttl_seconds: i64,
) !?[]u8 {
    const meta_text = Io.Dir.cwd().readFileAlloc(
        io,
        meta_path,
        gpa,
        .limited(64),
    ) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    defer gpa.free(meta_text);

    const trimmed = std.mem.trim(u8, meta_text, " \t\r\n");
    const fetched = std.fmt.parseInt(i64, trimmed, 10) catch
        return null;

    if (Io.Timestamp.now(io, .real).toSeconds() - fetched > ttl_seconds)
        return null;

    return readAny(gpa, io, cache_path) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
}

fn writeCache(io: Io, cache_path: []const u8, meta_path: []const u8, body: []const u8) !void {
    try writeFile(io, cache_path, body);
    var buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(
        &buf,
        "{d}",
        .{Io.Timestamp.now(io, .real).toSeconds()},
    ) catch unreachable;
    try writeFile(io, meta_path, ts);
}

fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    try atomic_write.writeFile(io, path, data);
}

//

test "readFresh returns cached data only while its metadata is fresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const cache_path = try std.fs.path.join(allocator, &.{ path_buf[0..path_len], "index.json" });
    const meta_path = try std.fs.path.join(allocator, &.{ path_buf[0..path_len], "index.meta" });

    try tmp.dir.writeFile(io, .{ .sub_path = "index.json", .data = "cached index" });

    var timestamp_buf: [32]u8 = undefined;
    const timestamp = try std.fmt.bufPrint(
        &timestamp_buf,
        "{d}",
        .{Io.Timestamp.now(io, .real).toSeconds()},
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "index.meta", .data = timestamp });

    const fresh = (try readFresh(allocator, io, cache_path, meta_path, 60)) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("cached index", fresh);

    try tmp.dir.writeFile(io, .{ .sub_path = "index.meta", .data = "0" });
    try std.testing.expect(
        try readFresh(allocator, io, cache_path, meta_path, 60) == null,
    );
}

test "readFresh ignores corrupt metadata and missing cache data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const cache_path = try std.fs.path.join(allocator, &.{ path_buf[0..path_len], "missing.json" });
    const meta_path = try std.fs.path.join(allocator, &.{ path_buf[0..path_len], "index.meta" });

    try tmp.dir.writeFile(io, .{ .sub_path = "index.meta", .data = "not a timestamp" });
    try std.testing.expect(
        try readFresh(allocator, io, cache_path, meta_path, 60) == null,
    );

    var timestamp_buf: [32]u8 = undefined;
    const timestamp = try std.fmt.bufPrint(
        &timestamp_buf,
        "{d}",
        .{Io.Timestamp.now(io, .real).toSeconds()},
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "index.meta", .data = timestamp });
    try std.testing.expect(
        try readFresh(allocator, io, cache_path, meta_path, 60) == null,
    );
}

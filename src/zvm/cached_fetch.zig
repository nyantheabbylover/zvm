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

const Io = std.Io;

const atomic_write = @import("atomic_write.zig");
const debug = @import("debug.zig");
const lock = @import("lock.zig");
const net = @import("net.zig");

const std = @import("std");

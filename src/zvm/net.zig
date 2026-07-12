pub const GetResult = struct {
    status: std.http.Status,
    body: []u8,
};

pub const max_body_bytes: usize = 8 << 20;

/// One-shot GET, buffering the whole (transparently decompressed) response
/// body into memory, capped at `max_body_bytes`. Meant for small payloads
/// (the download index, the mirror list), not for toolchain tarballs, which
/// stream via `download.zig` instead.
pub fn get(gpa: std.mem.Allocator, io: Io, url: []const u8) !GetResult {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    http_timeout.install(&req);
    try req.sendBodiless();

    var r_buf: [max_body_bytes / 1024]u8 = undefined;
    var res = req.receiveHead(&r_buf) catch |err|
        return http_timeout.translateError(&req, err);

    if (res.head.content_length) |len| {
        if (len > max_body_bytes) return error.ResponseTooLarge;
    }

    const d_buf: []u8 = switch (res.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (d_buf.len > 0) gpa.free(d_buf);

    var t_buf: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const body = res.readerDecompressing(&t_buf, &decompress, d_buf);

    var collected: Io.Writer.Allocating = .init(gpa);
    defer collected.deinit();

    var total: usize = 0;
    while (true) {
        const n = body.stream(&collected.writer, .limited(64 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return http_timeout.translateError(&req, e),
        };
        total += n;
        if (total > max_body_bytes) return error.ResponseTooLarge;
    }

    return .{
        .status = res.head.status,
        .body = try gpa.dupe(u8, collected.written()),
    };
}

const std = @import("std");
const http_timeout = @import("http_timeout.zig");
const Io = std.Io;

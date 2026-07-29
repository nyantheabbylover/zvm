pub fn download(
    gpa: std.mem.Allocator,
    io: Io,
    urls: []const []const u8,
    dest_path: []const u8,
    expected_sha256_hex: ?[]const u8,
    minisign_signature: ?[]const u8,
    label: []const u8,
    progress_parent: std.Progress.Node,
) !void {
    const node = progress_parent.start(label, urls.len);
    defer node.end();

    var last_err: anyerror = error.NoDownloadSources;
    for (urls, 0..) |url, i| {
        debug.log("trying {s}", .{url});
        attempt(
            gpa,
            io,
            url,
            dest_path,
            expected_sha256_hex,
            minisign_signature,
            label,
            node,
        ) catch |err| {
            debug.log("  {s} failed: {s}", .{ url, @errorName(err) });
            last_err = err;
            node.setCompletedItems(i + 1);

            continue;
        };
        debug.log("  {s} succeeded", .{url});

        return;
    }

    return last_err;
}

fn attempt(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    dest_path: []const u8,
    expected_sha256_hex: ?[]const u8,
    minisign_signature: ?[]const u8,
    label: []const u8,
    progress_parent: std.Progress.Node,
) !void {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    http_timeout.install(&req);
    try req.sendBodiless();

    var r_buf: [8 * 1024]u8 = undefined;
    var res = req.receiveHead(&r_buf) catch |err|
        return http_timeout.translateError(&req, err);
    if (res.head.status == .not_found)
        return error.VersionNotFound;
    if (res.head.status != .ok)
        return error.HttpRequestFailed;

    const total: usize = @intCast(res.head.content_length orelse 0);
    const node = progress_parent.start(label, total);
    defer node.end();

    const cwd = Io.Dir.cwd();
    var out_file = try cwd.createFile(io, dest_path, .{});
    defer out_file.close(io);

    var f_buf: [1 << 16]u8 = undefined;
    var fw = out_file.writer(io, &f_buf);

    const d_buf: []u8 = switch (res.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (d_buf.len > 0) gpa.free(d_buf);

    var t_buf: [1 << 16]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const body = res.readerDecompressing(&t_buf, &decompress, d_buf);

    var downloaded: usize = 0;
    while (true) {
        const n = body.stream(
            &fw.interface,
            .limited(1 << 16),
        ) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return http_timeout.translateError(&req, e),
        };
        downloaded += n;
        node.setCompletedItems(downloaded);
    }
    try fw.interface.flush();

    if (expected_sha256_hex) |expected| {
        const bytes = try cwd.readFileAlloc(io, dest_path, gpa, .limited(1 << 30));
        defer gpa.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var hex_buf: [64]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{digest}) catch unreachable;
        if (!std.ascii.eqlIgnoreCase(hex, expected))
            return error.ChecksumMismatch;
    } else if (minisign_signature) |signature| {
        try minisign.verifyFile(io, dest_path, signature);
    }
}

//

const Io = std.Io;

const debug = @import("debug.zig");
const http_timeout = @import("http_timeout.zig");
const minisign = @import("minisign.zig");

const std = @import("std");

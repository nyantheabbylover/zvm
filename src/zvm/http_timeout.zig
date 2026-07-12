const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

const read_timeout_ms = 5 * std.time.ms_per_s;

/// Installs a per-read timeout on the connection used by
/// `request`. 
/// This covers waiting for response headers and every
/// subsequent body read.
/// The standard HTTP client has no request-read timeout
/// in Zig 0.16, so this wraps its underlying stream reader
/// instead.
pub fn install(request: *std.http.Client.Request) void {
    const connection = request.connection orelse return;
    connection.stream_reader.interface.vtable = &.{
        .stream = stream,
        .readVec = readVec,
    };
}

/// `Io.Reader` reports a failed read as
/// `error.ReadFailed` and stores the underlying cause
/// on the stream reader. Recover the timeout at the HTTP
/// boundary so callers can report it clearly.
pub fn translateError(request: *const std.http.Client.Request, err: anyerror) anyerror {
    if (err != error.ReadFailed)
        return err;

    const connection = request.connection orelse return err;
    if (connection.stream_reader.err) |read_err| {
        if (read_err == error.Timeout)
            return error.Timeout;
    }

    return err;
}

fn stream(reader: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const dest = limit.slice(try writer.writableSliceGreedy(1));
    var data: [1][]u8 = .{dest};
    const n = try readVec(reader, &data);
    writer.advance(n);

    return n;
}

fn readVec(reader: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    const stream_reader: *Io.net.Stream.Reader = @alignCast(@fieldParentPtr("interface", reader));
    var iovecs_buffer: [8][]u8 = undefined;
    const dest_n, const data_size = try reader.writableVector(&iovecs_buffer, data);
    const dest = iovecs_buffer[0..dest_n];
    std.debug.assert(dest[0].len > 0);
    const n = readSocket(stream_reader, dest) catch |err| {
        stream_reader.err = err;

        return error.ReadFailed;
    };

    if (n == 0)
        return error.EndOfStream;

    if (n > data_size) {
        reader.end += n - data_size;

        return data_size;
    }

    return n;
}

fn readSocket(stream_reader: *Io.net.Stream.Reader, dest: [][]u8) Io.net.Stream.Reader.Error!usize {
    if (comptime builtin.os.tag == .windows) {
        return readSocketWindows(stream_reader, dest);
    }

    return readSocketPosix(stream_reader, dest);
}

fn readSocketPosix(stream_reader: *Io.net.Stream.Reader, dest: [][]u8) Io.net.Stream.Reader.Error!usize {
    var fds: [1]std.posix.pollfd = .{
        .{
            .fd = stream_reader.stream.socket.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR,
            .revents = 0,
        },
    };

    if (try std.posix.poll(&fds, read_timeout_ms) == 0)
        return error.Timeout;

    return stream_reader.io.vtable.netRead(
        stream_reader.io.userdata,
        stream_reader.stream.socket.handle,
        dest,
    );
}

fn readSocketWindows(stream_reader: *Io.net.Stream.Reader, dest: [][]u8) Io.net.Stream.Reader.Error!usize {
    const Result = union(enum) {
        read: Io.net.Stream.Reader.Error!usize,
        timeout: Io.Cancelable!void,
    };

    var select = Io.Select(Result).init(stream_reader.io, &.{});
    defer select.cancelDiscard();

    select.concurrent(
        .read,
        blockingRead,
        .{
            stream_reader.io,
            stream_reader.stream.socket.handle,
            dest,
        },
    ) catch
        return error.Unexpected;

    select.concurrent(
        .timeout,
        Io.sleep,
        .{
            stream_reader.io,
            .fromMilliseconds(read_timeout_ms),
            .awake,
        },
    ) catch
        return error.Unexpected;

    return switch (try select.await()) {
        .read => |result| result,
        .timeout => |result| {
            try result;

            return error.Timeout;
        },
    };
}

fn blockingRead(
    io: Io,
    socket: std.posix.socket_t,
    dest: [][]u8,
) Io.net.Stream.Reader.Error!usize {
    return io.vtable.netRead(io.userdata, socket, dest);
}

const max_attempts = 6;

pub fn deleteTree(io: Io, dir: Io.Dir, sub_path: []const u8) anyerror!void {
    var attempt: u32 = 0;
    while (true) {
        return dir.deleteTree(io, sub_path) catch |err| {
            attempt += 1;
            if (err != error.AccessDenied or attempt >= max_attempts)
                return err;
            Io.sleep(io, .fromMilliseconds(100 * attempt), .awake) catch {};

            continue;
        };
    }
}

pub fn rename(io: Io, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) anyerror!void {
    var attempt: u32 = 0;
    while (true) {
        return old_dir.rename(
            old_sub_path,
            new_dir,
            new_sub_path,
            io,
        ) catch |err| {
            attempt += 1;
            if (err != error.AccessDenied or attempt >= max_attempts)
                return err;
            Io.sleep(io, .fromMilliseconds(100 * attempt), .awake) catch {};

            continue;
        };
    }
}

//

const Io = std.Io;

const std = @import("std");

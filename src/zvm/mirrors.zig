const mirrors_url = "https://ziglang.org/download/community-mirrors.txt";
const ttl_seconds: i64 = 24 * 60 * 60;

/// Fetches (or serves cached) the community mirror list, shuffled. Any
/// failure just yields an empty list, mirrors are a best-effort speedup,
/// callers always keep ziglang.org itself as the final fallback.
pub fn fetchMirrors(
    gpa: std.mem.Allocator,
    io: Io,
    paths: paths_mod.Paths,
) [][]const u8 {
    const body = cached_fetch.fetch(
        gpa,
        io,
        mirrors_url,
        paths.mirrors_file,
        paths.mirrors_meta_file,
        paths.locks,
        "mirrors",
        ttl_seconds,
    ) catch |err| {
        debug.log(
            "mirror list unavailable ({s}), falling back to ziglang.org directly",
            .{@errorName(err)},
        );

        return &.{};
    };

    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');

    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0)
            continue;
        list.append(gpa, trimmed) catch
            return &.{};
    }

    const items = list.toOwnedSlice(gpa) catch
        return &.{};

    var prng = std.Random.DefaultPrng.init(
        @bitCast(Io.Timestamp.now(io, .real).toMilliseconds()),
    );
    prng.random().shuffle([]const u8, items);

    debug.log("{d} mirror(s) available, shuffled", .{items.len});

    return items;
}

pub fn mirrorUrl(
    gpa: std.mem.Allocator,
    mirror_base: []const u8,
    filename: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        gpa,
        "{s}/{s}?source=zvm",
        .{ mirror_base, filename },
    );
}

//

const Io = std.Io;

const cached_fetch = @import("cached_fetch.zig");
const paths_mod = @import("paths.zig");
const debug = @import("debug.zig");

const std = @import("std");

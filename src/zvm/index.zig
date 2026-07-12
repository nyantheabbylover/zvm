pub const Resolved = struct {
    /// Concrete version (e.g. "master" resolves to the actual dev snapshot version string reported by the index).
    version: []const u8,
    tarball_url: []const u8,
    /// null when the version isn't present in the index. Historical dev
    /// snapshots are verified using their adjacent Minisign signature instead.
    shasum: ?[]const u8,
    size: ?u64,
};

const index_url = "https://ziglang.org/download/index.json";
const ttl_seconds: i64 = 60 * 60;

pub fn fetchIndexObject(gpa: std.mem.Allocator, io: Io, paths: Paths) !std.json.ObjectMap {
    const body = try cached_fetch.fetch(
        gpa,
        io,
        index_url,
        paths.index_file,
        paths.index_meta_file,
        ttl_seconds,
    );
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        body,
        .{},
    );

    return parsed.value.object;
}

/// Resolves a requested version string ("master", "latest", or an exact version) to a concrete download,
/// `minimum_zig_version` is treated as an exact pin, not a semver range.
pub fn resolve(gpa: std.mem.Allocator, io: Io, paths: Paths, requested: []const u8) !Resolved {
    try validateVersion(requested);
    const root = try fetchIndexObject(gpa, io, paths);

    const key = if (std.mem.eql(u8, requested, "latest"))
        latestStableKey(root) orelse return error.NoStableVersionFound
    else
        requested;

    if (try pickFromIndex(root, key)) |r| {
        debug.log(
            "resolved '{s}' -> zig {s} (in index, {s})",
            .{
                requested,
                r.version,
                if (r.shasum != null) "verifiable" else "no shasum",
            },
        );

        return r;
    }

    const r = try createUnlisted(gpa, key);
    debug.log(
        "resolved '{s}' -> zig {s} (not in index, unverified: {s})",
        .{
            requested,
            r.version,
            r.tarball_url,
        },
    );

    return r;
}

fn latestStableKey(root: std.json.ObjectMap) ?[]const u8 {
    var best: ?[]const u8 = null;

    var it = root.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "master")) continue;
        if (best == null or compareStableVersion(key, best.?) == .gt) best = key;
    }

    return best;
}

fn pickFromIndex(root: std.json.ObjectMap, key: []const u8) !?Resolved {
    const entry = root.get(key) orelse return null;
    const obj = entry.object;
    const version = if (obj.get("version")) |v| v.string else key;
    try validateVersion(version);
    const t = obj.get(target.nativeTargetString()) orelse return null;
    const tobj = t.object;
    const tarball = tobj.get("tarball") orelse return null;

    const size: ?u64 = blk: {
        const s = tobj.get("size") orelse break :blk null;
        break :blk switch (s) {
            .integer => |i| @intCast(i),
            else => null,
        };
    };

    return Resolved{
        .version = version,
        .tarball_url = tarball.string,
        .shasum = if (tobj.get("shasum")) |s| s.string else null,
        .size = size,
    };
}

fn createUnlisted(gpa: std.mem.Allocator, version: []const u8) !Resolved {
    const url = try std.fmt.allocPrint(
        gpa,
        "https://ziglang.org/builds/zig-{s}-{s}{s}",
        .{
            target.nativeTargetString(),
            version,
            target.archiveExt(),
        },
    );

    return Resolved{
        .version = version,
        .tarball_url = url,
        .shasum = null,
        .size = null,
    };
}

const Paths = @import("paths.zig").Paths;

const validateVersion = @import("version.zig").validate;
const compareStableVersion = @import("version.zig").compareStable;

const cached_fetch = @import("cached_fetch.zig");
const target = @import("target.zig");
const debug = @import("debug.zig");

const std = @import("std");
const Io = std.Io;

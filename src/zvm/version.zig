/// Validates a version before it is used as a cache directory name or URL
/// component. Zig's released and development builds use semantic versioning;
/// `master` and `latest` are the two supported aliases.
pub fn validate(input: []const u8) !void {
    if (input.len == 0 or input.len > 32) return error.InvalidVersion;
    if (std.mem.eql(u8, input, "master") or std.mem.eql(u8, input, "latest")) return;

    _ = std.SemanticVersion.parse(input) catch return error.InvalidVersion;
}

pub fn looksLikeVersion(arg: []const u8) bool {
    if (arg.len == 0) return false;
    if (std.mem.eql(u8, arg, "master")) return true;
    if (std.mem.eql(u8, arg, "latest")) return true;

    return std.ascii.isDigit(arg[0]);
}

pub fn compareStable(a: []const u8, b: []const u8) std.math.Order {
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const an = ai.next();
        const bn = bi.next();

        if (an == null and bn == null) return .eq;

        const av: u32 = if (an) |s| (std.fmt.parseInt(u32, s, 10) catch 0) else 0;
        const bv: u32 = if (bn) |s| (std.fmt.parseInt(u32, s, 10) catch 0) else 0;

        if (av != bv) return if (av < bv) .lt else .gt;
    }
}

//

const std = @import("std");

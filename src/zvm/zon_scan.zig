const std = @import("std");

//

pub fn findMinimumZigVersion(source: [:0]const u8) ?[]const u8 {
    var tokenizer: std.zig.Tokenizer = .init(source);

    const State = enum {
        none,
        saw_period,
        saw_ident,
        saw_equal,
    };
    var state: State = .none;

    while (true) {
        const t = tokenizer.next();
        if (t.tag == .eof)
            break;
        switch (state) {
            .none => state = if (t.tag == .period) .saw_period else .none,
            .saw_period => {
                const text = source[t.loc.start..t.loc.end];
                state = if (t.tag == .identifier and std.mem.eql(u8, text, "minimum_zig_version"))
                    .saw_ident
                else if (t.tag == .period)
                    .saw_period
                else
                    .none;
            },
            .saw_ident => state = if (t.tag == .equal) .saw_equal else .none,
            .saw_equal => {
                if (t.tag == .string_literal) {
                    const raw = source[t.loc.start..t.loc.end];
                    if (raw.len >= 2)
                        return raw[1 .. raw.len - 1];
                }
                state = .none;
            },
        }
    }

    return null;
}

//

test "findMinimumZigVersion finds the declared version" {
    const source: [:0]const u8 =
        \\.{
        \\    .name = "example",
        \\    .minimum_zig_version = "0.16.0",
        \\};
    ;

    const version = findMinimumZigVersion(source) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("0.16.0", version);
}

test "findMinimumZigVersion ignores comments and string contents" {
    const source: [:0]const u8 =
        \\// .minimum_zig_version = "0.15.0"
        \\ .description = ".minimum_zig_version = \\"0.15.0\\"",
        \\ .minimum_zig_version = "0.16.0",
    ;

    const version = findMinimumZigVersion(source) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("0.16.0", version);
}

test "findMinimumZigVersion returns null when absent" {
    const source: [:0]const u8 =
        \\.{
        \\    .name = "example",
        \\};
    ;

    try std.testing.expect(findMinimumZigVersion(source) == null);
}

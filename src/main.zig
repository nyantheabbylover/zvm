//! The `zig` shim.

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(gpa);
    zvm.debug.initFromEnv(gpa, init.minimal.environ);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const errw: Io.Terminal = .{
        .writer = &stderr_fw.interface,
        .mode = zvm.color.detectMode(io, .stderr(), gpa, init.minimal.environ),
    };

    const paths = zvm.paths.Paths.discover(gpa, init.minimal.environ) catch |e| {
        try zvm.color.print(errw, .red, "zvm: failed to determine cache directory: {s}\n", .{@errorName(e)});
        try errw.writer.flush();

        std.process.exit(1);
    };
    paths.ensureLayout(io) catch |e| {
        try zvm.color.print(errw, .red, "zvm: failed to create {s}: {s}\n", .{ paths.base, @errorName(e) });
        try errw.writer.flush();

        std.process.exit(1);
    };

    var override: ?[]const u8 = null;
    var passthrough_start: usize = 1;
    if (argv.len > 1 and zvm.version.looksLikeVersion(argv[1])) {
        override = argv[1];
        passthrough_start = 2;
    }

    var ctx = zvm.resolve.Context{ .gpa = gpa, .io = io, .paths = paths };

    const resolution = zvm.resolve.resolveVersion(&ctx, override) catch |e| {
        try zvm.color.print(
            errw,
            .red,
            \\zvm: could not determine which zig version to use.
            \\  - pass a version explicitly: zig 0.16.0 build
            \\  - or add "minimum_zig_version" to build.zig.zon
            \\  - or run: zvm default <version>
            \\({s})
            \\
        ,
            .{
                @errorName(e),
            },
        );
        try errw.writer.flush();

        std.process.exit(1);
    };

    const root_progress = std.Progress.start(
        io,
        .{
            .root_name = "zvm",
        },
    );
    const install_result = zvm.resolve.ensureInstalled(
        &ctx,
        resolution.version,
        root_progress,
    ) catch |e| {
        root_progress.end();
        if (zvm.resolve.installErrorHint(e)) |hint| {
            try zvm.color.print(errw, .red, "zvm: could not install zig {s}: {s}\n", .{ resolution.version, hint });
        } else {
            try zvm.color.print(errw, .red, "zvm: failed to install zig {s}: {s}\n", .{ resolution.version, @errorName(e) });
        }
        try errw.writer.flush();

        std.process.exit(1);
    };
    root_progress.end();

    if (!install_result.verified) {
        try zvm.color.print(
            errw,
            .yellow,
            "zvm: warning: zig {s} was installed without checksum or signature verification\n",
            .{install_result.version},
        );
        try errw.writer.flush();
    }

    zvm.resolve.recordUse(&ctx, install_result.version);

    const version_dir = try paths.versionDir(gpa, install_result.version);
    const exe_path = try std.fs.path.join(gpa, &.{ version_dir, zvm.target.exeName() });

    var real_argv: std.ArrayList([]const u8) = .empty;
    try real_argv.append(gpa, exe_path);
    try real_argv.appendSlice(gpa, argv[passthrough_start..]);

    zvm.debug.log("exec: {s}", .{exe_path});
    const code = zvm.exec.run(io, real_argv.items) catch |e| {
        try zvm.color.print(errw, .red, "zvm: failed to launch {s}: {s}\n", .{ exe_path, @errorName(e) });
        try errw.writer.flush();

        std.process.exit(1);
    };
    try errw.writer.flush();

    std.process.exit(code);
}

const zvm = @import("zvm");

const std = @import("std");
const Io = std.Io;

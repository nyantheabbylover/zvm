//! The `zls` shim.

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(gpa);
    var environ = try init.minimal.environ.createMap(gpa);
    defer environ.deinit();
    zvm.debug.initFromEnv(environ);
    zvm.debug.log("zvm {s}", .{zvm.app_version});

    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const errw: Io.Terminal = .{
        .writer = &stderr_fw.interface,
        .mode = zvm.color.detectMode(io, .stderr(), environ),
    };

    const paths = zvm.paths.Paths.discover(
        gpa,
        environ,
    ) catch |e| {
        try zvm.color.print(
            errw,
            .red,
            "zvm: failed to determine cache directory: {t}\n",
            .{e},
        );
        try errw.writer.flush();

        std.process.exit(1);
    };
    paths.ensureLayout(io) catch |e| {
        try zvm.color.print(
            errw,
            .red,
            "zvm: failed to create {s}: {t}\n",
            .{ paths.base, e },
        );
        try errw.writer.flush();

        std.process.exit(1);
    };

    var override: ?[]const u8 = null;
    var passthrough_start: usize = 1;
    if (argv.len > 1 and zvm.version.looksLikeVersion(argv[1])) {
        override = argv[1];
        passthrough_start = 2;
    }

    var ctx = zvm.resolve.Context{
        .gpa = gpa,
        .io = io,
        .paths = paths,
    };

    const resolution = zvm.resolve.resolveVersion(
        &ctx,
        override,
    ) catch |e| {
        try zvm.color.print(
            errw,
            .red,
            \\zvm: could not determine which zig version to use.
            \\  - pass a version explicitly: zls 0.16.0
            \\  - or add "minimum_zig_version" to build.zig.zon
            \\  - or run: zvm default <version>
            \\({t})
            \\
        ,
            .{e},
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
    var use_result = zvm.resolve.ensureInstalledForUse(
        &ctx,
        resolution.version,
        root_progress,
    ) catch |e| {
        root_progress.end();
        if (zvm.resolve.installErrorHint(e)) |hint| {
            try zvm.color.print(
                errw,
                .red,
                "zvm: could not install zig {s}: {s}\n",
                .{ resolution.version, hint },
            );
        } else {
            try zvm.color.print(
                errw,
                .red,
                "zvm: failed to install zig {s}: {t}\n",
                .{ resolution.version, e },
            );
        }
        try errw.writer.flush();

        std.process.exit(1);
    };
    defer use_result.version_lock.release(io);

    const install_result = use_result.install;

    if (!install_result.already_installed and !install_result.verified) {
        try zvm.color.print(
            errw,
            .yellow,
            "zvm: warning: zig {s} was installed without checksum or signature verification\n",
            .{install_result.version},
        );
        try errw.writer.flush();
    }

    // The version lock is already held, so this skips its own acquisition.
    _ = zvm.zls.installLocked(
        &ctx,
        install_result.version,
        root_progress,
    ) catch |e| {
        root_progress.end();
        try zvm.color.print(
            errw,
            .red,
            "zvm: failed to install zls for zig {s}: {t}\n",
            .{ install_result.version, e },
        );
        try errw.writer.flush();

        std.process.exit(1);
    };
    root_progress.end();

    zvm.resolve.recordUse(&ctx, install_result.version);

    const zls_dir = try paths.zlsDir(gpa, install_result.version);
    const exe_path = try std.fs.path.join(gpa, &.{ zls_dir, zvm.target.zlsExeName() });

    var real_argv: std.ArrayList([]const u8) = .empty;
    try real_argv.append(gpa, exe_path);
    try real_argv.appendSlice(gpa, argv[passthrough_start..]);

    zvm.debug.log("exec: {s}", .{exe_path});
    try use_result.version_lock.inheritAcrossExec();
    const code = zvm.exec.run(io, real_argv.items) catch |e| {
        try zvm.color.print(
            errw,
            .red,
            "zvm: failed to launch {s}: {t}\n",
            .{ exe_path, e },
        );
        try errw.writer.flush();

        std.process.exit(1);
    };
    try errw.writer.flush();

    std.process.exit(code);
}

//

const Io = std.Io;

const zvm = @import("zvm");

const std = @import("std");

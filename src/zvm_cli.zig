pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const raw_argv = try init.minimal.args.toSlice(gpa);
    var environ = try init.minimal.environ.createMap(gpa);
    defer environ.deinit();
    zvm.debug.initFromEnv(environ);

    var argv_list: std.ArrayList([]const u8) = .empty;
    var skip_verification = false;
    for (raw_argv) |a| {
        if (std.mem.eql(u8, a, "--verbose") or
            std.mem.eql(u8, a, "-v"))
        {
            zvm.debug.enabled = true;

            continue;
        }

        if (std.mem.eql(u8, a, "--no-verify")) {
            skip_verification = true;

            continue;
        }

        try argv_list.append(gpa, a);
    }
    const argv = argv_list.items;
    zvm.debug.log("zvm {s}", .{zvm.app_version});

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out: Io.Terminal = .{
        .writer = &stdout_fw.interface,
        .mode = zvm.color.detectMode(io, .stdout(), environ),
    };

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

    var ctx = zvm.resolve.Context{
        .gpa = gpa,
        .io = io,
        .paths = paths,
        .skip_verification = skip_verification,
    };

    if (argv.len < 2) {
        try printHelp(out);
        try out.writer.flush();

        return;
    }

    const cmd = argv[1];
    const rest = argv[2..];
    const is_install = std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "add");

    if (skip_verification and !is_install) {
        try zvm.color.print(
            errw,
            .red,
            "zvm: --no-verify is only valid with install/add \n",
            .{},
        );
        try errw.writer.flush();

        std.process.exit(1);
    }

    if (std.mem.eql(u8, cmd, "version") or
        std.mem.eql(u8, cmd, "--version") or
        std.mem.eql(u8, cmd, "-V"))
    {
        try out.writer.print("{s}\n", .{zvm.app_version});
    } else if (is_install) {
        try cmdInstall(&ctx, out, errw, rest);
    } else if (std.mem.eql(u8, cmd, "list") or
        std.mem.eql(u8, cmd, "ls"))
    {
        try cmdList(&ctx, out);
    } else if (std.mem.eql(u8, cmd, "list-remote") or
        std.mem.eql(u8, cmd, "ls-remote"))
    {
        try cmdListRemote(&ctx, out, errw);
    } else if (std.mem.eql(u8, cmd, "remove") or
        std.mem.eql(u8, cmd, "rm") or
        std.mem.eql(u8, cmd, "uninstall"))
    {
        try cmdRemove(&ctx, out, errw, rest);
    } else if (std.mem.eql(u8, cmd, "which")) {
        try cmdWhich(&ctx, out, errw, rest);
    } else if (std.mem.eql(u8, cmd, "default")) {
        try cmdDefault(&ctx, out, errw, rest);
    } else if (std.mem.eql(u8, cmd, "--help") or
        std.mem.eql(u8, cmd, "-h") or
        std.mem.eql(u8, cmd, "help"))
    {
        try printHelp(out);
    } else {
        try zvm.color.print(
            errw,
            .red,
            "zvm: unknown command '{s}'\n\n",
            .{cmd},
        );
        try printHelp(errw);
        try errw.writer.flush();

        std.process.exit(1);
    }

    try out.writer.flush();
    try errw.writer.flush();
}

fn cmdInstall(
    ctx: *zvm.resolve.Context,
    out: Io.Terminal,
    errw: Io.Terminal,
    args: []const []const u8,
) !void {
    const resolution = if (args.len > 0)
        zvm.resolve.Resolution{ .version = args[0], .source = .override }
    else
        zvm.resolve.resolveVersion(ctx, null) catch |e| {
            try zvm.color.print(errw, .red, "zvm: {t}\n", .{e});
            try errw.writer.flush();

            std.process.exit(1);
        };

    const root_progress = std.Progress.start(ctx.io, .{ .root_name = "zvm install" });
    const result = zvm.resolve.ensureInstalled(
        ctx,
        resolution.version,
        root_progress,
    ) catch |e| {
        root_progress.end();
        if (zvm.resolve.installErrorHint(e)) |hint| {
            try zvm.color.print(
                errw,
                .red,
                "zvm: could not install {s}: {s}\n",
                .{ resolution.version, hint },
            );
        } else {
            try zvm.color.print(
                errw,
                .red,
                "zvm: failed to install {s}: {t}\n",
                .{ resolution.version, e },
            );
        }
        try errw.writer.flush();

        std.process.exit(1);
    };
    root_progress.end();

    if (ctx.skip_verification and !result.already_installed) {
        try zvm.color.print(
            out,
            .yellow,
            "warning: installed zig {s} without verification (--no-verify)\n",
            .{result.version},
        );
    } else if (!result.already_installed and !result.verified) {
        try zvm.color.print(
            out,
            .yellow,
            "warning: zig {s} was installed without checksum or signature verification\n",
            .{result.version},
        );
    }

    zvm.resolve.recordUse(ctx, result.version);

    if (result.already_installed) {
        try zvm.color.print(
            out,
            .dim,
            "zig {s} is already installed\n",
            .{result.version},
        );
    } else {
        try zvm.color.print(
            out,
            .green,
            "installed zig {s}\n",
            .{result.version},
        );
    }
}

fn cmdList(
    ctx: *zvm.resolve.Context,
    out: Io.Terminal,
) !void {
    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(
        ctx.io,
        ctx.paths.versions,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.FileNotFound => {
            try out.writer.print(
                "no versions installed yet, run `zvm install <version>`\n",
                .{},
            );

            return;
        },
        else => return err,
    };
    defer dir.close(ctx.io);

    const cfg = zvm.config.load(ctx.gpa, ctx.io, ctx.paths.config_file) catch
        zvm.config.Config{};

    var it = dir.iterate();
    var any = false;
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .directory)
            continue;

        any = true;

        const is_default = cfg.default_version != null and std.mem.eql(u8, cfg.default_version.?, entry.name);
        const is_recent = cfg.last_used_version != null and std.mem.eql(u8, cfg.last_used_version.?, entry.name);
        try zvm.color.print(out, .cyan, "  {s}", .{entry.name});
        if (is_default)
            try zvm.color.print(out, .cyan, "  (default)", .{});
        if (is_recent)
            try zvm.color.print(out, .dim, "  (last used)", .{});
        try out.writer.print("\n", .{});
    }

    if (!any)
        try out.writer.print(
            "no versions installed yet, run `zvm install <version>`\n",
            .{},
        );
}

fn cmdListRemote(
    ctx: *zvm.resolve.Context,
    out: Io.Terminal,
    errw: Io.Terminal,
) !void {
    const root = zvm.index.fetchIndexObject(
        ctx.gpa,
        ctx.io,
        ctx.paths,
    ) catch |e| {
        try zvm.color.print(
            errw,
            .red,
            "zvm: failed to fetch version index: {t}\n",
            .{e},
        );
        try errw.writer.flush();

        std.process.exit(1);
    };

    var list: std.ArrayList([]const u8) = .empty;
    var it = root.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "master"))
            continue;
        try list.append(ctx.gpa, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return zvm.version.compareStable(a, b) == .gt;
        }
    }.lessThan);

    try zvm.color.print(out, .yellow, "master", .{});
    try zvm.color.print(out, .dim, " (dev)\n", .{});
    for (list.items) |v|
        try zvm.color.print(out, .cyan, "{s}\n", .{v});
}

fn cmdRemove(
    ctx: *zvm.resolve.Context,
    out: Io.Terminal,
    errw: Io.Terminal,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        try zvm.color.print(
            errw,
            .red,
            "usage: zvm remove <version>\n",
            .{},
        );
        try errw.writer.flush();

        std.process.exit(1);
    }
    const v = args[0];
    zvm.version.validate(v) catch |e| {
        try zvm.color.print(
            errw,
            .red,
            "zvm: invalid version '{s}': {t}\n",
            .{ v, e },
        );
        try errw.writer.flush();

        std.process.exit(1);
    };
    const dir_path = try ctx.paths.versionDir(ctx.gpa, v);

    var version_lock = zvm.lock.tryAcquireExclusive(
        ctx.gpa,
        ctx.io,
        ctx.paths.locks,
        v,
    ) catch |e| {
        try zvm.color.print(
            errw,
            .red,
            "zvm: failed to lock {s}: {t}\n",
            .{ v, e },
        );
        try errw.writer.flush();

        std.process.exit(1);
    } orelse {
        try zvm.color.print(
            errw,
            .red,
            "zvm: cannot remove {s}: version is currently in use or being installed\n",
            .{v},
        );
        try errw.writer.flush();

        std.process.exit(1);
    };
    defer version_lock.release(ctx.io);

    if (!zvm.resolve.isInstalled(ctx, dir_path)) {
        try zvm.color.print(
            out,
            .dim,
            "zig {s} is not installed\n",
            .{v},
        );

        return;
    }

    const root_progress = std.Progress.start(ctx.io, .{ .root_name = "zvm remove" });
    const label = try std.fmt.allocPrint(ctx.gpa, "remove zig {s}", .{v});
    const node = root_progress.start(label, 0);
    zvm.retry.deleteTree(ctx.io, Io.Dir.cwd(), dir_path) catch |e| {
        node.end();
        root_progress.end();
        try zvm.color.print(
            errw,
            .red,
            "zvm: failed to remove {s}: {t}\n",
            .{ v, e },
        );
        try errw.writer.flush();

        std.process.exit(1);
    };
    node.end();
    root_progress.end();
    try zvm.color.print(
        out,
        .green,
        "removed zig {s}\n",
        .{v},
    );
}

fn cmdWhich(
    ctx: *zvm.resolve.Context,
    out: Io.Terminal,
    errw: Io.Terminal,
    args: []const []const u8,
) !void {
    const override: ?[]const u8 = if (args.len > 0) args[0] else null;
    const resolution = zvm.resolve.resolveVersion(ctx, override) catch |e| {
        try zvm.color.print(errw, .red, "zvm: {t}\n", .{e});
        try errw.writer.flush();

        std.process.exit(1);
    };
    const dir_path = try ctx.paths.versionDir(ctx.gpa, resolution.version);
    const installed = zvm.resolve.isInstalled(ctx, dir_path);

    try zvm.color.print(out, .cyan, "{s}\n", .{resolution.version});
    try zvm.color.print(out, .dim, "  source: ", .{});
    try out.writer.print("{s}", .{@tagName(resolution.source)});
    if (resolution.project_file) |p| {
        try zvm.color.print(out, .dim, " ({s})", .{p});
    }
    try zvm.color.print(out, .dim, "\n  status: ", .{});
    if (installed) {
        try zvm.color.print(out, .green, "installed", .{});
    } else {
        try zvm.color.print(out, .dim, "not installed", .{});
    }
    try out.writer.print("\n", .{});
}

fn cmdDefault(
    ctx: *zvm.resolve.Context,
    out: Io.Terminal,
    errw: Io.Terminal,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        const cfg = zvm.config.load(ctx.gpa, ctx.io, ctx.paths.config_file) catch
            zvm.config.Config{};
        if (cfg.default_version) |d| {
            try zvm.color.print(out, .cyan, "{s}\n", .{d});
        } else {
            try zvm.color.print(out, .dim, "(none set)\n", .{});
        }

        return;
    }

    if (std.mem.eql(u8, args[0], "clear")) {
        try zvm.config.setDefault(ctx.gpa, ctx.io, ctx.paths, null);
        try zvm.color.print(out, .green, "default cleared\n", .{});

        return;
    }

    zvm.version.validate(args[0]) catch |e| {
        try zvm.color.print(
            errw,
            .red,
            "zvm: invalid version '{s}': {t}\n",
            .{ args[0], e },
        );
        try errw.writer.flush();

        std.process.exit(1);
    };

    try zvm.config.setDefault(ctx.gpa, ctx.io, ctx.paths, args[0]);
    try zvm.color.print(out, .green, "default set to {s}\n", .{args[0]});
}

fn printHelp(t: Io.Terminal) !void {
    try zvm.color.print(t, .cyan, "zvm", .{});
    try zvm.color.print(t, .dim, " {s}\n", .{zvm.app_version});

    try zvm.color.print(t, .yellow, "Usage:\n", .{});
    try zvm.color.print(t, .cyan, "  zvm <command>", .{});
    try t.writer.print(" [arguments]\n\n", .{});

    try zvm.color.print(t, .yellow, "Commands:\n", .{});
    try helpEntry(t, "zvm install [version]", "Download and cache a Zig version (auto-detected if omitted)");
    try helpEntry(t, "zvm list", "List installed versions");
    try helpEntry(t, "zvm list-remote", "List versions available for download");
    try helpEntry(t, "zvm remove <version>", "Delete an installed version");
    try helpEntry(t, "zvm which [version]", "Show which version would be used, and why");
    try helpEntry(t, "zvm default [version]", "Show or set the fallback version");
    try helpEntry(t, "zvm default clear", "Clear the fallback version");
    try helpEntry(t, "zvm version", "Show the zvm version");
    try t.writer.print("\n", .{});

    try zvm.color.print(t, .yellow, "Options:\n", .{});
    try helpEntry(t, "--verbose", "Show version resolution, mirror, and cache decisions");
    try helpEntry(t, "--no-verify", "Skip verification for install/add (unsafe)");
    try t.writer.print("\n", .{});

    try zvm.color.print(t, .dim, "The `zig` shim auto-selects a version from build.zig.zon.\n", .{});
    try zvm.color.print(t, .dim, "Override it with `zig 0.16.0 build`. Set ZVM_DEBUG=1 for shim debug output.\n", .{});
    try zvm.color.print(t, .dim, "The shim cannot take --verbose itself as the remaining arguments go to Zig.\n", .{});
}

fn helpEntry(t: Io.Terminal, command: []const u8, description: []const u8) !void {
    try zvm.color.print(t, .cyan, "  {s}", .{command});
    const padding = if (command.len < 24) 24 - command.len else 1;
    try t.writer.splatByteAll(' ', padding);
    try t.writer.print("{s}\n", .{description});
}

//

const Io = std.Io;

const zvm = @import("zvm");

const std = @import("std");

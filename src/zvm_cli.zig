pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const raw_argv = try init.minimal.args.toSlice(gpa);
    zvm.debug.initFromEnv(gpa, init.minimal.environ);

    var argv_list: std.ArrayList([]const u8) = .empty;
    var skip_verification = false;
    for (raw_argv) |a| {
        if (std.mem.eql(u8, a, "--verbose")) {
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

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out: Io.Terminal = .{
        .writer = &stdout_fw.interface,
        .mode = zvm.color.detectMode(io, .stdout(), gpa, init.minimal.environ),
    };

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

    var ctx = zvm.resolve.Context{
        .gpa = gpa,
        .io = io,
        .paths = paths,
        .skip_verification = skip_verification,
    };

    if (argv.len < 2) {
        try printHelp(out.writer);
        try out.writer.flush();

        return;
    }

    const cmd = argv[1];
    const rest = argv[2..];
    const is_install = std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "add");

    if (skip_verification and !is_install) {
        try zvm.color.print(errw, .red, "zvm: --no-verify is only valid with install/add \n", .{});
        try errw.writer.flush();

        std.process.exit(1);
    }

    if (is_install) {
        try cmdInstall(&ctx, out, errw, rest);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        try cmdList(&ctx, out);
    } else if (std.mem.eql(u8, cmd, "list-remote") or std.mem.eql(u8, cmd, "ls-remote")) {
        try cmdListRemote(&ctx, out, errw);
    } else if (std.mem.eql(u8, cmd, "remove") or std.mem.eql(u8, cmd, "rm") or std.mem.eql(u8, cmd, "uninstall")) {
        try cmdRemove(&ctx, out, errw, rest);
    } else if (std.mem.eql(u8, cmd, "which")) {
        try cmdWhich(&ctx, out, errw, rest);
    } else if (std.mem.eql(u8, cmd, "default")) {
        try cmdDefault(&ctx, out, errw, rest);
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        try printHelp(out.writer);
    } else {
        try zvm.color.print(errw, .red, "zvm: unknown command '{s}'\n\n", .{cmd});
        try printHelp(errw.writer);
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
            try zvm.color.print(errw, .red, "zvm: {s}\n", .{@errorName(e)});
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
            try zvm.color.print(errw, .red, "zvm: could not install {s}: {s}\n", .{ resolution.version, hint });
        } else {
            try zvm.color.print(errw, .red, "zvm: failed to install {s}: {s}\n", .{ resolution.version, @errorName(e) });
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
    } else if (!result.verified) {
        try zvm.color.print(
            out,
            .yellow,
            "warning: zig {s} was installed without checksum or signature verification\n",
            .{
                result.version,
            },
        );
    }

    zvm.resolve.recordUse(ctx, result.version);

    if (result.already_installed) {
        try zvm.color.print(out, .dim, "zig {s} is already installed\n", .{result.version});
    } else {
        try zvm.color.print(out, .green, "installed zig {s}\n", .{result.version});
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
            try out.writer.print("no versions installed yet, run `zvm install <version>`\n", .{});

            return;
        },
        else => return err,
    };
    defer dir.close(ctx.io);

    const cfg = zvm.config.load(ctx.gpa, ctx.io, ctx.paths.config_file) catch zvm.config.Config{};

    var it = dir.iterate();
    var any = false;
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .directory) continue;

        any = true;

        const is_default = cfg.default_version != null and std.mem.eql(u8, cfg.default_version.?, entry.name);
        const is_recent = cfg.last_used_version != null and std.mem.eql(u8, cfg.last_used_version.?, entry.name);
        try out.writer.print("  {s}", .{entry.name});
        if (is_default) try zvm.color.print(out, .cyan, "  (default)", .{});
        if (is_recent) try zvm.color.print(out, .dim, "  (last used)", .{});
        try out.writer.print("\n", .{});
    }

    if (!any) try out.writer.print("no versions installed yet, run `zvm install <version>`\n", .{});
}

fn cmdListRemote(
    ctx: *zvm.resolve.Context,
    out: Io.Terminal,
    errw: Io.Terminal,
) !void {
    const root = zvm.index.fetchIndexObject(ctx.gpa, ctx.io, ctx.paths) catch |e| {
        try zvm.color.print(errw, .red, "zvm: failed to fetch version index: {s}\n", .{@errorName(e)});
        try errw.writer.flush();

        std.process.exit(1);
    };

    var list: std.ArrayList([]const u8) = .empty;
    var it = root.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "master")) continue;
        try list.append(ctx.gpa, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return zvm.version.compareStable(a, b) == .gt;
        }
    }.lessThan);

    try out.writer.print("master (dev)\n", .{});
    for (list.items) |v| try out.writer.print("{s}\n", .{v});
}

fn cmdRemove(
    ctx: *zvm.resolve.Context,
    out: Io.Terminal,
    errw: Io.Terminal,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        try zvm.color.print(errw, .red, "usage: zvm remove <version>\n", .{});
        try errw.writer.flush();

        std.process.exit(1);
    }
    const v = args[0];
    zvm.version.validate(v) catch |e| {
        try zvm.color.print(errw, .red, "zvm: invalid version '{s}': {s}\n", .{ v, @errorName(e) });
        try errw.writer.flush();

        std.process.exit(1);
    };
    const dir_path = try ctx.paths.versionDir(ctx.gpa, v);

    if (!zvm.resolve.isInstalled(ctx, dir_path)) {
        try zvm.color.print(out, .dim, "zig {s} is not installed\n", .{v});

        return;
    }

    const root_progress = std.Progress.start(ctx.io, .{ .root_name = "zvm remove" });
    const label = try std.fmt.allocPrint(ctx.gpa, "remove zig {s}", .{v});
    const node = root_progress.start(label, 0);
    zvm.retry.deleteTree(ctx.io, Io.Dir.cwd(), dir_path) catch |e| {
        node.end();
        root_progress.end();
        try zvm.color.print(errw, .red, "zvm: failed to remove {s}: {s}\n", .{ v, @errorName(e) });
        try errw.writer.flush();

        std.process.exit(1);
    };
    node.end();
    root_progress.end();
    try zvm.color.print(out, .green, "removed zig {s}\n", .{v});
}

fn cmdWhich(
    ctx: *zvm.resolve.Context,
    out: Io.Terminal,
    errw: Io.Terminal,
    args: []const []const u8,
) !void {
    const override: ?[]const u8 = if (args.len > 0) args[0] else null;
    const resolution = zvm.resolve.resolveVersion(ctx, override) catch |e| {
        try zvm.color.print(errw, .red, "zvm: {s}\n", .{@errorName(e)});
        try errw.writer.flush();

        std.process.exit(1);
    };
    const dir_path = try ctx.paths.versionDir(ctx.gpa, resolution.version);
    const installed = zvm.resolve.isInstalled(ctx, dir_path);

    try out.writer.print("{s}\n  source: {s}", .{ resolution.version, @tagName(resolution.source) });
    if (resolution.project_file) |p| try out.writer.print(" ({s})", .{p});
    try out.writer.print("\n  status: ", .{});
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
        const cfg = zvm.config.load(ctx.gpa, ctx.io, ctx.paths.config_file) catch zvm.config.Config{};
        if (cfg.default_version) |d| try out.writer.print("{s}\n", .{d}) else try zvm.color.print(out, .dim, "(none set)\n", .{});

        return;
    }

    var cfg = zvm.config.load(ctx.gpa, ctx.io, ctx.paths.config_file) catch zvm.config.Config{};
    if (std.mem.eql(u8, args[0], "clear")) {
        cfg.default_version = null;
        try zvm.config.save(ctx.gpa, ctx.io, ctx.paths.config_file, cfg);
        try zvm.color.print(out, .green, "default cleared\n", .{});

        return;
    }

    zvm.version.validate(args[0]) catch |e| {
        try zvm.color.print(errw, .red, "zvm: invalid version '{s}': {s}\n", .{ args[0], @errorName(e) });
        try errw.writer.flush();

        std.process.exit(1);
    };

    cfg.default_version = args[0];
    try zvm.config.save(ctx.gpa, ctx.io, ctx.paths.config_file, cfg);
    try zvm.color.print(out, .green, "default set to {s}\n", .{args[0]});
}

fn printHelp(w: *Io.Writer) !void {
    try w.print(
        \\zvm -- a lightweight Zig version manager
        \\
        \\Usage:
        \\  zvm install [version]     Download and cache a zig version (auto-detected if omitted)
        \\  zvm list                  List installed versions
        \\  zvm list-remote           List versions available for download
        \\  zvm remove <version>      Delete an installed version
        \\  zvm which [version]       Show which version would be used, and why
        \\  zvm default [version]     Show or set the fallback version
        \\  zvm default clear         Clear the fallback version
        \\
        \\  --verbose                  Show version resolution / mirror / cache decisions
        \\  --no-verify                Skip SHA-256 and Minisign verification for install/add (unsafe)
        \\
        \\The `zig` shim auto-selects a version from build.zig.zon,
        \\or you can override it: `zig 0.16.0 build`. Set ZVM_DEBUG=1 to get the
        \\same verbose output from the shim (it can't take --verbose itself --
        \\everything after it passes straight through to the real compiler).
        \\
    , .{});
}

const zvm = @import("zvm");

const std = @import("std");
const Io = std.Io;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_version = packageVersion(b);
    const zls_supported = switch (target.result.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    };

    const mod = b.addModule("zvm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const options = b.addOptions();
    options.addOption([]const u8, "app_version", app_version);
    mod.addOptions("build_options", options);

    const zig_shim = b.addExecutable(.{
        .name = "zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .imports = &.{
                .{ .name = "zvm", .module = mod },
            },
        }),
    });
    b.installArtifact(zig_shim);

    const zvm_cli = b.addExecutable(.{
        .name = "zvm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zvm_cli.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .imports = &.{
                .{
                    .name = "zvm",
                    .module = mod,
                },
            },
        }),
    });
    b.installArtifact(zvm_cli);

    if (zls_supported) {
        const zls_shim = b.addExecutable(.{
            .name = "zls",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/zls_shim.zig"),
                .target = target,
                .optimize = optimize,
                .strip = optimize != .Debug,
                .imports = &.{
                    .{ .name = "zvm", .module = mod },
                },
            }),
        });
        b.installArtifact(zls_shim);
    }

    const run_step = b.step("run", "Run the zvm CLI");
    const run_cmd = b.addRunArtifact(zvm_cli);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}

fn packageVersion(b: *std.Build) []const u8 {
    const zon = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        "build.zig.zon",
        b.allocator,
        .limited(64 * 1024),
    ) catch |err| std.debug.panic(
        "unable to read build.zig.zon: {t}",
        .{err},
    );
    const prefix = ".version = \"";
    const start = std.mem.indexOf(u8, zon, prefix) orelse
        @panic("build.zig.zon is missing .version");
    const value = zon[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, value, '"') orelse
        @panic("build.zig.zon has an invalid .version");

    return value[0..end];
}

const std = @import("std");

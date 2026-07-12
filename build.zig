pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zvm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const zig_shim = b.addExecutable(.{
        .name = "zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = b.release_mode != .off,
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
            .strip = b.release_mode != .off,
            .imports = &.{
                .{
                    .name = "zvm",
                    .module = mod,
                },
            },
        }),
    });
    b.installArtifact(zvm_cli);

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

const std = @import("std");

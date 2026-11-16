const std = @import("std");
const sdk_build = @import("parabellum_sdk");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk_dep = b.dependency("parabellum_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const libs_dep = b.dependency("parabellum_libs", .{
        .target = target,
        .optimize = optimize,
    });

    const vfs_mod = libs_dep.module("vfs");

    // Task catalog shared library (`libvault.so`) loaded by Parabellum engine via pipeline.yaml.
    // Zero compile-time dependency on `lib-gdrive` or `lib-gdrive-vfs` (configured dynamically).
    const plugin_so = sdk_build.addTaskPlugin(b, sdk_dep, .{
        .name = "vault",
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
    plugin_so.root_module.addImport("vfs", vfs_mod);
    b.installArtifact(plugin_so);

    const daemon_state_mod = b.createModule(.{
        .root_source_file = b.path("src/DaemonState.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vfs", .module = vfs_mod },
        },
    });

    const test_step = b.step("test", "Run vault plugin and daemon tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vfs", .module = vfs_mod },
                .{ .name = "DaemonState", .module = daemon_state_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}

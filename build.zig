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
    const tika_mod = libs_dep.module("tika");

    // Task catalog shared library (`libvault.so`) loaded by Parabellum engine via pipeline.yaml.
    // Zero compile-time dependency on `sqlite`, `lib-gdrive`, or `lib-gdrive-vfs`
    // (managed by `driver/sqlite` + `configs/schemas.yaml` and `driver/gdrive_store` at runtime).
    const plugin_so = sdk_build.addTaskPlugin(b, sdk_dep, .{
        .name = "vault",
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
    plugin_so.root_module.addImport("vfs", vfs_mod);
    plugin_so.root_module.addImport("tika", tika_mod);
    b.installArtifact(plugin_so);

    const vault_app_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parabellum_sdk", .module = sdk_dep.module("parabellum_sdk") },
            .{ .name = "vfs", .module = vfs_mod },
            .{ .name = "tika", .module = tika_mod },
        },
    });

    const test_step = b.step("test", "Run vault plugin and daemon tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "parabellum_sdk", .module = sdk_dep.module("parabellum_sdk") },
                .{ .name = "vfs", .module = vfs_mod },
                .{ .name = "tika", .module = tika_mod },
                .{ .name = "vault_app", .module = vault_app_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}

const sdk = @import("parabellum_sdk");
const abi = sdk.task;

const container = @import("container.zig");
pub const VaultContext = container.VaultContext;
pub const VaultPluginContainer = container.VaultPluginContainer;

pub const task_mount = @import("tasks/mount.zig");
pub const task_catalog_read = @import("tasks/catalog_read.zig");
pub const task_catalog_write = @import("tasks/catalog_write.zig");
pub const task_write = @import("tasks/write_data.zig");
pub const task_read = @import("tasks/read_data.zig");
pub const task_gc = @import("tasks/gc.zig");

pub const MountService = task_mount.MountService;
pub const CatalogReadService = task_catalog_read.CatalogReadService;
pub const CatalogWriteService = task_catalog_write.CatalogWriteService;
pub const WriteDataService = task_write.WriteDataService;
pub const ReadDataService = task_read.ReadDataService;
pub const GcService = task_gc.GcService;

pub const tasks = [_]sdk.abi.task.TaskDescriptor_ABI{
    VaultPluginContainer.defineTaskService(MountService, .{ .name = "vfs_mount" }),
    VaultPluginContainer.defineTaskService(CatalogReadService, .{ .name = "vfs_catalog_read" }),
    VaultPluginContainer.defineTaskService(CatalogWriteService, .{ .name = "vfs_catalog_write" }),
    VaultPluginContainer.defineTaskService(WriteDataService, .{ .name = "vfs_write" }),
    VaultPluginContainer.defineTaskService(ReadDataService, .{ .name = "vfs_read" }),
    VaultPluginContainer.defineTaskService(GcService, .{ .name = "vfs_gc" }),
};

pub const manifest: sdk.abi.task.ModuleManifest_ABI = .{
    .abi_version = sdk.abi.task.ABI_VERSION,
    .module_name = "vault",
    .module_version = .{ .major = 0, .minor = 2, .patch = 0 },
    .tasks_ptr = &tasks,
    .tasks_len = tasks.len,
};

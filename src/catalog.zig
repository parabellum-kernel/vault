const sdk = @import("parabellum_sdk");
const abi = sdk.task;

const container = @import("container.zig");
pub const VaultContext = container.VaultContext;
pub const VaultPluginContainer = container.VaultPluginContainer;

pub const task_init = @import("tasks/init_vault.zig");
pub const task_mkdir = @import("tasks/mkdir.zig");
pub const task_ls = @import("tasks/list_dir.zig");
pub const task_upload = @import("tasks/upload_file.zig");
pub const task_read = @import("tasks/read_range.zig");
pub const task_delete = @import("tasks/delete_inode.zig");
pub const task_quotas = @import("tasks/get_quotas.zig");
pub const task_gc = @import("tasks/run_gc.zig");
pub const task_refresh = @import("tasks/refresh_catalog.zig");
pub const task_rename = @import("tasks/rename_inode.zig");
pub const task_write_packed = @import("tasks/write_packed.zig");
pub const task_part_create = @import("tasks/partition_create.zig");
pub const task_part_resize = @import("tasks/partition_resize.zig");
pub const task_metrics = @import("tasks/get_metrics.zig");
pub const task_jobs = @import("tasks/enqueue_job.zig");
pub const task_stream = @import("tasks/stream.zig");

pub const InitVaultService = task_init.InitVaultService;
pub const MkdirService = task_mkdir.MkdirService;
pub const ListDirService = task_ls.ListDirService;
pub const UploadFileService = task_upload.UploadFileService;
pub const ReadRangeService = task_read.ReadRangeService;
pub const DeleteInodeService = task_delete.DeleteInodeService;
pub const GetQuotasService = task_quotas.GetQuotasService;
pub const RunGcService = task_gc.RunGcService;
pub const RefreshCatalogService = task_refresh.RefreshCatalogService;
pub const RenameInodeService = task_rename.RenameInodeService;
pub const WritePackedService = task_write_packed.WritePackedService;
pub const PartitionCreateService = task_part_create.PartitionCreateService;
pub const PartitionResizeService = task_part_resize.PartitionResizeService;
pub const GetMetricsService = task_metrics.GetMetricsService;
pub const EnqueueJobService = task_jobs.EnqueueJobService;
pub const StreamRangeService = task_stream.StreamRangeService;

pub const tasks = [_]abi.TaskDescriptor_ABI{
    VaultPluginContainer.defineTaskService(InitVaultService, .{ .name = "vault_init" }),
    VaultPluginContainer.defineTaskService(MkdirService, .{ .name = "vault_mkdir" }),
    VaultPluginContainer.defineTaskService(ListDirService, .{ .name = "vault_ls" }),
    VaultPluginContainer.defineTaskService(UploadFileService, .{ .name = "vault_upload" }),
    VaultPluginContainer.defineTaskService(ReadRangeService, .{ .name = "vault_read" }),
    VaultPluginContainer.defineTaskService(DeleteInodeService, .{ .name = "vault_delete" }),
    VaultPluginContainer.defineTaskService(GetQuotasService, .{ .name = "vault_quotas" }),
    VaultPluginContainer.defineTaskService(RunGcService, .{ .name = "vault_gc" }),
    VaultPluginContainer.defineTaskService(RefreshCatalogService, .{ .name = "vault_refresh" }),
    VaultPluginContainer.defineTaskService(RenameInodeService, .{ .name = "vault_rename" }),
    VaultPluginContainer.defineTaskService(WritePackedService, .{ .name = "vault_write_packed" }),
    VaultPluginContainer.defineTaskService(PartitionCreateService, .{ .name = "vault_partition_create" }),
    VaultPluginContainer.defineTaskService(PartitionResizeService, .{ .name = "vault_partition_resize" }),
    VaultPluginContainer.defineTaskService(GetMetricsService, .{ .name = "vault_metrics" }),
    VaultPluginContainer.defineTaskService(EnqueueJobService, .{ .name = "vault_jobs" }),
    VaultPluginContainer.defineTaskService(StreamRangeService, .{ .name = "vault_stream" }),
};

pub const manifest: abi.ModuleManifest_ABI = .{
    .abi_version = abi.ABI_VERSION,
    .module_name = "vault",
    .module_version = .{ .major = 0, .minor = 1, .patch = 0 },
    .tasks_ptr = &tasks,
    .tasks_len = tasks.len,
};

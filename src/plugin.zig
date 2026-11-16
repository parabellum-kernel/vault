const std = @import("std");
const sdk = @import("parabellum_sdk");
const vfs = @import("vfs");
const DaemonState = @import("DaemonState.zig");

const task_abi = sdk.task;

/// Parabellum Task Plugin entrypoint for `vault` (`libvault.so`).
/// Storage backends (e.g. `gdrive_store`) are bound at runtime via `configs/pipeline.yaml`.
pub const VaultCatalog = struct {
    pub fn verifyLinkage() void {
        _ = vfs.Vault;
        _ = DaemonState;
    }
};

const empty_tasks = [0]task_abi.TaskDescriptor_ABI{};

pub const manifest: task_abi.ModuleManifest_ABI = .{
    .abi_version = task_abi.ABI_VERSION,
    .module_name = "vault",
    .module_version = .{ .major = 0, .minor = 1, .patch = 0 },
    .tasks_ptr = &empty_tasks,
    .tasks_len = 0,
};

comptime {
    @export(&manifest, .{ .name = task_abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

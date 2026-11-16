const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("DaemonState.zig");
const AppConfig = @import("config.zig").AppConfig;

const task_abi = sdk.task;
const task_sdk = sdk.task.sdk;

var global_state_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var global_state: ?DaemonState = null;

pub fn acquireGlobalState() *DaemonState {
    while (global_state_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
    if (global_state == null) {
        global_state = DaemonState.init(
            std.heap.c_allocator,
            std.Io.Threaded.global_single_threaded.io(),
        );
    }
    return &global_state.?;
}

pub fn releaseGlobalState() void {
    global_state_lock.store(false, .release);
}

pub fn getOrMountVault(state: *DaemonState, vault_id: []const u8, device_id: []const u8) !*DaemonState.VaultEntry {
    if (state.getVault(vault_id)) |existing| return existing;

    var cfg = try AppConfig.load(state.allocator, state.io, "configs/.env", "configs/vault.yaml");
    defer cfg.deinit(state.allocator);

    const effective_dev = if (std.mem.eql(u8, device_id, "vault-desktop-01")) cfg.device_id else device_id;
    const entry = try state.createInMemoryVault(vault_id, effective_dev, 1700000000);

    // Provision configured logical partitions from configs/vault.yaml if mounting the configured vault.
    if (std.mem.eql(u8, vault_id, cfg.vault_id)) {
        for (cfg.partitions) |p| {
            entry.partitions.createPartition(
                &entry.vault,
                p.name,
                p.root_folder,
                p.quota_gb * 1024 * 1024 * 1024,
                p.policy_kind,
                &.{},
                1700000000,
            ) catch {};
        }
    }
    return entry;
}

/// Per-task DI Context injected into every `vault` `Service` via `VaultPluginContainer`.
pub const VaultContext = struct {
    alloc: std.mem.Allocator = undefined,
    logger: task_abi.Logger = undefined,
    state: *DaemonState = undefined,

    pub fn init(self: *VaultContext, alloc: std.mem.Allocator, ctx: task_abi.TaskContext) !void {
        self.* = .{
            .alloc = alloc,
            .logger = task_abi.Logger.init(ctx.raw),
            .state = acquireGlobalState(),
        };
    }

    pub fn deinit(_: *VaultContext) void {
        releaseGlobalState();
    }
};

pub const VaultPluginContainer = task_sdk.DiContainer(VaultContext);

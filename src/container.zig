const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("DaemonState.zig");

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
    return state.createInMemoryVault(vault_id, device_id, 1700000000);
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

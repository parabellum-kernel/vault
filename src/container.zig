const std = @import("std");
const sdk = @import("parabellum_sdk");
const VaultState = @import("VaultState.zig");
const AppConfig = @import("config.zig").AppConfig;

const task_abi = sdk.abi.task;
const task_sdk = sdk.task;
const driver_abi = sdk.abi.driver;

var global_state_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var global_threaded_io: ?std.Io.Threaded = null;
var global_state: ?VaultState = null;

pub fn acquireGlobalState() *VaultState {
    while (global_state_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
    if (global_threaded_io == null) {
        global_threaded_io = std.Io.Threaded.init(std.heap.c_allocator, .{
            .environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } },
        });
    }
    if (global_state == null) {
        global_state = VaultState.init(
            std.heap.c_allocator,
            global_threaded_io.?.io(),
        );
    }
    return &global_state.?;
}

pub fn releaseGlobalState() void {
    global_state_lock.store(false, .release);
}

pub fn getOrMountVault(state: *VaultState, vault_id: []const u8, device_id: []const u8) !*VaultState.VaultEntry {
    if (state.getVault(vault_id)) |existing| return existing;

    var cfg = try AppConfig.load(state.allocator, state.io, "configs/.env", "configs/vault.yaml");
    defer cfg.deinit(state.allocator);

    const now_s = VaultState.unixNow(state.io);
    const effective_dev = if (std.mem.eql(u8, device_id, "vault-desktop-01")) cfg.device_id else device_id;
    const entry = if (state.catalog_repo != null and state.blob_repo != null)
        try state.mountConfiguredVault(
            vault_id,
            effective_dev,
            cfg.device_key_path,
            state.catalog_repo.?.handle,
            state.catalog_repo.?.vtable,
            state.blob_repo.?.handle,
            state.blob_repo.?.vtable,
            now_s,
        )
    else
        try state.createInMemoryVault(vault_id, effective_dev, now_s);

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
                now_s,
            ) catch {};
        }
    }
    return entry;
}

pub const ProgressReporter = struct {
    raw_ctx: ?*task_abi.TaskContext_ABI = null,
    report_fn: ?*const fn (ctx: *task_abi.TaskContext_ABI, done: u64, total: u64) callconv(.c) void = null,

    pub fn report(self: ProgressReporter, done: u64, total: u64) void {
        if (self.report_fn) |f| {
            if (self.raw_ctx) |c| f(c, done, total);
        }
    }
};

/// Per-task DI Context injected into every `vault` `Service` via `VaultPluginContainer`.
pub const VaultContext = struct {
    alloc: std.mem.Allocator = undefined,
    logger: task_sdk.Logger = undefined,
    state: *VaultState = undefined,
    catalog_repo: ?VaultState.RepoRef = null,
    blob_repo: ?VaultState.RepoRef = null,
    local_fs_repo: ?VaultState.RepoRef = null,
    progress: ProgressReporter = .{},

    fn resolveRepo(ctx: task_sdk.TaskContext, id: [*:0]const u8) ?VaultState.RepoRef {
        const get_repo = ctx.raw.host.get_repository orelse return null;
        var raw_handle: ?*anyopaque = null;
        var raw_vtable: ?*const anyopaque = null;
        if (get_repo(ctx.raw, id, &raw_handle, &raw_vtable) != .ok) return null;
        const h = raw_handle orelse return null;
        const v = raw_vtable orelse return null;
        return .{
            .handle = @ptrCast(@alignCast(h)),
            .vtable = @ptrCast(@alignCast(v)),
        };
    }

    pub fn init(self: *VaultContext, alloc: std.mem.Allocator, ctx: task_sdk.TaskContext) !void {
        const state = acquireGlobalState();
        const cat_repo = resolveRepo(ctx, "vfs_catalog_db");
        const blob_repo = resolveRepo(ctx, "gdrive_primary");
        const local_fs_repo = resolveRepo(ctx, "local_fs");
        if (state.catalog_repo == null) state.catalog_repo = cat_repo;
        if (state.blob_repo == null) state.blob_repo = blob_repo;

        self.* = .{
            .alloc = alloc,
            .logger = task_sdk.Logger.init(ctx.raw),
            .state = state,
            .catalog_repo = cat_repo,
            .blob_repo = blob_repo,
            .local_fs_repo = local_fs_repo,
            .progress = .{
                .raw_ctx = ctx.raw,
                .report_fn = ctx.raw.host.report_progress,
            },
        };
    }

    pub fn deinit(_: *VaultContext) void {
        releaseGlobalState();
    }
};

pub const VaultPluginContainer = task_sdk.DiContainer(VaultContext);

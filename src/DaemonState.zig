const std = @import("std");
const vfs = @import("vfs");
const PartitionManager = @import("PartitionManager.zig");

/// Central in-process state owned by the Vault Daemon (`ARCH-037D`).
/// Holds all open `vfs.Vault` instances and the asynchronous job queue.
const DaemonState = @This();

pub const JobKind = enum { upload, download, sync, gc };
pub const JobStatus = enum { queued, running, completed, failed };

pub const Job = struct {
    id: u64,
    vault_id: []u8,
    kind: JobKind,
    status: JobStatus = .queued,
    target_path: []u8,
    created_at: i64,

    pub fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        allocator.free(self.vault_id);
        allocator.free(self.target_path);
    }
};

pub const VaultEntry = struct {
    vault: vfs.Vault,
    catalog: vfs.InMemoryCatalog,
    partitions: PartitionManager,
    mem_store: ?vfs.InMemoryBlobStore = null,

    pub fn deinit(self: *VaultEntry) void {
        self.partitions.deinit();
        self.vault.deinit();
        self.catalog.deinit();
        if (self.mem_store) |*ms| ms.deinit();
    }
};

allocator: std.mem.Allocator,
io: std.Io,
vaults: std.StringHashMapUnmanaged(*VaultEntry) = .empty,
jobs: std.ArrayListUnmanaged(Job) = .empty,
next_job_id: u64 = 1,

pub fn init(allocator: std.mem.Allocator, io: std.Io) DaemonState {
    return .{
        .allocator = allocator,
        .io = io,
    };
}

pub fn deinit(self: *DaemonState) void {
    var it = self.vaults.iterator();
    while (it.next()) |e| {
        self.allocator.free(e.key_ptr.*);
        e.value_ptr.*.deinit();
        self.allocator.destroy(e.value_ptr.*);
    }
    self.vaults.deinit(self.allocator);

    for (self.jobs.items) |*j| j.deinit(self.allocator);
    self.jobs.deinit(self.allocator);
}

/// Creates and mounts an in-memory demo/local vault inside the daemon.
pub fn createInMemoryVault(
    self: *DaemonState,
    vault_id: []const u8,
    device_id: []const u8,
    now_unix_s: i64,
) !*VaultEntry {
    if (self.vaults.contains(vault_id)) return error.VaultAlreadyMounted;

    const entry = try self.allocator.create(VaultEntry);
    errdefer self.allocator.destroy(entry);

    entry.* = .{
        .vault = undefined,
        .catalog = vfs.InMemoryCatalog.init(self.allocator),
        .partitions = PartitionManager.init(self.allocator),
        .mem_store = vfs.InMemoryBlobStore.init(self.allocator),
    };
    errdefer {
        entry.partitions.deinit();
        entry.catalog.deinit();
        if (entry.mem_store) |*ms| ms.deinit();
    }

    const kp = try vfs.Provisioner.keygenDevice(self.io);
    entry.vault = try vfs.Vault.create(
        self.allocator,
        self.io,
        entry.mem_store.?.port(),
        entry.catalog.port(),
        vault_id,
        device_id,
        kp.public_key,
        &.{.{ .node_id = "mem:node-1" }},
        .{},
        now_unix_s,
    );
    errdefer entry.vault.deinit();

    const key = try self.allocator.dupe(u8, vault_id);
    errdefer self.allocator.free(key);
    try self.vaults.put(self.allocator, key, entry);
    return entry;
}

pub fn getVault(self: *DaemonState, vault_id: []const u8) ?*VaultEntry {
    return self.vaults.get(vault_id);
}

pub fn enqueueJob(
    self: *DaemonState,
    vault_id: []const u8,
    kind: JobKind,
    target_path: []const u8,
    now_unix_s: i64,
) !u64 {
    const id = self.next_job_id;
    self.next_job_id += 1;

    const vid = try self.allocator.dupe(u8, vault_id);
    errdefer self.allocator.free(vid);
    const tp = try self.allocator.dupe(u8, target_path);
    errdefer self.allocator.free(tp);

    try self.jobs.append(self.allocator, .{
        .id = id,
        .vault_id = vid,
        .kind = kind,
        .status = .queued,
        .target_path = tp,
        .created_at = now_unix_s,
    });
    return id;
}


const std = @import("std");
const sdk = @import("parabellum_sdk");
const vfs = @import("vfs");
const PartitionManager = @import("PartitionManager.zig");
const RepoCatalogAdapter = @import("RepoCatalogAdapter.zig").RepoCatalogAdapter;
const RepoBlobStoreAdapter = @import("RepoBlobStoreAdapter.zig").RepoBlobStoreAdapter;
const abi = sdk.abi;

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
    partitions: PartitionManager,
    catalog: ?vfs.InMemoryCatalog = null,
    mem_store: ?vfs.InMemoryBlobStore = null,
    repo_catalog: ?RepoCatalogAdapter = null,
    repo_blob_store: ?RepoBlobStoreAdapter = null,

    pub fn deinit(self: *VaultEntry) void {
        self.partitions.deinit();
        self.vault.deinit();
        if (self.catalog) |*c| c.deinit();
        if (self.mem_store) |*ms| ms.deinit();
    }
};

pub const RepoRef = struct {
    handle: *abi.driver.RepoHandle_ABI,
    vtable: *const abi.driver.StorageRepositoryVTable_ABI,
};

allocator: std.mem.Allocator,
io: std.Io,
catalog_repo: ?RepoRef = null,
blob_repo: ?RepoRef = null,
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
        if (entry.catalog) |*c| c.deinit();
        if (entry.mem_store) |*ms| ms.deinit();
    }

    const kp = try vfs.Provisioner.keygenDevice(self.io);
    entry.vault = try vfs.Vault.create(
        self.allocator,
        self.io,
        entry.mem_store.?.port(),
        entry.catalog.?.port(),
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

/// Mounts a vault backed by engine-injected C-ABI `CatalogPort` and `BlobStorePort` repositories.
/// Loads or generates+persists `device.key` at `device_key_path`, then attempts `Vault.open`
/// or falls back to `Vault.create` if the vault is new.
pub fn mountConfiguredVault(
    self: *DaemonState,
    vault_id: []const u8,
    device_id: []const u8,
    device_key_path: []const u8,
    catalog_handle: *abi.driver.RepoHandle_ABI,
    catalog_vtable: *const abi.driver.StorageRepositoryVTable_ABI,
    blob_handle: *abi.driver.RepoHandle_ABI,
    blob_vtable: *const abi.driver.StorageRepositoryVTable_ABI,
    now_unix_s: i64,
) !*VaultEntry {
    if (self.vaults.contains(vault_id)) return error.VaultAlreadyMounted;

    const entry = try self.allocator.create(VaultEntry);
    errdefer self.allocator.destroy(entry);

    entry.* = .{
        .vault = undefined,
        .partitions = PartitionManager.init(self.allocator),
        .repo_catalog = RepoCatalogAdapter.init(self.allocator, catalog_handle, catalog_vtable),
        .repo_blob_store = RepoBlobStoreAdapter.init(blob_handle, blob_vtable),
    };
    errdefer entry.partitions.deinit();

    const kp = try loadOrCreateDeviceKey(self.io, device_key_path);
    const cat_port = entry.repo_catalog.?.port();
    const blob_port = entry.repo_blob_store.?.port();
    const primary_node_id = "user-01";

    if (entry.repo_blob_store.?.discoverCatalogObjectId(self.allocator, primary_node_id, vault_id)) |cat_obj_id| {
        defer self.allocator.free(cat_obj_id);
        entry.vault = vfs.Vault.open(
            self.allocator,
            self.io,
            blob_port,
            cat_port,
            vault_id,
            primary_node_id,
            cat_obj_id,
            device_id,
            kp.secret_key,
            .{},
        ) catch try vfs.Vault.create(
            self.allocator,
            self.io,
            blob_port,
            cat_port,
            vault_id,
            device_id,
            kp.public_key,
            &.{.{ .node_id = primary_node_id }},
            .{},
            now_unix_s,
        );
    } else |_| {
        entry.vault = try vfs.Vault.create(
            self.allocator,
            self.io,
            blob_port,
            cat_port,
            vault_id,
            device_id,
            kp.public_key,
            &.{.{ .node_id = primary_node_id }},
            .{},
            now_unix_s,
        );
    }
    errdefer entry.vault.deinit();

    const key = try self.allocator.dupe(u8, vault_id);
    errdefer self.allocator.free(key);
    try self.vaults.put(self.allocator, key, entry);
    return entry;
}

fn loadOrCreateDeviceKey(io: std.Io, path: []const u8) !vfs.Crypto.HybridKem.KeyPair {
    const pk_len = vfs.Crypto.HybridKem.PublicKey.encoded_length;
    const sk_len = vfs.Crypto.HybridKem.SecretKey.encoded_length;

    if (path.len > 0) {
        if (std.Io.Dir.cwd().openFile(io, path, .{})) |file| {
            defer file.close(io);
            var pk_buf: [pk_len]u8 = undefined;
            var sk_buf: [sk_len]u8 = undefined;
            var buf: [4096]u8 = undefined;
            var reader = file.reader(io, &buf);
            if (reader.interface.readSliceAll(&pk_buf)) |_| {
                if (reader.interface.readSliceAll(&sk_buf)) |_| {
                    const pk = vfs.Crypto.HybridKem.PublicKey.fromBytes(&pk_buf);
                    const sk = vfs.Crypto.HybridKem.SecretKey.fromBytes(&sk_buf);
                    return .{ .public_key = pk, .secret_key = sk };
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }

    const kp = try vfs.Provisioner.keygenDevice(io);
    if (path.len > 0) {
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
        if (std.Io.Dir.cwd().createFile(io, path, .{})) |file| {
            defer file.close(io);
            var wbuf: [4096]u8 = undefined;
            var writer = file.writer(io, &wbuf);
            const pk_bytes = kp.public_key.toBytes();
            const sk_bytes = kp.secret_key.toBytes();
            writer.interface.writeAll(&pk_bytes) catch {};
            writer.interface.writeAll(&sk_bytes) catch {};
            writer.interface.flush() catch {};
        } else |_| {}
    }
    return kp;
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


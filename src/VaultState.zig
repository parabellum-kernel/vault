const std = @import("std");
const sdk = @import("parabellum_sdk");
const vfs = @import("vfs");
const PartitionManager = @import("PartitionManager.zig");
const RepoCatalogAdapter = vfs.RepoCatalogAdapter(sdk.abi);
const RepoBlobStoreAdapter = vfs.RepoBlobStoreAdapter(sdk.abi);
const abi = sdk.abi;

/// Central in-process state shared across `vault` task invocations.
/// Holds all open `vfs.Vault` instances and partition managers.
const VaultState = @This();

pub const VaultEntry = struct {
    vault: vfs.Vault,
    partitions: PartitionManager,
    catalog: ?vfs.InMemoryCatalog = null,
    mem_store: ?vfs.InMemoryBlobStore = null,
    repo_catalog: ?RepoCatalogAdapter = null,
    repo_blob_store: ?RepoBlobStoreAdapter = null,
    composite_blob_store: ?vfs.CompositeBlobStore = null,

    pub fn deinit(self: *VaultEntry) void {
        self.partitions.deinit();
        self.vault.deinit();
        if (self.composite_blob_store) |*cs| cs.deinit();
        if (self.catalog) |*c| c.deinit();
        if (self.mem_store) |*ms| ms.deinit();
    }
};

pub fn unixNow(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
}

pub const RepoRef = struct {
    handle: *abi.driver.RepoHandle_ABI,
    vtable: *const abi.driver.StorageRepositoryVTable_ABI,
};

allocator: std.mem.Allocator,
io: std.Io,
catalog_repo: ?RepoRef = null,
blob_repo: ?RepoRef = null,
vaults: std.StringHashMapUnmanaged(*VaultEntry) = .empty,

pub fn init(allocator: std.mem.Allocator, io: std.Io) VaultState {
    return .{
        .allocator = allocator,
        .io = io,
    };
}

pub fn deinit(self: *VaultState) void {
    var it = self.vaults.iterator();
    while (it.next()) |e| {
        self.allocator.free(e.key_ptr.*);
        e.value_ptr.*.deinit();
        self.allocator.destroy(e.value_ptr.*);
    }
    self.vaults.deinit(self.allocator);
}

/// Creates and mounts an in-memory demo/local vault inside the process.
pub fn createInMemoryVault(
    self: *VaultState,
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
    self: *VaultState,
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
        .composite_blob_store = vfs.CompositeBlobStore.init(self.allocator),
    };
    errdefer {
        if (entry.composite_blob_store) |*cs| cs.deinit();
        entry.partitions.deinit();
    }

    const kp = try loadOrCreateDeviceKey(self.io, device_key_path);
    const cat_port = entry.repo_catalog.?.port();
    const primary_node_id = if (std.c.getenv("VAULT_NODE_ID")) |v| std.mem.span(v) else "node-primary";
    try entry.composite_blob_store.?.registerNode(primary_node_id, entry.repo_blob_store.?.port());
    const blob_port = entry.composite_blob_store.?.port();

    if (entry.repo_blob_store.?.discoverCatalogObjectId(self.allocator, primary_node_id, vault_id)) |cat_obj_id| {
        defer self.allocator.free(cat_obj_id);
        // U4: Do NOT fall back to Vault.create if opening an existing catalog fails.
        entry.vault = try vfs.Vault.open(
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
        );
    } else |err| switch (err) {
        error.CatalogNotFound => {
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
        },
        else => return err,
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
            try std.Io.Dir.cwd().createDirPath(io, dir);
        }
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = .fromMode(0o600) });
        defer file.close(io);
        var wbuf: [4096]u8 = undefined;
        var writer = file.writer(io, &wbuf);
        const pk_bytes = kp.public_key.toBytes();
        const sk_bytes = kp.secret_key.toBytes();
        try writer.interface.writeAll(&pk_bytes);
        try writer.interface.writeAll(&sk_bytes);
        try writer.interface.flush();
    }
    return kp;
}

pub fn getVault(self: *VaultState, vault_id: []const u8) ?*VaultEntry {
    return self.vaults.get(vault_id);
}

test "U4: mountConfiguredVault propagates non-CatalogNotFound errors instead of creating phantom vault" {
    const MockFailRepo = struct {
        fn getCaps(_: *const abi.driver.RepoHandle_ABI) callconv(.c) abi.driver.DriverCapabilities_ABI {
            return .{};
        }
        fn recCount(_: *const abi.driver.RepoHandle_ABI, _: abi.Slice_ABI) callconv(.c) usize {
            return 0;
        }
        fn deinitRepo(_: *abi.driver.RepoHandle_ABI) callconv(.c) void {}
        fn readStream(_: *abi.driver.RepoHandle_ABI, _: *const abi.driver.ReadSpec_ABI, _: *abi.driver.RowIterator_ABI) callconv(.c) abi.HostError_ABI {
            return .io_error;
        }
        const vtable = abi.driver.StorageRepositoryVTable_ABI{
            .get_capabilities = getCaps,
            .record_count = recCount,
            .deinit = deinitRepo,
            .read_stream = readStream,
        };
    };

    var state = VaultState.init(std.testing.allocator, std.testing.io);
    defer state.deinit();

    var dummy_cat: u8 = 0;
    var dummy_blob: u8 = 0;
    const tmp_key = ".zig-cache/test_u4_device.key";
    std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_key) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_key) catch {};

    try std.testing.expectError(
        error.HostReadFailed,
        state.mountConfiguredVault(
            "v1",
            "dev-1",
            tmp_key,
            @ptrCast(&dummy_cat),
            &MockFailRepo.vtable,
            @ptrCast(&dummy_blob),
            &MockFailRepo.vtable,
            unixNow(std.testing.io),
        ),
    );
}


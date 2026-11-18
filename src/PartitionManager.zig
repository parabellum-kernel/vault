const std = @import("std");
const vfs = @import("vfs");

/// Manages logical partitions (folder-scoped quotas + `UploadPolicy` filtering)
/// inside a single `vfs.Vault` (`ARCH-037D` Pattern B).
const PartitionManager = @This();

pub const PolicyKind = enum {
    most_available,
    first_fit,
    random,
    pinned,
};

pub const Partition = struct {
    name: []u8,
    root_folder: []u8,
    root_inode_id: ?[]u8 = null,
    quota_bytes: u64,
    policy_kind: PolicyKind = .most_available,
    pinned_node_id: ?[]u8 = null,
    allowed_node_ids: [][]u8 = &.{},

    pub fn deinit(self: *Partition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root_folder);
        if (self.root_inode_id) |id| allocator.free(id);
        if (self.pinned_node_id) |id| allocator.free(id);
        for (self.allowed_node_ids) |id| allocator.free(id);
        if (self.allowed_node_ids.len > 0) allocator.free(self.allowed_node_ids);
    }
};

/// `UploadPolicy` adapter that restricts `accounts` to `allowed_node_ids` (when non-empty)
/// before applying the partition's selection strategy (`most_available`, `first_fit`, `random`, `pinned`).
pub const PartitionUploadPolicy = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    partition: *const Partition,

    pub fn policy(self: *PartitionUploadPolicy) vfs.PoolAllocator.UploadPolicy {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = vfs.PoolAllocator.UploadPolicy.VTable{
        .selectAccount = selectImpl,
    };

    fn isAllowed(self: *const PartitionUploadPolicy, node_id: []const u8) bool {
        if (self.partition.allowed_node_ids.len == 0) return true;
        for (self.partition.allowed_node_ids) |allowed| {
            if (std.mem.eql(u8, allowed, node_id)) return true;
        }
        return false;
    }

    fn selectImpl(ptr: *anyopaque, accounts: []const vfs.PoolAllocator.ServiceAccountQuota, required_bytes: u64) ?usize {
        const self: *PartitionUploadPolicy = @ptrCast(@alignCast(ptr));

        // Build a filtered view where disallowed nodes have 0 effective capacity.
        const filtered = self.allocator.alloc(vfs.PoolAllocator.ServiceAccountQuota, accounts.len) catch return null;
        defer self.allocator.free(filtered);
        for (accounts, 0..) |acc, i| {
            filtered[i] = acc;
            if (!self.isAllowed(acc.sa_id)) {
                filtered[i].total_bytes = 0;
                filtered[i].used_bytes = 0;
            }
        }

        return switch (self.partition.policy_kind) {
            .most_available => blk: {
                var p = vfs.PoolAllocator.MostAvailablePolicy{};
                break :blk p.policy().selectAccount(filtered, required_bytes);
            },
            .first_fit => blk: {
                var p = vfs.PoolAllocator.FirstFitPolicy{};
                break :blk p.policy().selectAccount(filtered, required_bytes);
            },
            .random => blk: {
                var p = vfs.PoolAllocator.RandomPolicy{ .io = self.io };
                break :blk p.policy().selectAccount(filtered, required_bytes);
            },
            .pinned => blk: {
                const target = self.partition.pinned_node_id orelse return null;
                var p = vfs.PoolAllocator.PinnedAccountPolicy{ .sa_id = target };
                break :blk p.policy().selectAccount(filtered, required_bytes);
            },
        };
    }
};

allocator: std.mem.Allocator,
partitions: std.StringHashMapUnmanaged(Partition) = .empty,

pub fn init(allocator: std.mem.Allocator) PartitionManager {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *PartitionManager) void {
    var it = self.partitions.iterator();
    while (it.next()) |e| {
        self.allocator.free(e.key_ptr.*);
        e.value_ptr.deinit(self.allocator);
    }
    self.partitions.deinit(self.allocator);
}

pub fn createPartition(
    self: *PartitionManager,
    vault: *vfs.Vault,
    name: []const u8,
    root_folder: []const u8,
    quota_bytes: u64,
    policy_kind: PolicyKind,
    allowed_node_ids: []const []const u8,
    now_unix_s: i64,
) !void {
    if (self.partitions.contains(name)) return error.PartitionAlreadyExists;

    const clean_name = std.mem.trimStart(u8, root_folder, "/");
    const root_id: []u8 = if (vault.stat(null, clean_name)) |existing|
        try self.allocator.dupe(u8, existing.inode_id)
    else
        try vault.mkdir(null, clean_name, now_unix_s);
    errdefer self.allocator.free(root_id);

    const owned_key = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(owned_key);
    const owned_name = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(owned_name);
    const owned_folder = try self.allocator.dupe(u8, root_folder);
    errdefer self.allocator.free(owned_folder);

    const owned_allowed = try self.allocator.alloc([]u8, allowed_node_ids.len);
    var built: usize = 0;
    errdefer {
        for (owned_allowed[0..built]) |id| self.allocator.free(id);
        self.allocator.free(owned_allowed);
    }
    for (allowed_node_ids) |id| {
        owned_allowed[built] = try self.allocator.dupe(u8, id);
        built += 1;
    }

    try self.partitions.put(self.allocator, owned_key, .{
        .name = owned_name,
        .root_folder = owned_folder,
        .root_inode_id = root_id,
        .quota_bytes = quota_bytes,
        .policy_kind = policy_kind,
        .allowed_node_ids = owned_allowed,
    });
}

pub fn resizePartition(self: *PartitionManager, name: []const u8, new_quota_bytes: u64) !void {
    const part = self.partitions.getPtr(name) orelse return error.PartitionNotFound;
    part.quota_bytes = new_quota_bytes;
}

pub fn usedBytes(self: *const PartitionManager, vault: *const vfs.Vault, name: []const u8) !u64 {
    const part = self.partitions.get(name) orelse return error.PartitionNotFound;
    const children = try vault.listDir(part.root_inode_id);
    defer vault.allocator.free(children);

    var total: u64 = 0;
    for (children) |child| {
        if (child.kind == .file) total +|= child.logical_size;
    }
    return total;
}

/// Writes `plaintext` into partition `name`, enforcing `quota_bytes` and its `UploadPolicy`.
pub fn writeFile(
    self: *PartitionManager,
    vault: *vfs.Vault,
    partition_name: []const u8,
    file_name: []const u8,
    plaintext: []const u8,
    now_unix_s: i64,
) ![]u8 {
    return self.writeFileWithMime(vault, partition_name, file_name, plaintext, null, now_unix_s);
}

pub fn writeFileWithMime(
    self: *PartitionManager,
    vault: *vfs.Vault,
    partition_name: []const u8,
    file_name: []const u8,
    plaintext: []const u8,
    mime_type: ?[]const u8,
    now_unix_s: i64,
) ![]u8 {
    const part = self.partitions.getPtr(partition_name) orelse return error.PartitionNotFound;
    const current_used = try self.usedBytes(vault, partition_name);
    if (current_used +| plaintext.len > part.quota_bytes) {
        return error.PartitionQuotaExceeded;
    }

    var pol = PartitionUploadPolicy{
        .allocator = self.allocator,
        .io = vault.io,
        .partition = part,
    };
    return vault.write(part.root_inode_id, file_name, plaintext, .{
        .upload_policy = pol.policy(),
        .mime_type = mime_type,
    }, now_unix_s);
}


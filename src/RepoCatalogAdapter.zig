const std = @import("std");
const sdk = @import("parabellum_sdk");
const vfs = @import("vfs");
const abi = sdk.abi;

/// Adapts a C-ABI `StorageRepositoryVTable_ABI` handle into `vfs.CatalogPort`.
pub const RepoCatalogAdapter = struct {
    allocator: std.mem.Allocator,
    handle: *abi.driver.RepoHandle_ABI,
    vtable: *const abi.driver.StorageRepositoryVTable_ABI,

    pub fn init(
        allocator: std.mem.Allocator,
        handle: *abi.driver.RepoHandle_ABI,
        vtable: *const abi.driver.StorageRepositoryVTable_ABI,
    ) RepoCatalogAdapter {
        return .{
            .allocator = allocator,
            .handle = handle,
            .vtable = vtable,
        };
    }

    pub fn port(self: *RepoCatalogAdapter) vfs.CatalogPort {
        return .{
            .ptr = self,
            .vtable = &port_vtable,
        };
    }

    const port_vtable = vfs.CatalogPort.VTable{
        .getMeta = getMetaImpl,
        .setMeta = setMetaImpl,
        .putKeySlot = putKeySlotImpl,
        .getKeySlot = getKeySlotImpl,
        .deleteKeySlot = deleteKeySlotImpl,
        .putStorageNode = putStorageNodeImpl,
        .listStorageNodes = listStorageNodesImpl,
        .putLease = putLeaseImpl,
        .deleteLease = deleteLeaseImpl,
        .listActiveLeases = listActiveLeasesImpl,
        .pruneExpiredLeases = pruneExpiredLeasesImpl,
        .putInode = putInodeImpl,
        .getInode = getInodeImpl,
        .findInodeByName = findInodeByNameImpl,
        .listChildren = listChildrenImpl,
        .deleteInode = deleteInodeImpl,
        .putExtent = putExtentImpl,
        .listExtents = listExtentsImpl,
        .markGc = markGcImpl,
        .listPendingGc = listPendingGcImpl,
        .deleteGc = deleteGcImpl,
        .exportSnapshot = exportSnapshotImpl,
        .importSnapshot = importSnapshotImpl,
    };

    fn checkErr(err: abi.HostError_ABI) !void {
        if (err != .ok) return error.StorageAbiError;
    }

    fn writeFields(self: *RepoCatalogAdapter, table: []const u8, fields: []const abi.NamedField_ABI) !void {
        const write_fn = self.vtable.write_row orelse return error.NotSupported;
        const spec = abi.driver.WriteSpec_ABI{
            .table = abi.Slice_ABI.from(table),
            .mode = .upsert,
            .fields_ptr = fields.ptr,
            .fields_len = fields.len,
        };
        try checkErr(write_fn(self.handle, &spec));
    }

    fn openStream(self: *RepoCatalogAdapter, table: []const u8, filter: []const u8) !abi.driver.RowIterator_ABI {
        const read_fn = self.vtable.read_stream orelse return error.NotSupported;
        var iter: abi.driver.RowIterator_ABI = undefined;
        const spec = abi.driver.ReadSpec_ABI{
            .table = abi.Slice_ABI.from(table),
            .filter_sql_or_expr = abi.Slice_ABI.from(filter),
            .limit = 0,
            .offset = 0,
        };
        try checkErr(read_fn(self.handle, &spec, &iter));
        return iter;
    }

    fn nextRow(iter: *abi.driver.RowIterator_ABI, out_row: *abi.RowView_ABI) !bool {
        const err = iter.vtable.next(iter.handle, out_row);
        if (err == .end_of_stream) return false;
        try checkErr(err);
        return true;
    }

    fn deinitIter(iter: *abi.driver.RowIterator_ABI) void {
        iter.vtable.deinit(iter.handle);
    }

    fn findField(row: *const abi.RowView_ABI, name: []const u8) ?abi.Value_ABI {
        for (row.fieldsSlice()) |f| {
            if (std.mem.eql(u8, std.mem.span(f.name), name)) return f.value;
        }
        return null;
    }

    fn getBytes(allocator: std.mem.Allocator, row: *const abi.RowView_ABI, name: []const u8) ![]const u8 {
        const f = findField(row, name) orelse return "";
        return switch (f.tag) {
            .bytes_val => allocator.dupe(u8, f.payload.bytes.toSlice()),
            .null_val => "",
            else => "",
        };
    }

    fn getOptBytes(allocator: std.mem.Allocator, row: *const abi.RowView_ABI, name: []const u8) !?[]const u8 {
        const f = findField(row, name) orelse return null;
        return switch (f.tag) {
            .bytes_val => if (f.payload.bytes.len > 0) try allocator.dupe(u8, f.payload.bytes.toSlice()) else null,
            .null_val => null,
            else => null,
        };
    }

    fn getU64(row: *const abi.RowView_ABI, name: []const u8, default_val: u64) u64 {
        const f = findField(row, name) orelse return default_val;
        return switch (f.tag) {
            .uint_val => f.payload.u,
            .int_val => if (f.payload.i >= 0) @intCast(f.payload.i) else default_val,
            else => default_val,
        };
    }

    fn getI64(row: *const abi.RowView_ABI, name: []const u8, default_val: i64) i64 {
        const f = findField(row, name) orelse return default_val;
        return switch (f.tag) {
            .int_val => f.payload.i,
            .uint_val => @intCast(f.payload.u),
            else => default_val,
        };
    }

    fn fBytes(name: [*:0]const u8, val: []const u8) abi.NamedField_ABI {
        return .{ .name = name, .value = .{ .tag = .bytes_val, .payload = .{ .bytes = abi.Slice_ABI.from(val) } } };
    }

    fn fOptBytes(name: [*:0]const u8, val: ?[]const u8) abi.NamedField_ABI {
        return if (val) |v|
            .{ .name = name, .value = .{ .tag = .bytes_val, .payload = .{ .bytes = abi.Slice_ABI.from(v) } } }
        else
            .{ .name = name, .value = .{ .tag = .null_val, .payload = .{ .i = 0 } } };
    }

    fn fU64(name: [*:0]const u8, val: u64) abi.NamedField_ABI {
        return .{ .name = name, .value = .{ .tag = .uint_val, .payload = .{ .u = val } } };
    }

    fn fI64(name: [*:0]const u8, val: i64) abi.NamedField_ABI {
        return .{ .name = name, .value = .{ .tag = .int_val, .payload = .{ .i = val } } };
    }

    // -------------------------------------------------------------------------
    // VfsMeta
    // -------------------------------------------------------------------------

    fn getMetaImpl(ptr: *anyopaque) vfs.CatalogPort.VfsMeta {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        var iter = self.openStream("vfs_meta", "id=1") catch return .{};
        defer deinitIter(&iter);

        var row: abi.RowView_ABI = undefined;
        if (!(nextRow(&iter, &row) catch false)) return .{};

        return .{
            .schema_version = @intCast(getU64(&row, "schema_version", 1)),
            .vfs_epoch = getU64(&row, "vfs_epoch", 1),
            .last_writer_device_id = getBytes(self.allocator, &row, "last_writer_device_id") catch "",
            .last_writer_sdk_semver = getBytes(self.allocator, &row, "last_writer_sdk_semver") catch "0.1.0",
            .last_observed_api_id = getBytes(self.allocator, &row, "last_observed_api_id") catch "drive:v3",
            .last_observed_api_revision = getBytes(self.allocator, &row, "last_observed_api_revision") catch "20261029",
        };
    }

    fn setMetaImpl(ptr: *anyopaque, meta: vfs.CatalogPort.VfsMeta) anyerror!void {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const fields = [_]abi.NamedField_ABI{
            fU64("id", 1),
            fU64("schema_version", meta.schema_version),
            fU64("vfs_epoch", meta.vfs_epoch),
            fBytes("last_writer_device_id", meta.last_writer_device_id),
            fBytes("last_writer_sdk_semver", meta.last_writer_sdk_semver),
            fBytes("last_observed_api_id", meta.last_observed_api_id),
            fBytes("last_observed_api_revision", meta.last_observed_api_revision),
        };
        try self.writeFields("vfs_meta", &fields);
    }

    // -------------------------------------------------------------------------
    // VaultKeySlot
    // -------------------------------------------------------------------------

    fn putKeySlotImpl(ptr: *anyopaque, slot: vfs.CatalogPort.VaultKeySlot) anyerror!void {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const fields = [_]abi.NamedField_ABI{
            fBytes("slot_id", slot.slot_id),
            fBytes("label", slot.label),
            fBytes("kem_alg", slot.kem_alg),
            fBytes("aead_alg", slot.aead_alg),
            fBytes("public_key", slot.public_key),
            fBytes("kem_ciphertext", slot.kem_ciphertext),
            fBytes("vmk_wrapped", slot.vmk_wrapped),
            fI64("created_at", slot.created_at),
        };
        try self.writeFields("vault_key_slots", &fields);
    }

    fn getKeySlotImpl(ptr: *anyopaque, slot_id: []const u8) ?vfs.CatalogPort.VaultKeySlot {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const filter = std.fmt.allocPrint(self.allocator, "slot_id='{s}'", .{slot_id}) catch return null;
        defer self.allocator.free(filter);

        var iter = self.openStream("vault_key_slots", filter) catch return null;
        defer deinitIter(&iter);

        var row: abi.RowView_ABI = undefined;
        if (!(nextRow(&iter, &row) catch false)) return null;

        return .{
            .slot_id = getBytes(self.allocator, &row, "slot_id") catch return null,
            .label = getBytes(self.allocator, &row, "label") catch return null,
            .kem_alg = getBytes(self.allocator, &row, "kem_alg") catch "MLKEM768-X25519",
            .aead_alg = getBytes(self.allocator, &row, "aead_alg") catch "XChaCha20-Poly1305",
            .public_key = getBytes(self.allocator, &row, "public_key") catch return null,
            .kem_ciphertext = getBytes(self.allocator, &row, "kem_ciphertext") catch return null,
            .vmk_wrapped = getBytes(self.allocator, &row, "vmk_wrapped") catch return null,
            .created_at = getI64(&row, "created_at", 0),
        };
    }

    fn deleteKeySlotImpl(ptr: *anyopaque, slot_id: []const u8) bool {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const fields = [_]abi.NamedField_ABI{fBytes("slot_id", slot_id)};
        self.writeFields("delete_vault_key_slot", &fields) catch return false;
        return true;
    }

    // -------------------------------------------------------------------------
    // StorageNodeEntry
    // -------------------------------------------------------------------------

    fn putStorageNodeImpl(ptr: *anyopaque, sa: vfs.CatalogPort.StorageNodeEntry) anyerror!void {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const fields = [_]abi.NamedField_ABI{
            fBytes("node_id", sa.node_id),
            fBytes("credentials_wrapped", sa.credentials_wrapped),
            fU64("quota_limit_bytes", sa.quota_limit_bytes),
            fU64("quota_used_bytes", sa.quota_used_bytes),
            fU64("catalog_headroom_bytes", sa.catalog_headroom_bytes),
            fU64("catalog_role", @intFromEnum(sa.catalog_role)),
            fU64("status", @intFromEnum(sa.status)),
            fI64("last_quota_sync_at", sa.last_quota_sync_at),
        };
        try self.writeFields("storage_nodes", &fields);
    }

    fn listStorageNodesImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]vfs.CatalogPort.StorageNodeEntry {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        var iter = try self.openStream("storage_nodes", "");
        defer deinitIter(&iter);

        var list: std.ArrayListUnmanaged(vfs.CatalogPort.StorageNodeEntry) = .empty;
        errdefer list.deinit(allocator);

        var row: abi.RowView_ABI = undefined;
        while (try nextRow(&iter, &row)) {
            try list.append(allocator, .{
                .node_id = try getBytes(allocator, &row, "node_id"),
                .credentials_wrapped = try getBytes(allocator, &row, "credentials_wrapped"),
                .quota_limit_bytes = getU64(&row, "quota_limit_bytes", 0),
                .quota_used_bytes = getU64(&row, "quota_used_bytes", 0),
                .catalog_headroom_bytes = getU64(&row, "catalog_headroom_bytes", 0),
                .catalog_role = @enumFromInt(@as(u8, @intCast(getU64(&row, "catalog_role", 0)))),
                .status = @enumFromInt(@as(u8, @intCast(getU64(&row, "status", 0)))),
                .last_quota_sync_at = getI64(&row, "last_quota_sync_at", 0),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    // -------------------------------------------------------------------------
    // UploadLease
    // -------------------------------------------------------------------------

    fn putLeaseImpl(ptr: *anyopaque, lease: vfs.CatalogPort.UploadLease) anyerror!void {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const fields = [_]abi.NamedField_ABI{
            fBytes("lease_id", lease.lease_id),
            fBytes("device_id", lease.device_id),
            fBytes("node_id", lease.node_id),
            fU64("reserved_bytes", lease.reserved_bytes),
            fU64("purpose", @intFromEnum(lease.purpose)),
            fI64("expires_at", lease.expires_at),
        };
        try self.writeFields("upload_leases", &fields);
    }

    fn deleteLeaseImpl(ptr: *anyopaque, lease_id: []const u8) bool {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const fields = [_]abi.NamedField_ABI{fBytes("lease_id", lease_id)};
        self.writeFields("delete_upload_lease", &fields) catch return false;
        return true;
    }

    fn listActiveLeasesImpl(ptr: *anyopaque, allocator: std.mem.Allocator, now_unix_s: i64) anyerror![]vfs.CatalogPort.UploadLease {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const filter = try std.fmt.allocPrint(allocator, "expires_at>{d}", .{now_unix_s});
        defer allocator.free(filter);

        var iter = try self.openStream("upload_leases", filter);
        defer deinitIter(&iter);

        var list: std.ArrayListUnmanaged(vfs.CatalogPort.UploadLease) = .empty;
        errdefer list.deinit(allocator);

        var row: abi.RowView_ABI = undefined;
        while (try nextRow(&iter, &row)) {
            const exp = getI64(&row, "expires_at", 0);
            if (exp <= now_unix_s) continue;
            try list.append(allocator, .{
                .lease_id = try getBytes(allocator, &row, "lease_id"),
                .device_id = try getBytes(allocator, &row, "device_id"),
                .node_id = try getBytes(allocator, &row, "node_id"),
                .reserved_bytes = getU64(&row, "reserved_bytes", 0),
                .purpose = @enumFromInt(@as(u8, @intCast(getU64(&row, "purpose", 0)))),
                .expires_at = exp,
            });
        }
        return list.toOwnedSlice(allocator);
    }

    fn pruneExpiredLeasesImpl(ptr: *anyopaque, now_unix_s: i64) usize {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const fields = [_]abi.NamedField_ABI{fI64("now_unix_s", now_unix_s)};
        self.writeFields("prune_expired_leases", &fields) catch return 0;
        return 0;
    }

    // -------------------------------------------------------------------------
    // Inode
    // -------------------------------------------------------------------------

    fn decodeInode(allocator: std.mem.Allocator, row: *const abi.RowView_ABI) !vfs.CatalogPort.Inode {
        var sha: ?[32]u8 = null;
        if (findField(row, "content_sha256")) |f| {
            if (f.tag == .bytes_val and f.payload.bytes.len == 32) {
                var buf: [32]u8 = undefined;
                @memcpy(&buf, f.payload.bytes.toSlice());
                sha = buf;
            }
        }
        return .{
            .inode_id = try getBytes(allocator, row, "inode_id"),
            .parent_id = try getOptBytes(allocator, row, "parent_id"),
            .name = try getBytes(allocator, row, "name"),
            .kind = @enumFromInt(@as(u8, @intCast(getU64(row, "kind", 1)))),
            .logical_size = getU64(row, "logical_size", 0),
            .compression_mode = try getBytes(allocator, row, "compression_mode"),
            .file_dek_wrapped = try getOptBytes(allocator, row, "file_dek_wrapped"),
            .content_sha256 = sha,
            .mime_type = try getOptBytes(allocator, row, "mime_type"),
            .mtime = getI64(row, "mtime", 0),
        };
    }

    fn putInodeImpl(ptr: *anyopaque, inode: vfs.CatalogPort.Inode) anyerror!void {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const sha_slice: ?[]const u8 = if (inode.content_sha256) |*s| s else null;
        const fields = [_]abi.NamedField_ABI{
            fBytes("inode_id", inode.inode_id),
            fOptBytes("parent_id", inode.parent_id),
            fBytes("name", inode.name),
            fU64("kind", @intFromEnum(inode.kind)),
            fU64("logical_size", inode.logical_size),
            fBytes("compression_mode", inode.compression_mode),
            fOptBytes("file_dek_wrapped", inode.file_dek_wrapped),
            fOptBytes("content_sha256", sha_slice),
            fOptBytes("mime_type", inode.mime_type),
            fI64("mtime", inode.mtime),
        };
        try self.writeFields("inodes", &fields);
    }

    fn getInodeImpl(ptr: *anyopaque, inode_id: []const u8) ?vfs.CatalogPort.Inode {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const filter = std.fmt.allocPrint(self.allocator, "inode_id='{s}'", .{inode_id}) catch return null;
        defer self.allocator.free(filter);

        var iter = self.openStream("inodes", filter) catch return null;
        defer deinitIter(&iter);

        var row: abi.RowView_ABI = undefined;
        if (!(nextRow(&iter, &row) catch false)) return null;
        return decodeInode(self.allocator, &row) catch null;
    }

    fn findInodeByNameImpl(ptr: *anyopaque, parent_id: ?[]const u8, name: []const u8) ?vfs.CatalogPort.Inode {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const filter = if (parent_id) |pid|
            std.fmt.allocPrint(self.allocator, "parent_id='{s}' AND name='{s}'", .{ pid, name }) catch return null
        else
            std.fmt.allocPrint(self.allocator, "parent_id IS NULL AND name='{s}'", .{name}) catch return null;
        defer self.allocator.free(filter);

        var iter = self.openStream("inodes", filter) catch return null;
        defer deinitIter(&iter);

        var row: abi.RowView_ABI = undefined;
        if (!(nextRow(&iter, &row) catch false)) return null;
        return decodeInode(self.allocator, &row) catch null;
    }

    fn listChildrenImpl(ptr: *anyopaque, allocator: std.mem.Allocator, parent_id: ?[]const u8) anyerror![]vfs.CatalogPort.Inode {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const filter = if (parent_id) |pid|
            try std.fmt.allocPrint(allocator, "parent_id='{s}'", .{pid})
        else
            try allocator.dupe(u8, "parent_id IS NULL");
        defer allocator.free(filter);

        var iter = try self.openStream("inodes", filter);
        defer deinitIter(&iter);

        var list: std.ArrayListUnmanaged(vfs.CatalogPort.Inode) = .empty;
        errdefer list.deinit(allocator);

        var row: abi.RowView_ABI = undefined;
        while (try nextRow(&iter, &row)) {
            try list.append(allocator, try decodeInode(allocator, &row));
        }
        return list.toOwnedSlice(allocator);
    }

    fn deleteInodeImpl(ptr: *anyopaque, inode_id: []const u8) bool {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const fields = [_]abi.NamedField_ABI{fBytes("inode_id", inode_id)};
        self.writeFields("delete_inode", &fields) catch return false;
        return true;
    }

    // -------------------------------------------------------------------------
    // InodeExtent
    // -------------------------------------------------------------------------

    fn putExtentImpl(ptr: *anyopaque, extent: vfs.CatalogPort.InodeExtent) anyerror!void {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const ext_id = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ extent.inode_id, extent.part_index });
        defer self.allocator.free(ext_id);

        const fields = [_]abi.NamedField_ABI{
            fBytes("extent_id", ext_id),
            fBytes("inode_id", extent.inode_id),
            fU64("part_index", extent.part_index),
            fU64("logical_offset", extent.logical_offset),
            fU64("logical_len", extent.logical_len),
            fBytes("node_id", extent.node_id),
            fBytes("remote_object_id", extent.remote_object_id),
            fBytes("remote_blob_name", extent.remote_blob_name),
            fU64("physical_size", extent.physical_size),
            fU64("phys_part_offset", extent.phys_part_offset),
            fU64("phys_part_len", extent.phys_part_len),
        };
        try self.writeFields("inode_extents", &fields);
    }

    fn listExtentsImpl(ptr: *anyopaque, allocator: std.mem.Allocator, inode_id: []const u8) anyerror![]vfs.CatalogPort.InodeExtent {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const filter = try std.fmt.allocPrint(allocator, "inode_id='{s}'", .{inode_id});
        defer allocator.free(filter);

        var iter = try self.openStream("inode_extents", filter);
        defer deinitIter(&iter);

        var list: std.ArrayListUnmanaged(vfs.CatalogPort.InodeExtent) = .empty;
        errdefer list.deinit(allocator);

        var row: abi.RowView_ABI = undefined;
        while (try nextRow(&iter, &row)) {
            try list.append(allocator, .{
                .inode_id = try getBytes(allocator, &row, "inode_id"),
                .part_index = @intCast(getU64(&row, "part_index", 0)),
                .logical_offset = getU64(&row, "logical_offset", 0),
                .logical_len = getU64(&row, "logical_len", 0),
                .node_id = try getBytes(allocator, &row, "node_id"),
                .remote_object_id = try getBytes(allocator, &row, "remote_object_id"),
                .remote_blob_name = try getBytes(allocator, &row, "remote_blob_name"),
                .physical_size = getU64(&row, "physical_size", 0),
                .phys_part_offset = getU64(&row, "phys_part_offset", 0),
                .phys_part_len = getU64(&row, "phys_part_len", 0),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    // -------------------------------------------------------------------------
    // PendingGcEntry
    // -------------------------------------------------------------------------

    fn markGcImpl(ptr: *anyopaque, entry: vfs.CatalogPort.PendingGcEntry) anyerror!void {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const fields = [_]abi.NamedField_ABI{
            fBytes("gc_id", entry.gc_id),
            fBytes("node_id", entry.node_id),
            fBytes("remote_object_id", entry.remote_object_id),
            fI64("marked_at", entry.marked_at),
        };
        try self.writeFields("pending_gc", &fields);
    }

    fn listPendingGcImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]vfs.CatalogPort.PendingGcEntry {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        var iter = try self.openStream("pending_gc", "");
        defer deinitIter(&iter);

        var list: std.ArrayListUnmanaged(vfs.CatalogPort.PendingGcEntry) = .empty;
        errdefer list.deinit(allocator);

        var row: abi.RowView_ABI = undefined;
        while (try nextRow(&iter, &row)) {
            try list.append(allocator, .{
                .gc_id = try getBytes(allocator, &row, "gc_id"),
                .node_id = try getBytes(allocator, &row, "node_id"),
                .remote_object_id = try getBytes(allocator, &row, "remote_object_id"),
                .marked_at = getI64(&row, "marked_at", 0),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    fn deleteGcImpl(ptr: *anyopaque, gc_id: []const u8) bool {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const fields = [_]abi.NamedField_ABI{fBytes("gc_id", gc_id)};
        self.writeFields("delete_pending_gc", &fields) catch return false;
        return true;
    }

    // -------------------------------------------------------------------------
    // Snapshot
    // -------------------------------------------------------------------------

    const Snapshot = struct {
        meta: vfs.CatalogPort.VfsMeta,
        storage_nodes: []const vfs.CatalogPort.StorageNodeEntry,
        inodes: []const vfs.CatalogPort.Inode,
        extents: []const vfs.CatalogPort.InodeExtent,
        pending_gc: []const vfs.CatalogPort.PendingGcEntry,
    };

    fn exportSnapshotImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const meta = getMetaImpl(ptr);
        const nodes = try listStorageNodesImpl(ptr, aa);
        const gc = try listPendingGcImpl(ptr, aa);

        var inodes_list: std.ArrayListUnmanaged(vfs.CatalogPort.Inode) = .empty;
        {
            var iter = try self.openStream("inodes", "");
            defer deinitIter(&iter);
            var row: abi.RowView_ABI = undefined;
            while (try nextRow(&iter, &row)) {
                try inodes_list.append(aa, try decodeInode(aa, &row));
            }
        }

        var extents_list: std.ArrayListUnmanaged(vfs.CatalogPort.InodeExtent) = .empty;
        {
            var iter = try self.openStream("inode_extents", "");
            defer deinitIter(&iter);
            var row: abi.RowView_ABI = undefined;
            while (try nextRow(&iter, &row)) {
                try extents_list.append(aa, .{
                    .inode_id = try getBytes(aa, &row, "inode_id"),
                    .part_index = @intCast(getU64(&row, "part_index", 0)),
                    .logical_offset = getU64(&row, "logical_offset", 0),
                    .logical_len = getU64(&row, "logical_len", 0),
                    .node_id = try getBytes(aa, &row, "node_id"),
                    .remote_object_id = try getBytes(aa, &row, "remote_object_id"),
                    .remote_blob_name = try getBytes(aa, &row, "remote_blob_name"),
                    .physical_size = getU64(&row, "physical_size", 0),
                    .phys_part_offset = getU64(&row, "phys_part_offset", 0),
                    .phys_part_len = getU64(&row, "phys_part_len", 0),
                });
            }
        }

        const snap = Snapshot{
            .meta = meta,
            .storage_nodes = nodes,
            .inodes = inodes_list.items,
            .extents = extents_list.items,
            .pending_gc = gc,
        };
        return std.json.Stringify.valueAlloc(allocator, snap, .{});
    }

    fn importSnapshotImpl(ptr: *anyopaque, snapshot_bytes: []const u8) anyerror!void {
        const self: *RepoCatalogAdapter = @ptrCast(@alignCast(ptr));
        const parsed = try std.json.parseFromSlice(Snapshot, self.allocator, snapshot_bytes, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const snap = parsed.value;
        self.writeFields("clear_table", &.{fBytes("table", "inode_extents")}) catch {};
        self.writeFields("clear_table", &.{fBytes("table", "inodes")}) catch {};
        self.writeFields("clear_table", &.{fBytes("table", "pending_gc")}) catch {};
        self.writeFields("clear_table", &.{fBytes("table", "storage_nodes")}) catch {};

        try setMetaImpl(ptr, snap.meta);
        for (snap.storage_nodes) |n| try putStorageNodeImpl(ptr, n);
        for (snap.inodes) |in| try putInodeImpl(ptr, in);
        for (snap.extents) |ex| try putExtentImpl(ptr, ex);
        for (snap.pending_gc) |gc| try markGcImpl(ptr, gc);
    }
};

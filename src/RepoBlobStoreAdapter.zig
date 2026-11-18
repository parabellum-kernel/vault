const std = @import("std");
const sdk = @import("parabellum_sdk");
const vfs = @import("vfs");
const abi = sdk.abi;

/// Adapts a C-ABI `StorageRepositoryVTable_ABI` handle into `vfs.BlobStorePort`.
pub const RepoBlobStoreAdapter = struct {
    handle: *abi.driver.RepoHandle_ABI,
    vtable: *const abi.driver.StorageRepositoryVTable_ABI,

    pub fn init(
        handle: *abi.driver.RepoHandle_ABI,
        vtable: *const abi.driver.StorageRepositoryVTable_ABI,
    ) RepoBlobStoreAdapter {
        return .{ .handle = handle, .vtable = vtable };
    }

    pub fn port(self: *RepoBlobStoreAdapter) vfs.BlobStorePort {
        return .{
            .ptr = self,
            .vtable = &port_vtable,
        };
    }

    const port_vtable = vfs.BlobStorePort.VTable{
        .putObject = putObjectImpl,
        .getObject = getObjectImpl,
        .getRange = getRangeImpl,
        .updateObjectIfMatch = updateObjectIfMatchImpl,
        .deleteObject = deleteObjectImpl,
        .getQuota = getQuotaImpl,
    };

    fn checkErr(err: abi.HostError_ABI) !void {
        if (err != .ok) return error.StorageAbiError;
    }

    fn readSingleRow(
        self: *RepoBlobStoreAdapter,
        table: []const u8,
        filter: []const u8,
        offset: u64,
        limit: u64,
        out_row: *abi.RowView_ABI,
        iter_out: *abi.driver.RowIterator_ABI,
    ) !bool {
        const read_fn = self.vtable.read_stream orelse return error.NotSupported;
        var iter: abi.driver.RowIterator_ABI = undefined;
        const spec = abi.driver.ReadSpec_ABI{
            .table = abi.Slice_ABI.from(table),
            .filter_sql_or_expr = abi.Slice_ABI.from(filter),
            .limit = limit,
            .offset = offset,
        };
        try checkErr(read_fn(self.handle, &spec, &iter));
        iter_out.* = iter;

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

    pub fn discoverCatalogObjectId(
        self: *RepoBlobStoreAdapter,
        allocator: std.mem.Allocator,
        node_id: []const u8,
        vault_id: []const u8,
    ) ![]u8 {
        const filter = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ node_id, vault_id });
        defer allocator.free(filter);

        var row: abi.RowView_ABI = undefined;
        var iter: abi.driver.RowIterator_ABI = undefined;
        if (!try self.readSingleRow("discover_catalog", filter, 0, 1, &row, &iter)) {
            deinitIter(&iter);
            return error.CatalogNotFound;
        }
        defer deinitIter(&iter);

        const obj_val = findField(&row, "object_id") orelse return error.CatalogNotFound;
        if (obj_val.tag != .bytes_val) return error.CatalogNotFound;
        const s = obj_val.payload.bytes.toSlice();
        if (s.len == 0) return error.CatalogNotFound;
        return allocator.dupe(u8, s);
    }

    fn fBytes(name: [*:0]const u8, val: []const u8) abi.NamedField_ABI {
        return .{ .name = name, .value = .{ .tag = .bytes_val, .payload = .{ .bytes = abi.Slice_ABI.from(val) } } };
    }

    fn putObjectImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        node_id: []const u8,
        name: []const u8,
        data: []const u8,
    ) anyerror!vfs.BlobStorePort.PutResult {
        const self: *RepoBlobStoreAdapter = @ptrCast(@alignCast(ptr));
        const write_fn = self.vtable.write_row orelse return error.NotSupported;
        const is_cat = std.mem.endsWith(u8, name, ".vfscat");
        const op_table = if (is_cat) "put_catalog" else "put_object";
        const vid = if (is_cat and name.len > ".vfscat".len) name[0 .. name.len - ".vfscat".len] else "default";

        const fields = [_]abi.NamedField_ABI{
            fBytes("node_id", node_id),
            fBytes("name", name),
            fBytes("vault_id", vid),
        };
        const spec = abi.driver.WriteSpec_ABI{
            .table = abi.Slice_ABI.from(op_table),
            .fields_ptr = &fields,
            .fields_len = fields.len,
            .raw_bytes = abi.Slice_ABI.from(data),
        };
        try checkErr(write_fn(self.handle, &spec));

        var row: abi.RowView_ABI = undefined;
        var iter: abi.driver.RowIterator_ABI = undefined;
        if (!try self.readSingleRow("last_put_result", "", 0, 1, &row, &iter)) {
            deinitIter(&iter);
            return error.MissingPutResult;
        }
        defer deinitIter(&iter);

        const obj_id_val = findField(&row, "object_id") orelse return error.MissingObjectId;
        const obj_id = try allocator.dupe(u8, obj_id_val.payload.bytes.toSlice());
        errdefer allocator.free(obj_id);

        const etag: ?[]u8 = if (findField(&row, "etag")) |ev|
            if (ev.payload.bytes.len > 0) try allocator.dupe(u8, ev.payload.bytes.toSlice()) else null
        else
            null;

        return .{ .object_id = obj_id, .etag = etag };
    }

    fn getObjectImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        node_id: []const u8,
        object_id: []const u8,
    ) anyerror!vfs.BlobStorePort.GetResult {
        const self: *RepoBlobStoreAdapter = @ptrCast(@alignCast(ptr));
        const filter = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ node_id, object_id });
        defer allocator.free(filter);

        var row: abi.RowView_ABI = undefined;
        var iter: abi.driver.RowIterator_ABI = undefined;
        if (!try self.readSingleRow("get_object", filter, 0, 1, &row, &iter)) {
            deinitIter(&iter);
            return error.ObjectNotFound;
        }
        defer deinitIter(&iter);

        const data_val = findField(&row, "data") orelse return error.MissingObjectData;
        const data = try allocator.dupe(u8, data_val.payload.bytes.toSlice());
        errdefer allocator.free(data);

        const etag: ?[]u8 = if (findField(&row, "etag")) |ev|
            if (ev.payload.bytes.len > 0) try allocator.dupe(u8, ev.payload.bytes.toSlice()) else null
        else
            null;

        return .{ .data = data, .etag = etag };
    }

    fn getRangeImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        node_id: []const u8,
        object_id: []const u8,
        start: u64,
        end_inclusive: u64,
    ) anyerror![]u8 {
        const self: *RepoBlobStoreAdapter = @ptrCast(@alignCast(ptr));
        const filter = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ node_id, object_id });
        defer allocator.free(filter);

        const limit: u64 = if (end_inclusive >= start) (end_inclusive - start + 1) else 0;
        var row: abi.RowView_ABI = undefined;
        var iter: abi.driver.RowIterator_ABI = undefined;
        if (!try self.readSingleRow("get_range", filter, start, limit, &row, &iter)) {
            deinitIter(&iter);
            return error.ObjectNotFound;
        }
        defer deinitIter(&iter);

        const data_val = findField(&row, "data") orelse return error.MissingObjectData;
        return allocator.dupe(u8, data_val.payload.bytes.toSlice());
    }

    fn updateObjectIfMatchImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        node_id: []const u8,
        object_id: []const u8,
        expected_etag: ?[]const u8,
        data: []const u8,
    ) anyerror![]u8 {
        const self: *RepoBlobStoreAdapter = @ptrCast(@alignCast(ptr));
        const write_fn = self.vtable.write_row orelse return error.NotSupported;
        const etag_slice = expected_etag orelse "";
        const fields = [_]abi.NamedField_ABI{
            fBytes("node_id", node_id),
            fBytes("object_id", object_id),
            fBytes("expected_etag", etag_slice),
        };
        const spec = abi.driver.WriteSpec_ABI{
            .table = abi.Slice_ABI.from("update_object"),
            .fields_ptr = &fields,
            .fields_len = fields.len,
            .raw_bytes = abi.Slice_ABI.from(data),
        };
        try checkErr(write_fn(self.handle, &spec));

        var row: abi.RowView_ABI = undefined;
        var iter: abi.driver.RowIterator_ABI = undefined;
        if (!try self.readSingleRow("last_put_result", "", 0, 1, &row, &iter)) {
            deinitIter(&iter);
            return error.MissingPutResult;
        }
        defer deinitIter(&iter);

        const etag_val = findField(&row, "etag") orelse return allocator.dupe(u8, "");
        return allocator.dupe(u8, etag_val.payload.bytes.toSlice());
    }

    fn deleteObjectImpl(
        ptr: *anyopaque,
        _: std.mem.Allocator,
        node_id: []const u8,
        object_id: []const u8,
    ) anyerror!void {
        const self: *RepoBlobStoreAdapter = @ptrCast(@alignCast(ptr));
        const write_fn = self.vtable.write_row orelse return error.NotSupported;
        const fields = [_]abi.NamedField_ABI{
            fBytes("node_id", node_id),
            fBytes("object_id", object_id),
        };
        const spec = abi.driver.WriteSpec_ABI{
            .table = abi.Slice_ABI.from("delete_object"),
            .fields_ptr = &fields,
            .fields_len = fields.len,
        };
        try checkErr(write_fn(self.handle, &spec));
    }

    fn getQuotaImpl(
        ptr: *anyopaque,
        _: std.mem.Allocator,
        node_id: []const u8,
    ) anyerror!vfs.BlobStorePort.QuotaInfo {
        const self: *RepoBlobStoreAdapter = @ptrCast(@alignCast(ptr));
        var row: abi.RowView_ABI = undefined;
        var iter: abi.driver.RowIterator_ABI = undefined;
        if (!try self.readSingleRow("get_quota", node_id, 0, 1, &row, &iter)) {
            deinitIter(&iter);
            return error.QuotaNotFound;
        }
        defer deinitIter(&iter);

        const limit_val = findField(&row, "limit_bytes") orelse return error.MissingQuotaField;
        const used_val = findField(&row, "used_bytes") orelse return error.MissingQuotaField;
        return .{
            .limit_bytes = limit_val.payload.u,
            .used_bytes = used_val.payload.u,
        };
    }
};

const std = @import("std");
const sdk = @import("parabellum_sdk");
const vfs = @import("vfs");
const tika = @import("tika");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const WriteDataInputs = struct {
    op: []const u8 = "file",
    vault_id: []const u8 = "default",
    partition: []const u8 = "",
    parent_id: []const u8 = "",
    name: []const u8 = "",
    data: []const u8 = "",
    source_path: []const u8 = "",
    /// JSON array of `{"name":"...","data":"..."}` objects when `op == "packed"`.
    files_json: []const u8 = "",
};

pub const WriteDataOutputs = struct {
    count: i64,
    inode_id: []const u8,
    logical_size: i64,
};

pub const WriteDataService = struct {
    state: *DaemonState,
    logger: Logger,
    local_fs_repo: ?DaemonState.RepoRef = null,
    progress: container.ProgressReporter = .{},

    const PackedItem = struct {
        name: []const u8,
        data: []const u8,
    };

    pub fn execute(self: *WriteDataService, alloc: std.mem.Allocator, inputs: WriteDataInputs) !WriteDataOutputs {
        if (inputs.parent_id.len == 0 and inputs.partition.len == 0) {
            return error.RootUploadNotAllowed;
        }
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        const parent: ?[]const u8 = if (inputs.parent_id.len == 0) null else inputs.parent_id;

        if (std.mem.eql(u8, inputs.op, "packed")) {
            const parsed = try std.json.parseFromSlice([]const PackedItem, alloc, inputs.files_json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();

            const batch = try alloc.alloc(vfs.Vault.BatchFileInput, parsed.value.len);
            defer alloc.free(batch);
            var total_packed: u64 = 0;
            for (parsed.value, 0..) |item, i| {
                batch[i] = .{ .parent_id = parent, .name = item.name, .plaintext = item.data };
                total_packed += item.data.len;
            }
            self.progress.report(0, total_packed);

            const ids = try entry.vault.writePacked(batch, .{ .auto_pack_enabled = true }, 1700000000);
            self.progress.report(total_packed, total_packed);
            defer {
                for (ids) |id| entry.vault.allocator.free(id);
                entry.vault.allocator.free(ids);
            }

            var aw: std.Io.Writer.Allocating = .init(alloc);
            errdefer aw.deinit();
            try aw.writer.writeByte('[');
            for (ids, 0..) |id, i| {
                if (i > 0) try aw.writer.writeByte(',');
                try aw.writer.print("\"{s}\"", .{id});
            }
            try aw.writer.writeByte(']');

            return .{
                .count = @intCast(ids.len),
                .inode_id = try aw.toOwnedSlice(),
                .logical_size = 0,
            };
        }

        // Single file upload: supports inline data, "base64:...", or reading from `source_path`.
        var owned_buf: ?[]u8 = null;
        defer if (owned_buf) |b| alloc.free(b);

        const raw_bytes: []const u8 = if (inputs.source_path.len > 0) blk: {
            if (self.local_fs_repo) |fs_repo| {
                if (fs_repo.vtable.read_stream) |read_fn| {
                    var iter: sdk.abi.driver.RowIterator_ABI = undefined;
                    const spec = sdk.abi.driver.ReadSpec_ABI{
                        .table = sdk.abi.Slice_ABI.from("file"),
                        .filter_sql_or_expr = sdk.abi.Slice_ABI.from(inputs.source_path),
                    };
                    if (read_fn(fs_repo.handle, &spec, &iter) == .ok) {
                        defer iter.vtable.deinit(iter.handle);
                        var row: sdk.abi.RowView_ABI = undefined;
                        if (iter.vtable.next(iter.handle, &row) == .ok) {
                            for (row.fieldsSlice()) |f| {
                                if (std.mem.eql(u8, std.mem.span(f.name), "data") and f.value.tag == .bytes_val) {
                                    const dup = try alloc.dupe(u8, f.value.payload.bytes.toSlice());
                                    owned_buf = dup;
                                    break :blk dup;
                                }
                            }
                        }
                    }
                }
            }
            const file = try std.Io.Dir.cwd().openFile(self.state.io, inputs.source_path, .{});
            defer file.close(self.state.io);
            const stat = try file.stat(self.state.io);
            const buf = try alloc.alloc(u8, @intCast(stat.size));
            owned_buf = buf;
            var reader = file.reader(self.state.io, &.{});
            try reader.interface.readSliceAll(buf);
            break :blk buf;
        } else if (std.mem.startsWith(u8, inputs.data, "base64:")) blk: {
            const b64_payload = inputs.data["base64:".len..];
            const max_len = try std.base64.standard.Decoder.calcSizeUpperBound(b64_payload.len);
            const buf = try alloc.alloc(u8, max_len);
            owned_buf = buf;
            try std.base64.standard.Decoder.decode(buf, b64_payload);
            const exact_len = std.base64.standard.Decoder.calcSizeForSlice(b64_payload) catch max_len;
            break :blk buf[0..exact_len];
        } else inputs.data;

        const target_name = if (inputs.name.len > 0)
            inputs.name
        else if (inputs.source_path.len > 0)
            std.fs.path.basename(inputs.source_path)
        else
            return error.MissingFileName;

        const effective_parent: ?[]const u8 = if (inputs.partition.len > 0) blk: {
            const p = entry.partitions.partitions.get(inputs.partition) orelse return error.PartitionNotFound;
            break :blk p.root_inode_id;
        } else parent;
        const prev_inode_id: ?[]u8 = if (entry.vault.stat(effective_parent, target_name)) |existing|
            try alloc.dupe(u8, existing.inode_id)
        else
            null;
        defer if (prev_inode_id) |pid| alloc.free(pid);

        const detected = tika.detect(raw_bytes);
        const mime_opt: ?[]const u8 = if (std.mem.eql(u8, detected.mime_type, "application/octet-stream")) null else detected.mime_type;

        self.progress.report(0, raw_bytes.len);

        const id = if (inputs.partition.len > 0)
            try entry.partitions.writeFileWithMime(&entry.vault, inputs.partition, target_name, raw_bytes, mime_opt, 1700000000)
        else
            try entry.vault.write(parent, target_name, raw_bytes, .{ .mime_type = mime_opt }, 1700000000);
        defer self.state.allocator.free(id);

        if (prev_inode_id) |old_id| {
            if (!std.mem.eql(u8, old_id, id)) {
                entry.vault.delete(old_id, 1700000000) catch {};
            }
        }
        self.progress.report(raw_bytes.len, raw_bytes.len);

        self.logger.info("Uploaded '{s}' ({d} bytes) -> '{s}'", .{ target_name, raw_bytes.len, id });
        return .{
            .count = 1,
            .inode_id = try alloc.dupe(u8, id),
            .logical_size = @intCast(raw_bytes.len),
        };
    }
};

const std = @import("std");
const sdk = @import("parabellum_sdk");
const vfs = @import("vfs");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const WritePackedInputs = struct {
    vault_id: []const u8 = "default",
    parent_id: []const u8 = "",
    /// JSON array of `{"name":"...","data":"..."}` objects.
    files_json: []const u8,
};

pub const WritePackedOutputs = struct {
    count: i64,
    inode_ids_json: []const u8,
};

pub const WritePackedService = struct {
    state: *DaemonState,
    logger: Logger,

    const JsonItem = struct {
        name: []const u8,
        data: []const u8,
    };

    pub fn execute(self: *WritePackedService, alloc: std.mem.Allocator, inputs: WritePackedInputs) !WritePackedOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        const parent: ?[]const u8 = if (inputs.parent_id.len == 0) null else inputs.parent_id;

        const parsed = try std.json.parseFromSlice([]const JsonItem, alloc, inputs.files_json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const batch = try alloc.alloc(vfs.Vault.BatchFileInput, parsed.value.len);
        defer alloc.free(batch);
        for (parsed.value, 0..) |item, i| {
            batch[i] = .{
                .parent_id = parent,
                .name = item.name,
                .plaintext = item.data,
            };
        }

        const ids = try entry.vault.writePacked(batch, .{ .auto_pack_enabled = true }, 1700000000);
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

        self.logger.info("Packed {d} small files in vault '{s}'", .{ ids.len, inputs.vault_id });
        return .{
            .count = @intCast(ids.len),
            .inode_ids_json = try aw.toOwnedSlice(),
        };
    }
};

const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const UploadInputs = struct {
    vault_id: []const u8 = "default",
    partition: []const u8 = "",
    parent_id: []const u8 = "",
    name: []const u8,
    data: []const u8,
};

pub const UploadOutputs = struct {
    inode_id: []const u8,
    logical_size: i64,
};

pub const UploadFileService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *UploadFileService, alloc: std.mem.Allocator, inputs: UploadInputs) !UploadOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");

        const id = if (inputs.partition.len > 0)
            try entry.partitions.writeFile(&entry.vault, inputs.partition, inputs.name, inputs.data, 1700000000)
        else blk: {
            const parent: ?[]const u8 = if (inputs.parent_id.len == 0) null else inputs.parent_id;
            break :blk try entry.vault.write(parent, inputs.name, inputs.data, .{}, 1700000000);
        };
        defer self.state.allocator.free(id);

        self.logger.info("Uploaded '{s}' ({d} bytes) -> '{s}'", .{ inputs.name, inputs.data.len, id });
        return .{
            .inode_id = try alloc.dupe(u8, id),
            .logical_size = @intCast(inputs.data.len),
        };
    }
};

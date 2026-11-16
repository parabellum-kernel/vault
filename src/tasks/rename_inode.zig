const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const RenameInputs = struct {
    vault_id: []const u8 = "default",
    inode_id: []const u8,
    new_parent_id: []const u8 = "",
    new_name: []const u8,
};

pub const RenameOutputs = struct {
    renamed: bool,
};

pub const RenameInodeService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *RenameInodeService, _: std.mem.Allocator, inputs: RenameInputs) !RenameOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        const parent: ?[]const u8 = if (inputs.new_parent_id.len == 0) null else inputs.new_parent_id;
        try entry.vault.rename(inputs.inode_id, parent, inputs.new_name, 1700000000);
        self.logger.info("Renamed inode '{s}' -> '{s}'", .{ inputs.inode_id, inputs.new_name });
        return .{ .renamed = true };
    }
};

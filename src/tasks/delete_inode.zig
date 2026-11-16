const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const DeleteInputs = struct {
    vault_id: []const u8 = "default",
    inode_id: []const u8,
};

pub const DeleteOutputs = struct {
    deleted: bool,
};

pub const DeleteInodeService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *DeleteInodeService, _: std.mem.Allocator, inputs: DeleteInputs) !DeleteOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        try entry.vault.delete(inputs.inode_id, 1700000000);
        self.logger.info("Deleted inode '{s}' from vault '{s}'", .{ inputs.inode_id, inputs.vault_id });
        return .{ .deleted = true };
    }
};

const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const MkdirInputs = struct {
    vault_id: []const u8 = "default",
    parent_id: []const u8 = "",
    name: []const u8,
};

pub const MkdirOutputs = struct {
    inode_id: []const u8,
};

pub const MkdirService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *MkdirService, alloc: std.mem.Allocator, inputs: MkdirInputs) !MkdirOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        const parent: ?[]const u8 = if (inputs.parent_id.len == 0) null else inputs.parent_id;
        const id = try entry.vault.mkdir(parent, inputs.name, 1700000000);
        defer self.state.allocator.free(id);
        self.logger.info("Created directory '{s}' -> '{s}'", .{ inputs.name, id });
        return .{ .inode_id = try alloc.dupe(u8, id) };
    }
};

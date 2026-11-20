const std = @import("std");
const sdk = @import("parabellum_sdk");
const VaultState = @import("../VaultState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const CatalogWriteInputs = struct {
    op: []const u8 = "mkdir",
    vault_id: []const u8 = "default",
    parent_id: []const u8 = "",
    inode_id: []const u8 = "",
    name: []const u8 = "",
};

pub const CatalogWriteOutputs = struct {
    ok: bool,
    op: []const u8,
    inode_id: []const u8,
};

pub const CatalogWriteService = struct {
    state: *VaultState,
    logger: Logger,

    pub fn execute(self: *CatalogWriteService, alloc: std.mem.Allocator, inputs: CatalogWriteInputs) !CatalogWriteOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");

        if (std.mem.eql(u8, inputs.op, "rename")) {
            const parent: ?[]const u8 = if (inputs.parent_id.len == 0) null else inputs.parent_id;
            try entry.vault.rename(inputs.inode_id, parent, inputs.name, 1700000000);
            self.logger.info("Renamed inode '{s}' -> '{s}'", .{ inputs.inode_id, inputs.name });
            return .{ .ok = true, .op = "rename", .inode_id = try alloc.dupe(u8, inputs.inode_id) };
        }

        if (std.mem.eql(u8, inputs.op, "delete")) {
            try entry.vault.delete(inputs.inode_id, 1700000000);
            self.logger.info("Deleted inode '{s}' from vault '{s}'", .{ inputs.inode_id, inputs.vault_id });
            return .{ .ok = true, .op = "delete", .inode_id = try alloc.dupe(u8, inputs.inode_id) };
        }

        // Default: "mkdir"
        const parent: ?[]const u8 = if (inputs.parent_id.len == 0) null else inputs.parent_id;
        const id = try entry.vault.mkdir(parent, inputs.name, 1700000000);
        defer self.state.allocator.free(id);
        self.logger.info("Created directory '{s}' -> '{s}'", .{ inputs.name, id });
        return .{ .ok = true, .op = "mkdir", .inode_id = try alloc.dupe(u8, id) };
    }
};

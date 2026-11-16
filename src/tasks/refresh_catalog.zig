const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const RefreshInputs = struct {
    vault_id: []const u8 = "default",
};

pub const RefreshOutputs = struct {
    updated: bool,
};

pub const RefreshCatalogService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *RefreshCatalogService, _: std.mem.Allocator, inputs: RefreshInputs) !RefreshOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        const updated = try entry.vault.refresh();
        self.logger.info("Refreshed vault '{s}' (updated={})", .{ inputs.vault_id, updated });
        return .{ .updated = updated };
    }
};

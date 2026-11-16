const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const InitInputs = struct {
    vault_id: []const u8 = "default",
    device_id: []const u8 = "vault-desktop-01",
};

pub const InitOutputs = struct {
    status: []const u8,
    vault_id: []const u8,
};

pub const InitVaultService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *InitVaultService, alloc: std.mem.Allocator, inputs: InitInputs) !InitOutputs {
        self.logger.info("Initializing vault '{s}' for device '{s}'", .{ inputs.vault_id, inputs.device_id });
        _ = try container.getOrMountVault(self.state, inputs.vault_id, inputs.device_id);
        return .{
            .status = "ready",
            .vault_id = try alloc.dupe(u8, inputs.vault_id),
        };
    }
};

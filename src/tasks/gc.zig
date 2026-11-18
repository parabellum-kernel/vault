const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const GcInputs = struct {
    vault_id: []const u8 = "default",
};

pub const GcOutputs = struct {
    deleted_blobs: i64,
};

pub const GcService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *GcService, _: std.mem.Allocator, inputs: GcInputs) !GcOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        _ = try entry.vault.refresh();
        const n = try entry.vault.runGc();
        self.logger.info("GC deleted {d} blobs in vault '{s}'", .{ n, inputs.vault_id });
        return .{ .deleted_blobs = @intCast(n) };
    }
};

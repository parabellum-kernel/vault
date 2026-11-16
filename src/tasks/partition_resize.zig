const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const PartitionResizeInputs = struct {
    vault_id: []const u8 = "default",
    name: []const u8,
    new_quota_bytes: i64,
};

pub const PartitionResizeOutputs = struct {
    resized: bool,
    new_quota_bytes: i64,
};

pub const PartitionResizeService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *PartitionResizeService, _: std.mem.Allocator, inputs: PartitionResizeInputs) !PartitionResizeOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        const q: u64 = @intCast(@max(@as(i64, 0), inputs.new_quota_bytes));
        try entry.partitions.resizePartition(inputs.name, q);
        self.logger.info("Resized partition '{s}' to {d} bytes", .{ inputs.name, q });
        return .{ .resized = true, .new_quota_bytes = @intCast(q) };
    }
};

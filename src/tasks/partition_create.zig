const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const PartitionManager = @import("../PartitionManager.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const PartitionCreateInputs = struct {
    vault_id: []const u8 = "default",
    name: []const u8,
    root_folder: []const u8,
    quota_bytes: i64,
    policy: []const u8 = "most_available",
};

pub const PartitionCreateOutputs = struct {
    created: bool,
};

pub const PartitionCreateService = struct {
    state: *DaemonState,
    logger: Logger,

    fn parsePolicy(s: []const u8) PartitionManager.PolicyKind {
        if (std.mem.eql(u8, s, "first_fit")) return .first_fit;
        if (std.mem.eql(u8, s, "random")) return .random;
        if (std.mem.eql(u8, s, "pinned")) return .pinned;
        return .most_available;
    }

    pub fn execute(self: *PartitionCreateService, _: std.mem.Allocator, inputs: PartitionCreateInputs) !PartitionCreateOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        const quota: u64 = @intCast(@max(@as(i64, 0), inputs.quota_bytes));
        try entry.partitions.createPartition(
            &entry.vault,
            inputs.name,
            inputs.root_folder,
            quota,
            parsePolicy(inputs.policy),
            &.{},
            1700000000,
        );
        self.logger.info("Created partition '{s}' ({d} bytes)", .{ inputs.name, quota });
        return .{ .created = true };
    }
};

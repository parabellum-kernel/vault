const std = @import("std");
const sdk = @import("parabellum_sdk");
const VaultState = @import("../VaultState.zig");
const PartitionManager = @import("../PartitionManager.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const MountInputs = struct {
    op: []const u8 = "init",
    vault_id: []const u8 = "default",
    device_id: []const u8 = "vault-desktop-01",
    partition: []const u8 = "",
    root_folder: []const u8 = "",
    quota_bytes: i64 = 0,
    policy: []const u8 = "most_available",
};

pub const MountOutputs = struct {
    status: []const u8,
    vault_id: []const u8,
};

pub const MountService = struct {
    state: *VaultState,
    logger: Logger,

    pub fn execute(self: *MountService, alloc: std.mem.Allocator, inputs: MountInputs) !MountOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, inputs.device_id);

        if (std.mem.eql(u8, inputs.op, "partition_create")) {
            const policy_kind = std.meta.stringToEnum(PartitionManager.PolicyKind, inputs.policy) orelse .most_available;
            try entry.partitions.createPartition(
                &entry.vault,
                inputs.partition,
                inputs.root_folder,
                @intCast(@max(0, inputs.quota_bytes)),
                policy_kind,
                &.{},
                1700000000,
            );
            self.logger.info("Created partition '{s}' in vault '{s}'", .{ inputs.partition, inputs.vault_id });
            return .{ .status = "partition_created", .vault_id = try alloc.dupe(u8, inputs.vault_id) };
        }

        if (std.mem.eql(u8, inputs.op, "partition_resize")) {
            try entry.partitions.resizePartition(inputs.partition, @intCast(@max(0, inputs.quota_bytes)));
            self.logger.info("Resized partition '{s}' in vault '{s}'", .{ inputs.partition, inputs.vault_id });
            return .{ .status = "partition_resized", .vault_id = try alloc.dupe(u8, inputs.vault_id) };
        }

        self.logger.info("Mounted vault '{s}' for device '{s}'", .{ inputs.vault_id, inputs.device_id });
        return .{
            .status = "ready",
            .vault_id = try alloc.dupe(u8, inputs.vault_id),
        };
    }
};

const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const VaultIdInputs = struct {
    vault_id: []const u8 = "default",
};

pub const QuotasOutputs = struct {
    total_bytes: i64,
    used_bytes: i64,
    available_bytes: i64,
    node_count: i64,
};

pub const GetQuotasService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *GetQuotasService, _: std.mem.Allocator, inputs: VaultIdInputs) !QuotasOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        var q = try entry.vault.getQuotas(1700000000);
        defer q.deinit(entry.vault.allocator);
        self.logger.info("Quotas for '{s}': {d}/{d} bytes used", .{ inputs.vault_id, q.used_bytes, q.total_bytes });
        return .{
            .total_bytes = @intCast(q.total_bytes),
            .used_bytes = @intCast(q.used_bytes),
            .available_bytes = @intCast(q.available_bytes),
            .node_count = @intCast(q.nodes.len),
        };
    }
};

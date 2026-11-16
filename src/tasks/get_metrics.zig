const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const MetricsInputs = struct {
    vault_id: []const u8 = "default",
};

pub const MetricsOutputs = struct {
    cache_hits: i64,
    cache_misses: i64,
    cache_bytes: i64,
    partition_count: i64,
    job_count: i64,
};

pub const GetMetricsService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *GetMetricsService, _: std.mem.Allocator, inputs: MetricsInputs) !MetricsOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        const rc = &entry.vault.session.range_cache;
        self.logger.info("Metrics for '{s}': cache hits={d} misses={d}", .{ inputs.vault_id, rc.hits, rc.misses });
        return .{
            .cache_hits = @intCast(rc.hits),
            .cache_misses = @intCast(rc.misses),
            .cache_bytes = @intCast(rc.current_bytes),
            .partition_count = @intCast(entry.partitions.partitions.count()),
            .job_count = @intCast(self.state.jobs.items.len),
        };
    }
};

const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");

const Logger = sdk.task.Logger;

pub const EnqueueJobInputs = struct {
    vault_id: []const u8 = "default",
    kind: []const u8 = "sync",
    target_path: []const u8 = "/",
};

pub const EnqueueJobOutputs = struct {
    job_id: i64,
    queued_count: i64,
};

pub const EnqueueJobService = struct {
    state: *DaemonState,
    logger: Logger,

    fn parseKind(s: []const u8) DaemonState.JobKind {
        if (std.mem.eql(u8, s, "upload")) return .upload;
        if (std.mem.eql(u8, s, "download")) return .download;
        if (std.mem.eql(u8, s, "gc")) return .gc;
        return .sync;
    }

    pub fn execute(self: *EnqueueJobService, _: std.mem.Allocator, inputs: EnqueueJobInputs) !EnqueueJobOutputs {
        const id = try self.state.enqueueJob(
            inputs.vault_id,
            parseKind(inputs.kind),
            inputs.target_path,
            1700000000,
        );
        self.logger.info("Enqueued job #{d} ({s}) for '{s}'", .{ id, inputs.kind, inputs.target_path });
        return .{
            .job_id = @intCast(id),
            .queued_count = @intCast(self.state.jobs.items.len),
        };
    }
};

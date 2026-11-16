const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const ReadInputs = struct {
    vault_id: []const u8 = "default",
    inode_id: []const u8,
    offset: i64 = 0,
    max_len: i64 = 65536,
};

pub const ReadOutputs = struct {
    bytes_read: i64,
    data: []const u8,
};

pub const ReadRangeService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *ReadRangeService, alloc: std.mem.Allocator, inputs: ReadInputs) !ReadOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");

        const max_len: usize = @intCast(@max(@as(i64, 0), inputs.max_len));
        const offset: u64 = @intCast(@max(@as(i64, 0), inputs.offset));
        const buf = try alloc.alloc(u8, max_len);
        errdefer alloc.free(buf);

        const n = try entry.vault.readAt(inputs.inode_id, offset, buf);
        const exact = try alloc.realloc(buf, n);

        self.logger.info("Read {d} bytes from '{s}' at offset {d}", .{ n, inputs.inode_id, offset });
        return .{
            .bytes_read = @intCast(n),
            .data = exact,
        };
    }
};

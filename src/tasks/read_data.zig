const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");
const stream_mod = @import("stream.zig");

const Logger = sdk.task.Logger;

pub const ReadDataInputs = struct {
    op: []const u8 = "range",
    vault_id: []const u8 = "default",
    inode_id: []const u8,
    offset: i64 = 0,
    max_len: i64 = 262144,
    range: []const u8 = "",
    encoding: []const u8 = "raw",
};

pub const ReadDataOutputs = struct {
    status_code: i64,
    total_size: i64,
    offset: i64,
    bytes_read: i64,
    content_range: []const u8,
    mime_type: []const u8,
    data: []const u8,
};

pub const ReadDataService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *ReadDataService, alloc: std.mem.Allocator, inputs: ReadDataInputs) !ReadDataOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");

        if (std.mem.eql(u8, inputs.op, "stream") or inputs.range.len > 0) {
            var stream_svc = stream_mod.StreamRangeService{ .state = self.state, .logger = self.logger };
            const res = try stream_svc.execute(alloc, .{
                .vault_id = inputs.vault_id,
                .inode_id = inputs.inode_id,
                .range = inputs.range,
                .max_chunk = inputs.max_len,
            });
            const out_bytes = if (std.mem.eql(u8, inputs.encoding, "base64")) blk: {
                const b64_len = std.base64.standard.Encoder.calcSize(res.data.len);
                const b64_buf = try alloc.alloc(u8, b64_len);
                _ = std.base64.standard.Encoder.encode(b64_buf, res.data);
                alloc.free(res.data);
                break :blk b64_buf;
            } else res.data;
            return .{
                .status_code = res.status_code,
                .total_size = res.total_size,
                .offset = res.offset,
                .bytes_read = res.bytes_read,
                .content_range = res.content_range,
                .mime_type = res.mime_type,
                .data = out_bytes,
            };
        }

        const off: u64 = @intCast(@max(0, inputs.offset));
        const len: usize = @intCast(@max(0, inputs.max_len));
        const buf = try alloc.alloc(u8, len);
        errdefer alloc.free(buf);

        const n = try entry.vault.readAt(inputs.inode_id, off, buf);
        const raw_data = try alloc.realloc(buf, n);
        const out_data = if (std.mem.eql(u8, inputs.encoding, "base64")) blk: {
            const b64_len = std.base64.standard.Encoder.calcSize(raw_data.len);
            const b64_buf = try alloc.alloc(u8, b64_len);
            _ = std.base64.standard.Encoder.encode(b64_buf, raw_data);
            alloc.free(raw_data);
            break :blk b64_buf;
        } else raw_data;
        return .{
            .status_code = 200,
            .total_size = @intCast(n),
            .offset = inputs.offset,
            .bytes_read = @intCast(n),
            .content_range = "",
            .mime_type = "application/octet-stream",
            .data = out_data,
        };
    }
};

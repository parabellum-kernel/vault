const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const StreamInputs = struct {
    vault_id: []const u8 = "default",
    inode_id: []const u8,
    /// Optional HTTP Range header value, e.g. "bytes=0-65535" or "bytes=1024-".
    range: []const u8 = "",
    /// Maximum chunk size when `range` has an open end (default 256 KiB).
    max_chunk: i64 = 262144,
};

pub const StreamOutputs = struct {
    status_code: i64,
    total_size: i64,
    offset: i64,
    bytes_read: i64,
    content_range: []const u8,
    data: []const u8,
};

pub const ParsedRange = struct {
    start: u64,
    end_inclusive: u64,
    is_partial: bool,
};

/// Parse an HTTP `Range: bytes=start-end` header against `total_size`.
pub fn parseHttpRange(range_header: []const u8, total_size: u64, max_chunk: u64) !ParsedRange {
    if (total_size == 0) {
        return .{ .start = 0, .end_inclusive = 0, .is_partial = range_header.len > 0 };
    }
    const cap = if (max_chunk == 0) 262144 else max_chunk;
    const trimmed = std.mem.trim(u8, range_header, " \t\r\n");
    if (trimmed.len == 0) {
        const end = @min(total_size - 1, cap - 1);
        return .{ .start = 0, .end_inclusive = end, .is_partial = false };
    }
    if (!std.mem.startsWith(u8, trimmed, "bytes=")) return error.InvalidRangeHeader;
    const spec = trimmed["bytes=".len..];
    const dash_idx = std.mem.indexOfScalar(u8, spec, '-') orelse return error.InvalidRangeHeader;
    const start_str = spec[0..dash_idx];
    const end_str = spec[dash_idx + 1 ..];

    if (start_str.len == 0) {
        // Suffix range: bytes=-N
        const suffix = try std.fmt.parseInt(u64, end_str, 10);
        const start = if (suffix >= total_size) 0 else total_size - suffix;
        const end = @min(total_size - 1, start + cap - 1);
        return .{ .start = start, .end_inclusive = end, .is_partial = true };
    }

    const start = try std.fmt.parseInt(u64, start_str, 10);
    if (start >= total_size) return error.RangeNotSatisfiable;

    const requested_end = if (end_str.len == 0)
        @min(total_size - 1, start + cap - 1)
    else
        @min(total_size - 1, try std.fmt.parseInt(u64, end_str, 10));

    if (requested_end < start) return error.InvalidRangeHeader;
    return .{ .start = start, .end_inclusive = requested_end, .is_partial = true };
}

pub const StreamRangeService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *StreamRangeService, alloc: std.mem.Allocator, inputs: StreamInputs) !StreamOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        const inode = entry.vault.catalog.getInode(inputs.inode_id) orelse return error.InodeNotFound;
        const total_size: u64 = inode.logical_size;
        const max_chunk: u64 = @intCast(@max(@as(i64, 1), inputs.max_chunk));

        const pr = try parseHttpRange(inputs.range, total_size, max_chunk);
        if (total_size == 0) {
            return .{
                .status_code = if (pr.is_partial) 206 else 200,
                .total_size = 0,
                .offset = 0,
                .bytes_read = 0,
                .content_range = try alloc.dupe(u8, "bytes */0"),
                .data = "",
            };
        }

        const want: usize = @intCast(pr.end_inclusive - pr.start + 1);
        const buf = try alloc.alloc(u8, want);
        errdefer alloc.free(buf);

        const n = try entry.vault.readAt(inputs.inode_id, pr.start, buf);
        const exact = try alloc.realloc(buf, n);
        const actual_end = if (n == 0) pr.start else pr.start + n - 1;
        const content_range = try std.fmt.allocPrint(alloc, "bytes {d}-{d}/{d}", .{ pr.start, actual_end, total_size });

        self.logger.info("Streamed {d} bytes ({s}) for '{s}'", .{ n, content_range, inputs.inode_id });
        return .{
            .status_code = if (pr.is_partial) 206 else 200,
            .total_size = @intCast(total_size),
            .offset = @intCast(pr.start),
            .bytes_read = @intCast(n),
            .content_range = content_range,
            .data = exact,
        };
    }
};

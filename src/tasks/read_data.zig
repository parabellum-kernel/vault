const std = @import("std");
const sdk = @import("parabellum_sdk");
const tika = @import("tika");
const VaultState = @import("../VaultState.zig");
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
    command: []const u8 = "",
    mime_handlers: []const u8 = "",
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
    state: *VaultState,
    logger: Logger,

    pub fn execute(self: *ReadDataService, alloc: std.mem.Allocator, inputs: ReadDataInputs) !ReadDataOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");

        if (std.mem.eql(u8, inputs.op, "open")) {
            return try openViaXdgOpen(self, alloc, entry, inputs.inode_id);
        }

        if (std.mem.eql(u8, inputs.op, "stream_play")) {
            const inode = entry.vault.catalog.getInode(inputs.inode_id) orelse return error.InodeNotFound;
            const total_size = inode.logical_size;

            var probe_buf: [4096]u8 = undefined;
            const probe_n = entry.vault.readAt(inputs.inode_id, 0, &probe_buf) catch 0;
            const mime_type: []const u8 = if (inode.mime_type) |m|
                m
            else if (probe_n > 0)
                tika.detect(probe_buf[0..probe_n]).mime_type
            else
                "application/octet-stream";

            const cmd_spec = if (inputs.command.len > 0)
                inputs.command
            else
                resolveMimeCommand(mime_type, inputs.mime_handlers) orelse "xdg-open";

            if (std.mem.eql(u8, std.mem.trim(u8, cmd_spec, " \t"), "xdg-open")) {
                return try openViaXdgOpen(self, alloc, entry, inputs.inode_id);
            }

            var argv_buf: [16][]const u8 = undefined;
            var argc: usize = 0;
            var tok_it = std.mem.tokenizeAny(u8, cmd_spec, " \t");
            while (tok_it.next()) |tok| {
                if (argc >= argv_buf.len) break;
                argv_buf[argc] = tok;
                argc += 1;
            }
            if (argc == 0) return try openViaXdgOpen(self, alloc, entry, inputs.inode_id);

            const child = try std.process.spawn(self.state.io, .{
                .argv = argv_buf[0..argc],
                .stdin = .pipe,
                .stdout = .ignore,
                .stderr = .ignore,
            });

            const StreamCtx = struct {
                vault_id: []u8,
                inode_id: []u8,
                total_size: u64,
                io: std.Io,
                child: std.process.Child,

                fn run(ctx: *@This()) void {
                    const bg_alloc = std.heap.c_allocator;
                    defer {
                        if (ctx.child.stdin) |s| s.close(ctx.io);
                        _ = ctx.child.wait(ctx.io) catch {};
                        bg_alloc.free(ctx.vault_id);
                        bg_alloc.free(ctx.inode_id);
                        bg_alloc.destroy(ctx);
                    }
                    const stdin_file = ctx.child.stdin orelse return;
                    var chunk: [262144]u8 = undefined;
                    var offset: u64 = 0;
                    while (offset < ctx.total_size) {
                        const st = container.acquireGlobalState();
                        const n = blk: {
                            defer container.releaseGlobalState();
                            const ve = st.getVault(ctx.vault_id) orelse break :blk @as(usize, 0);
                            break :blk ve.vault.readAt(ctx.inode_id, offset, &chunk) catch 0;
                        };
                        if (n == 0) break;
                        var off: usize = 0;
                        while (off < n) {
                            const w = std.c.write(stdin_file.handle, chunk[off..n].ptr, n - off);
                            if (w <= 0) return;
                            off += @intCast(w);
                        }
                        offset += n;
                    }
                }
            };

            const bg_alloc = std.heap.c_allocator;
            const sctx = try bg_alloc.create(StreamCtx);
            sctx.* = .{
                .vault_id = try bg_alloc.dupe(u8, inputs.vault_id),
                .inode_id = try bg_alloc.dupe(u8, inputs.inode_id),
                .total_size = total_size,
                .io = self.state.io,
                .child = child,
            };
            const th = try std.Thread.spawn(.{}, StreamCtx.run, .{sctx});
            th.detach();

            self.logger.info("Streaming '{s}' ({s}, {d} bytes) -> {s}", .{ inode.name, mime_type, total_size, cmd_spec });
            const msg = try std.fmt.allocPrint(alloc, "Streaming {s} ({s}) -> {s}", .{ inode.name, mime_type, cmd_spec });
            return .{
                .status_code = 200,
                .total_size = @intCast(total_size),
                .offset = 0,
                .bytes_read = 0,
                .content_range = "",
                .mime_type = mime_type,
                .data = msg,
            };
        }

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

fn openViaXdgOpen(
    self: *ReadDataService,
    alloc: std.mem.Allocator,
    entry: *VaultState.VaultEntry,
    inode_id: []const u8,
) !ReadDataOutputs {
    const inode = entry.vault.catalog.getInode(inode_id) orelse return error.InodeNotFound;
    const tmp_path = try std.fmt.allocPrint(alloc, "/tmp/vault-{s}-{s}", .{ inode_id, inode.name });

    const io = self.state.io;
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    defer file.close(io);

    var chunk: [262144]u8 = undefined;
    var offset: u64 = 0;
    while (offset < inode.logical_size) {
        const n = try entry.vault.readAt(inode_id, offset, &chunk);
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const w = std.c.write(file.handle, chunk[off..n].ptr, n - off);
            if (w <= 0) return error.WriteFailed;
            off += @intCast(w);
        }
        offset += n;
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ "xdg-open", tmp_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = &child;

    self.logger.info("Opened '{s}' via xdg-open ({d} bytes)", .{ tmp_path, offset });
    const msg = try std.fmt.allocPrint(alloc, "Opened {s} ({d} bytes)", .{ tmp_path, offset });
    return .{
        .status_code = 200,
        .total_size = @intCast(inode.logical_size),
        .offset = 0,
        .bytes_read = @intCast(offset),
        .content_range = "",
        .mime_type = "text/plain",
        .data = msg,
    };
}

fn resolveMimeCommand(mime_type: []const u8, handlers: []const u8) ?[]const u8 {
    if (handlers.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, mime_type, '/');
    var wildcard_match: ?[]const u8 = null;
    var default_match: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, handlers, ';');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const pat = std.mem.trim(u8, pair[0..eq], " \t");
        const cmd = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        if (pat.len == 0 or cmd.len == 0) continue;

        if (std.mem.eql(u8, pat, mime_type)) return cmd;
        if (slash) |s| {
            if (std.mem.endsWith(u8, pat, "/*") and std.mem.eql(u8, pat[0 .. pat.len - 2], mime_type[0..s])) {
                wildcard_match = cmd;
            }
        }
        if (std.mem.eql(u8, pat, "*/*") or std.mem.eql(u8, pat, "default")) {
            default_match = cmd;
        }
    }
    return wildcard_match orelse default_match;
}

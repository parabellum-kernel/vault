const std = @import("std");
const posix = std.posix;

const DEFAULT_BASE_URL = "http://127.0.0.1:8787";
const DEFAULT_VAULT_ID = "default";

const Entry = struct {
    inode_id: []const u8 = "",
    name: []const u8 = "",
    kind: []const u8 = "file",
    logical_size: u64 = 0,
    mtime: i64 = 0,
};

fn writeFd(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = posix.system.write(fd, bytes[off..].ptr, bytes.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn printFd(alloc: std.mem.Allocator, fd: posix.fd_t, comptime fmt: []const u8, fmt_args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, fmt_args);
    defer alloc.free(s);
    try writeFd(fd, s);
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);

    const base_url = init.environ_map.get("VAULT_URL") orelse DEFAULT_BASE_URL;
    const vault_id = init.environ_map.get("VAULT_ID") orelse DEFAULT_VAULT_ID;

    if (args.len <= 1) {
        try runInteractiveTui(alloc, init.io, base_url, vault_id);
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "ls")) {
        const parent_id = if (args.len > 2) args[2] else "";
        const body = try std.fmt.allocPrint(alloc, "{{\"vault_id\":\"{s}\",\"parent_id\":\"{s}\"}}", .{ vault_id, parent_id });
        defer alloc.free(body);
        const resp = try postTask(alloc, init.io, base_url, "vault_ls", body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
        try writeFd(posix.STDOUT_FILENO, "\n");
    } else if (std.mem.eql(u8, cmd, "cat")) {
        if (args.len < 3) {
            try writeFd(posix.STDERR_FILENO, "Usage: vault-tui cat <inode_id>\n");
            return error.InvalidArguments;
        }
        try streamInodeToStdout(alloc, init.io, base_url, vault_id, args[2]);
    } else if (std.mem.eql(u8, cmd, "quotas")) {
        const body = try std.fmt.allocPrint(alloc, "{{\"vault_id\":\"{s}\"}}", .{vault_id});
        defer alloc.free(body);
        const resp = try postTask(alloc, init.io, base_url, "vault_quotas", body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
        try writeFd(posix.STDOUT_FILENO, "\n");
    } else if (std.mem.eql(u8, cmd, "metrics")) {
        const body = try std.fmt.allocPrint(alloc, "{{\"vault_id\":\"{s}\"}}", .{vault_id});
        defer alloc.free(body);
        const resp = try postTask(alloc, init.io, base_url, "vault_metrics", body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
        try writeFd(posix.STDOUT_FILENO, "\n");
    } else if (std.mem.eql(u8, cmd, "gc")) {
        const body = try std.fmt.allocPrint(alloc, "{{\"vault_id\":\"{s}\"}}", .{vault_id});
        defer alloc.free(body);
        const resp = try postTask(alloc, init.io, base_url, "vault_gc", body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
        try writeFd(posix.STDOUT_FILENO, "\n");
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printHelp();
    } else {
        try printHelp();
        return error.UnknownCommand;
    }
}

fn printHelp() !void {
    const help =
        \\vault-tui - Terminal UI & streaming pipe client for Vault VFS Daemon
        \\
        \\Usage:
        \\  vault-tui                  Launch interactive TUI
        \\  vault-tui ls [parent_id]   List directory entries
        \\  vault-tui cat <inode_id>   Stream-decrypt file to stdout (for pipes: | mpv -, | glow -)
        \\  vault-tui quotas           Show pool quotas
        \\  vault-tui metrics          Show API and RangeCache metrics
        \\  vault-tui gc               Run garbage collector
        \\
        \\Environment:
        \\  VAULT_URL   Daemon base URL (default: http://127.0.0.1:8787)
        \\  VAULT_ID    Vault ID (default: default)
        \\
    ;
    try writeFd(posix.STDOUT_FILENO, help);
}

fn postTask(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8, task_name: []const u8, json_body: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(alloc, "{s}/tasks/{s}", .{ base_url, task_name });
    defer alloc.free(url);
    const uri = try std.Uri.parse(url);

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .headers = .{ .accept_encoding = .omit },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = json_body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(json_body);
    try body_writer.end();
    try req.connection.?.flush();

    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (@intFromEnum(response.head.status) >= 400) return error.HttpRequestFailed;

    var out_writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer out_writer.deinit();

    var transfer_buf: [8192]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    _ = body_reader.streamRemaining(&out_writer.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => return err,
    };
    return try out_writer.toOwnedSlice();
}

/// Stream-decrypt an inode in 256 KiB chunks via `vault_stream` directly to stdout.
fn streamInodeToStdout(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8, vault_id: []const u8, inode_id: []const u8) !void {
    var offset: u64 = 0;
    const chunk_size: u64 = 262144;

    while (true) {
        const range_hdr = try std.fmt.allocPrint(alloc, "bytes={d}-{d}", .{ offset, offset + chunk_size - 1 });
        defer alloc.free(range_hdr);

        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"vault_id\":\"{s}\",\"inode_id\":\"{s}\",\"range\":\"{s}\",\"max_chunk\":{d}}}",
            .{ vault_id, inode_id, range_hdr, chunk_size },
        );
        defer alloc.free(body);

        const resp = try postTask(alloc, io, base_url, "vault_stream", body);
        defer alloc.free(resp);

        const parsed = try std.json.parseFromSlice(struct {
            total_size: i64 = 0,
            bytes_read: i64 = 0,
            data: []const u8 = "",
        }, alloc, resp, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (parsed.value.data.len > 0) {
            try writeFd(posix.STDOUT_FILENO, parsed.value.data);
        }
        if (parsed.value.bytes_read <= 0) break;
        offset += @intCast(parsed.value.bytes_read);
        if (parsed.value.total_size >= 0 and offset >= @as(u64, @intCast(parsed.value.total_size))) break;
    }
}

fn runInteractiveTui(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8, vault_id: []const u8) !void {
    const stdin_fd = posix.STDIN_FILENO;
    const orig_termios = try posix.tcgetattr(stdin_fd);
    var raw = orig_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    try posix.tcsetattr(stdin_fd, .FLUSH, raw);
    defer posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {};

    var parent_stack: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (parent_stack.items) |p| alloc.free(p);
        parent_stack.deinit(alloc);
    }

    var selected: usize = 0;
    var status_msg: []const u8 = "Ready (j/k: move, Enter: open/pipe, Backspace: up, g: GC, r: refresh, q: quit)";

    while (true) {
        const current_parent = if (parent_stack.items.len > 0) parent_stack.items[parent_stack.items.len - 1] else "";
        const ls_body = try std.fmt.allocPrint(alloc, "{{\"vault_id\":\"{s}\",\"parent_id\":\"{s}\"}}", .{ vault_id, current_parent });
        defer alloc.free(ls_body);

        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        defer {
            for (entries.items) |e| {
                alloc.free(e.inode_id);
                alloc.free(e.name);
                alloc.free(e.kind);
            }
            entries.deinit(alloc);
        }

        const ls_resp = postTask(alloc, io, base_url, "vault_ls", ls_body) catch |err| blk: {
            status_msg = @errorName(err);
            break :blk null;
        };
        defer if (ls_resp) |r| alloc.free(r);

        if (ls_resp) |resp| {
            if (std.json.parseFromSlice(struct {
                entries_json: []const u8 = "[]",
            }, alloc, resp, .{ .ignore_unknown_fields = true })) |top_parsed| {
                defer top_parsed.deinit();
                if (std.json.parseFromSlice([]const Entry, alloc, top_parsed.value.entries_json, .{ .ignore_unknown_fields = true })) |list_parsed| {
                    defer list_parsed.deinit();
                    for (list_parsed.value) |e| {
                        try entries.append(alloc, .{
                            .inode_id = try alloc.dupe(u8, e.inode_id),
                            .name = try alloc.dupe(u8, e.name),
                            .kind = try alloc.dupe(u8, e.kind),
                            .logical_size = e.logical_size,
                            .mtime = e.mtime,
                        });
                    }
                } else |_| {}
            } else |_| {}
        }

        if (entries.items.len > 0 and selected >= entries.items.len) {
            selected = entries.items.len - 1;
        }

        try writeFd(posix.STDOUT_FILENO, "\x1b[2J\x1b[H");
        try printFd(alloc, posix.STDOUT_FILENO, "\x1b[1;36mVault TUI\x1b[0m | url: {s} | vault: {s} | parent: {s}\r\n", .{
            base_url,
            vault_id,
            if (current_parent.len == 0) "/" else current_parent,
        });
        try writeFd(posix.STDOUT_FILENO, "--------------------------------------------------------------------------------\r\n");

        if (entries.items.len == 0) {
            try writeFd(posix.STDOUT_FILENO, "  (empty directory or daemon offline)\r\n");
        } else {
            for (entries.items, 0..) |e, idx| {
                const marker = if (idx == selected) ">" else " ";
                const is_dir = std.mem.eql(u8, e.kind, "directory");
                const kind = if (is_dir) "[DIR]" else "     ";
                if (idx == selected) {
                    try printFd(alloc, posix.STDOUT_FILENO, "\x1b[7m{s} {s} {s} ({d} B)\x1b[0m\r\n", .{ marker, kind, e.name, e.logical_size });
                } else {
                    try printFd(alloc, posix.STDOUT_FILENO, "{s} {s} {s} ({d} B)\r\n", .{ marker, kind, e.name, e.logical_size });
                }
            }
        }

        try writeFd(posix.STDOUT_FILENO, "--------------------------------------------------------------------------------\r\n");
        try printFd(alloc, posix.STDOUT_FILENO, "{s}\r\n", .{status_msg});

        var key_buf: [3]u8 = undefined;
        const n = try posix.read(stdin_fd, &key_buf);
        if (n == 0) break;

        if (key_buf[0] == 'q') {
            break;
        } else if (key_buf[0] == 'j' or (n == 3 and key_buf[0] == 0x1b and key_buf[1] == '[' and key_buf[2] == 'B')) {
            if (selected + 1 < entries.items.len) selected += 1;
        } else if (key_buf[0] == 'k' or (n == 3 and key_buf[0] == 0x1b and key_buf[1] == '[' and key_buf[2] == 'A')) {
            if (selected > 0) selected -= 1;
        } else if (key_buf[0] == 127 or key_buf[0] == 8) {
            if (parent_stack.items.len > 0) {
                alloc.free(parent_stack.pop().?);
                selected = 0;
            }
        } else if (key_buf[0] == 'g') {
            const gc_body = try std.fmt.allocPrint(alloc, "{{\"vault_id\":\"{s}\"}}", .{vault_id});
            defer alloc.free(gc_body);
            if (postTask(alloc, io, base_url, "vault_gc", gc_body)) |r| {
                alloc.free(r);
                status_msg = "GC completed";
            } else |err| {
                status_msg = @errorName(err);
            }
        } else if (key_buf[0] == 'r') {
            const ref_body = try std.fmt.allocPrint(alloc, "{{\"vault_id\":\"{s}\"}}", .{vault_id});
            defer alloc.free(ref_body);
            if (postTask(alloc, io, base_url, "vault_refresh", ref_body)) |r| {
                alloc.free(r);
                status_msg = "Refresh completed";
            } else |err| {
                status_msg = @errorName(err);
            }
        } else if (key_buf[0] == '\r' or key_buf[0] == '\n') {
            if (entries.items.len > 0) {
                const item = entries.items[selected];
                const is_dir = std.mem.eql(u8, item.kind, "directory");
                if (is_dir) {
                    try parent_stack.append(alloc, try alloc.dupe(u8, item.inode_id));
                    selected = 0;
                } else {
                    status_msg = "Pipe command: vault-tui cat <inode_id> | mpv - / glow - / zathura -";
                }
            }
        }
    }
    try writeFd(posix.STDOUT_FILENO, "\x1b[2J\x1b[H");
}

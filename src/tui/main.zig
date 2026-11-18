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

const JobSummary = struct {
    id: u64 = 0,
    pipeline: []const u8 = "",
    status: []const u8 = "",
    progress_bytes: u64 = 0,
    total_bytes: u64 = 0,
};

fn writeFd(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = posix.system.write(fd, bytes[off..].ptr, bytes.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .INTR => continue,
            .AGAIN => continue,
            .PIPE => return error.BrokenPipe,
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
    const home_dir = init.environ_map.get("HOME");
    const has_gui = (init.environ_map.get("DISPLAY") != null or init.environ_map.get("WAYLAND_DISPLAY") != null);
    _ = home_dir;

    if (args.len <= 1) {
        try runInteractiveTui(alloc, init.io, base_url, vault_id, init.environ_map, has_gui);
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "ls")) {
        const parent_id = if (args.len > 2) args[2] else "";
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"pipeline\":\"ls\",\"vault_id\":\"{s}\",\"parent_id\":\"{s}\"}}",
            .{ vault_id, parent_id },
        );
        defer alloc.free(body);
        const resp = try postJob(alloc, init.io, base_url, body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
    } else if (std.mem.eql(u8, cmd, "cat")) {
        if (args.len < 3) {
            try writeFd(posix.STDERR_FILENO, "Usage: vault-tui cat <inode_id>\n");
            return error.InvalidArguments;
        }
        try streamInodeToStdout(alloc, init.io, base_url, vault_id, args[2]);
    } else if (std.mem.eql(u8, cmd, "quotas")) {
        const body = try std.fmt.allocPrint(alloc, "{{\"pipeline\":\"quotas\",\"vault_id\":\"{s}\"}}", .{vault_id});
        defer alloc.free(body);
        const resp = try postJob(alloc, init.io, base_url, body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
    } else if (std.mem.eql(u8, cmd, "metrics")) {
        const body = try std.fmt.allocPrint(alloc, "{{\"pipeline\":\"metrics\",\"vault_id\":\"{s}\"}}", .{vault_id});
        defer alloc.free(body);
        const resp = try postJob(alloc, init.io, base_url, body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
    } else if (std.mem.eql(u8, cmd, "gc")) {
        const body = try std.fmt.allocPrint(alloc, "{{\"pipeline\":\"gc\",\"vault_id\":\"{s}\"}}", .{vault_id});
        defer alloc.free(body);
        const resp = try postJob(alloc, init.io, base_url, body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
    } else if (std.mem.eql(u8, cmd, "upload")) {
        if (args.len < 3) {
            try writeFd(posix.STDERR_FILENO, "Usage: vault-tui upload <file_path> [name] [parent_id]\n");
            return error.InvalidArguments;
        }
        const file_path = args[2];
        const name = if (args.len > 3) args[3] else std.fs.path.basename(file_path);
        const parent_id = if (args.len > 4) args[4] else "";

        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"pipeline\":\"upload\",\"vault_id\":\"{s}\",\"parent_id\":\"{s}\",\"name\":\"{s}\",\"source_path\":\"{s}\"}}",
            .{ vault_id, parent_id, name, file_path },
        );
        defer alloc.free(body);
        const resp = try postJob(alloc, init.io, base_url, body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
    } else if (std.mem.eql(u8, cmd, "jobs")) {
        const resp = try getJobs(alloc, init.io, base_url);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
    } else if (std.mem.eql(u8, cmd, "search")) {
        const query = if (args.len > 2) args[2] else "";
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"pipeline\":\"search\",\"vault_id\":\"{s}\",\"query\":\"{s}\"}}",
            .{ vault_id, query },
        );
        defer alloc.free(body);
        const resp = try postJob(alloc, init.io, base_url, body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
    } else if (std.mem.eql(u8, cmd, "mkdir")) {
        if (args.len < 3) {
            try writeFd(posix.STDERR_FILENO, "Usage: vault-tui mkdir <name> [parent_id]\n");
            return error.InvalidArguments;
        }
        const parent_id = if (args.len > 3) args[3] else "";
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"pipeline\":\"mkdir\",\"vault_id\":\"{s}\",\"parent_id\":\"{s}\",\"name\":\"{s}\"}}",
            .{ vault_id, parent_id, args[2] },
        );
        defer alloc.free(body);
        const resp = try postJob(alloc, init.io, base_url, body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
    } else if (std.mem.eql(u8, cmd, "rm")) {
        if (args.len < 3) {
            try writeFd(posix.STDERR_FILENO, "Usage: vault-tui rm <inode_id>\n");
            return error.InvalidArguments;
        }
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"pipeline\":\"delete\",\"vault_id\":\"{s}\",\"inode_id\":\"{s}\"}}",
            .{ vault_id, args[2] },
        );
        defer alloc.free(body);
        const resp = try postJob(alloc, init.io, base_url, body);
        defer alloc.free(resp);
        try writeFd(posix.STDOUT_FILENO, resp);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printHelp();
    } else {
        try printHelp();
        return error.UnknownCommand;
    }
}

fn printHelp() !void {
    const help =
        \\vault-tui - Optional Terminal UI & CLI client for Parabellum Daemon
        \\
        \\Usage:
        \\  vault-tui                  Launch interactive TUI
        \\  vault-tui ls [parent_id]   List directory entries
        \\  vault-tui cat <inode_id>   Stream-decrypt file to stdout
        \\  vault-tui quotas           Show pool quotas
        \\  vault-tui metrics          Show API and RangeCache metrics
        \\  vault-tui gc               Run garbage collector
        \\  vault-tui upload <path> [name] [parent_id]  Upload local file via daemon
        \\  vault-tui mkdir <name> [parent_id]         Create directory
        \\  vault-tui rm <inode_id>                    Delete file or directory
        \\  vault-tui search <query>                   Search files in vault
        \\  vault-tui jobs                             List background daemon jobs
        \\
        \\Environment:
        \\  VAULT_URL   Daemon base URL (default: http://127.0.0.1:8787)
        \\  VAULT_ID    Vault ID (default: default)
        \\
    ;
    try writeFd(posix.STDOUT_FILENO, help);
}

var last_error_detail: []const u8 = "";
var last_error_buf: [512]u8 = undefined;

fn httpRequest(
    alloc: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    json_body: ?[]const u8,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(method, uri, .{
        .extra_headers = if (json_body != null) &.{
            .{ .name = "Content-Type", .value = "application/json" },
        } else &.{},
        .headers = .{ .accept_encoding = .omit },
    });
    defer req.deinit();

    if (json_body) |body| {
        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    var out_writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer out_writer.deinit();

    var transfer_buf: [8192]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    _ = body_reader.streamRemaining(&out_writer.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => return err,
    };
    const body_res = try out_writer.toOwnedSlice();

    if (@intFromEnum(response.head.status) >= 400) {
        last_error_detail = std.fmt.bufPrint(
            &last_error_buf,
            "HTTP {d}: {s}",
            .{ @intFromEnum(response.head.status), std.mem.trim(u8, body_res, " \t\r\n") },
        ) catch "HTTP error";
        alloc.free(body_res);
        return error.HttpRequestFailed;
    }
    last_error_detail = "";
    return body_res;
}

fn postJob(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8, json_body: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(alloc, "{s}/v1/jobs", .{base_url});
    defer alloc.free(url);
    return try httpRequest(alloc, io, .POST, url, json_body);
}

fn getJobs(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(alloc, "{s}/v1/jobs", .{base_url});
    defer alloc.free(url);
    return try httpRequest(alloc, io, .GET, url, null);
}

/// Stream-decrypt an inode in 256 KiB chunks via `read` pipeline (`op: "stream"`) to `out_fd`.
fn streamInodeToFd(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    vault_id: []const u8,
    inode_id: []const u8,
    out_fd: posix.fd_t,
) !void {
    var offset: u64 = 0;
    const chunk_size: u64 = 262144;

    while (true) {
        const range_hdr = try std.fmt.allocPrint(alloc, "bytes={d}-{d}", .{ offset, offset + chunk_size - 1 });
        defer alloc.free(range_hdr);

        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"pipeline\":\"read\",\"op\":\"stream\",\"encoding\":\"base64\",\"vault_id\":\"{s}\",\"inode_id\":\"{s}\",\"range\":\"{s}\",\"max_len\":{d}}}",
            .{ vault_id, inode_id, range_hdr, chunk_size },
        );
        defer alloc.free(body);

        const resp = try postJob(alloc, io, base_url, body);
        defer alloc.free(resp);

        const parsed = try std.json.parseFromSlice(struct {
            output: ?struct {
                total_size: i64 = 0,
                bytes_read: i64 = 0,
                data: []const u8 = "",
            } = null,
        }, alloc, resp, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const out = parsed.value.output orelse break;
        if (out.data.len > 0) {
            const max_len = try std.base64.standard.Decoder.calcSizeUpperBound(out.data.len);
            const raw_buf = try alloc.alloc(u8, max_len);
            defer alloc.free(raw_buf);
            try std.base64.standard.Decoder.decode(raw_buf, out.data);
            const exact_len = std.base64.standard.Decoder.calcSizeForSlice(out.data) catch max_len;
            try writeFd(out_fd, raw_buf[0..exact_len]);
        }
        if (out.bytes_read <= 0) break;
        offset += @intCast(out.bytes_read);
        if (out.total_size >= 0 and offset >= @as(u64, @intCast(out.total_size))) break;
    }
}

fn streamInodeToStdout(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8, vault_id: []const u8, inode_id: []const u8) !void {
    return streamInodeToFd(alloc, io, base_url, vault_id, inode_id, posix.STDOUT_FILENO);
}

fn openInodeInViewer(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    vault_id: []const u8,
    inode_id: []const u8,
    name: []const u8,
    stdin_fd: posix.fd_t,
    orig_termios: posix.termios,
    raw_termios: posix.termios,
    has_gui: bool,
) ![]const u8 {
    const safe_name = std.fs.path.basename(name);
    const tmp_path = try std.fmt.allocPrint(alloc, "/tmp/vault-{s}", .{safe_name});
    defer alloc.free(tmp_path);

    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
    defer file.close(io);
    try streamInodeToFd(alloc, io, base_url, vault_id, inode_id, file.handle);

    if (has_gui) {
        _ = std.process.spawn(io, .{
            .argv = &.{ "xdg-open", tmp_path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return error.OpenFailed;
        return "Opened with xdg-open";
    }

    try posix.tcsetattr(stdin_fd, .FLUSH, orig_termios);
    defer posix.tcsetattr(stdin_fd, .FLUSH, raw_termios) catch {};
    var child = try std.process.spawn(io, .{
        .argv = &.{ "less", tmp_path },
    });
    _ = child.wait(io) catch {};
    return "Closed viewer";
}

fn fetchDirEntries(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    vault_id: []const u8,
    parent_id: []const u8,
    entries: *std.ArrayListUnmanaged(Entry),
) !void {
    for (entries.items) |e| {
        alloc.free(e.inode_id);
        alloc.free(e.name);
        alloc.free(e.kind);
    }
    entries.clearRetainingCapacity();

    const ls_body = try std.fmt.allocPrint(
        alloc,
        "{{\"pipeline\":\"ls\",\"vault_id\":\"{s}\",\"parent_id\":\"{s}\"}}",
        .{ vault_id, parent_id },
    );
    defer alloc.free(ls_body);

    const ls_resp = try postJob(alloc, io, base_url, ls_body);
    defer alloc.free(ls_resp);

    const top_parsed = try std.json.parseFromSlice(struct {
        output: ?struct {
            data_json: []const u8 = "[]",
        } = null,
    }, alloc, ls_resp, .{ .ignore_unknown_fields = true });
    defer top_parsed.deinit();

    const out = top_parsed.value.output orelse return;
    const list_parsed = try std.json.parseFromSlice([]const Entry, alloc, out.data_json, .{ .ignore_unknown_fields = true });
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
}

fn fetchSearchEntries(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    vault_id: []const u8,
    query: []const u8,
    entries: *std.ArrayListUnmanaged(Entry),
) !void {
    for (entries.items) |e| {
        alloc.free(e.inode_id);
        alloc.free(e.name);
        alloc.free(e.kind);
    }
    entries.clearRetainingCapacity();

    const search_body = try std.fmt.allocPrint(
        alloc,
        "{{\"pipeline\":\"search\",\"vault_id\":\"{s}\",\"query\":\"{s}\"}}",
        .{ vault_id, query },
    );
    defer alloc.free(search_body);

    const search_resp = try postJob(alloc, io, base_url, search_body);
    defer alloc.free(search_resp);

    const top_parsed = try std.json.parseFromSlice(struct {
        output: ?struct {
            data_json: []const u8 = "[]",
        } = null,
    }, alloc, search_resp, .{ .ignore_unknown_fields = true });
    defer top_parsed.deinit();

    const out = top_parsed.value.output orelse return;
    const list_parsed = try std.json.parseFromSlice([]const Entry, alloc, out.data_json, .{ .ignore_unknown_fields = true });
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
}

fn expandPathVars(alloc: std.mem.Allocator, path: []const u8, env_map: *const std.process.Environ.Map) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();

    var i: usize = 0;
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        if (env_map.get("HOME")) |h| {
            try aw.writer.writeAll(h);
            i = 1;
        }
    }

    while (i < path.len) {
        if (path[i] == '$') {
            if (i + 1 < path.len and path[i + 1] == '{') {
                if (std.mem.indexOfScalarPos(u8, path, i + 2, '}')) |close_idx| {
                    const var_name = path[i + 2 .. close_idx];
                    if (env_map.get(var_name)) |val| {
                        try aw.writer.writeAll(val);
                        i = close_idx + 1;
                        continue;
                    }
                }
            } else {
                var end: usize = i + 1;
                while (end < path.len and (std.ascii.isAlphanumeric(path[end]) or path[end] == '_')) : (end += 1) {}
                if (end > i + 1) {
                    const var_name = path[i + 1 .. end];
                    if (env_map.get(var_name)) |val| {
                        try aw.writer.writeAll(val);
                        i = end;
                        continue;
                    }
                }
            }
        }
        try aw.writer.writeByte(path[i]);
        i += 1;
    }
    return try aw.toOwnedSlice();
}

fn completeLocalPath(
    alloc: std.mem.Allocator,
    io: std.Io,
    buf: *std.ArrayListUnmanaged(u8),
    env_map: *const std.process.Environ.Map,
) !?[]u8 {
    const raw_input = buf.items;
    const slash_idx = std.mem.lastIndexOfScalar(u8, raw_input, '/');
    if (slash_idx == null and (std.mem.eql(u8, raw_input, "~") or (raw_input.len > 1 and raw_input[0] == '$'))) {
        const expanded = try expandPathVars(alloc, raw_input, env_map);
        defer alloc.free(expanded);
        if (std.Io.Dir.cwd().openDir(io, expanded, .{})) |d_const| {
            var d = d_const;
            d.close(io);
            try buf.append(alloc, '/');
            return null;
        } else |_| {}
    }
    const dir_raw = if (slash_idx) |i| (if (i == 0) "/" else raw_input[0..i]) else ".";
    const prefix = if (slash_idx) |i| raw_input[i + 1 ..] else raw_input;

    const dir_expanded = try expandPathVars(alloc, dir_raw, env_map);
    defer alloc.free(dir_expanded);

    var dir = std.Io.Dir.cwd().openDir(io, dir_expanded, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    const Match = struct { name: []u8, is_dir: bool };
    var matches: std.ArrayListUnmanaged(Match) = .empty;
    defer {
        for (matches.items) |m| alloc.free(m.name);
        matches.deinit(alloc);
    }

    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (std.mem.startsWith(u8, ent.name, prefix)) {
            try matches.append(alloc, .{
                .name = try alloc.dupe(u8, ent.name),
                .is_dir = ent.kind == .directory,
            });
        }
    }

    if (matches.items.len == 0) return null;

    if (matches.items.len == 1) {
        const m = matches.items[0];
        const suffix = m.name[prefix.len..];
        try buf.appendSlice(alloc, suffix);
        if (m.is_dir) try buf.append(alloc, '/');
        return null;
    }

    // Multiple matches: complete longest common prefix and return hints string
    var lcp_len: usize = matches.items[0].name.len;
    for (matches.items[1..]) |m| {
        const limit = @min(lcp_len, m.name.len);
        var j: usize = prefix.len;
        while (j < limit and matches.items[0].name[j] == m.name[j]) : (j += 1) {}
        lcp_len = j;
    }
    if (lcp_len > prefix.len) {
        try buf.appendSlice(alloc, matches.items[0].name[prefix.len..lcp_len]);
    }

    var hint_aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer hint_aw.deinit();
    const max_show = @min(matches.items.len, 8);
    for (matches.items[0..max_show], 0..) |m, idx| {
        if (idx > 0) try hint_aw.writer.writeAll("  ");
        try hint_aw.writer.writeAll(m.name);
        if (m.is_dir) try hint_aw.writer.writeByte('/');
    }
    if (matches.items.len > max_show) {
        try hint_aw.writer.print("  (+{d} more)", .{matches.items.len - max_show});
    }
    return try hint_aw.toOwnedSlice();
}

fn promptRawLine(
    alloc: std.mem.Allocator,
    io: std.Io,
    stdin_fd: posix.fd_t,
    label: []const u8,
    enable_tab: bool,
    env_map: *const std.process.Environ.Map,
) !?[]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    var hint: ?[]u8 = null;
    defer if (hint) |h| alloc.free(h);

    while (true) {
        try writeFd(posix.STDOUT_FILENO, "\r\x1b[2K");
        try printFd(alloc, posix.STDOUT_FILENO, "{s}{s}", .{ label, buf.items });
        if (hint) |h| {
            try printFd(alloc, posix.STDOUT_FILENO, "\r\n\x1b[2K\x1b[90m{s}\x1b[0m\x1b[1A", .{h});
            try writeFd(posix.STDOUT_FILENO, "\r");
            try printFd(alloc, posix.STDOUT_FILENO, "{s}{s}", .{ label, buf.items });
        }

        var ch: [1]u8 = undefined;
        const n = posix.read(stdin_fd, &ch) catch return null;
        if (n == 0) return null;

        if (ch[0] == '\r' or ch[0] == '\n') {
            try writeFd(posix.STDOUT_FILENO, "\r\n\x1b[2K");
            return try buf.toOwnedSlice(alloc);
        } else if (ch[0] == 0x1b or ch[0] == 3) {
            try writeFd(posix.STDOUT_FILENO, "\r\n\x1b[2K");
            buf.deinit(alloc);
            return null;
        } else if (ch[0] == 127 or ch[0] == 8) {
            if (buf.items.len > 0) _ = buf.pop();
            if (hint) |h| {
                alloc.free(h);
                hint = null;
            }
        } else if (ch[0] == '\t' and enable_tab) {
            if (hint) |h| {
                alloc.free(h);
                hint = null;
            }
            hint = try completeLocalPath(alloc, io, &buf, env_map);
        } else if (ch[0] >= 0x20 and ch[0] < 0x7f) {
            try buf.append(alloc, ch[0]);
            if (hint) |h| {
                alloc.free(h);
                hint = null;
            }
        }
    }
}

fn isMediaFile(name: []const u8) bool {
    const exts = [_][]const u8{ ".mp4", ".mkv", ".webm", ".avi", ".mov", ".m4v", ".mp3", ".flac", ".ogg", ".wav", ".m4a", ".opus" };
    for (exts) |ext| {
        if (name.len >= ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) {
            return true;
        }
    }
    return false;
}

fn spawnDetached(io: std.Io, argv: []const []const u8) bool {
    _ = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    return true;
}

fn formatHumanSize(buf: *[32]u8, bytes: u64) []const u8 {
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "0 B";
    }
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var val: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;
    val /= 1024.0;
    while (val >= 1024.0 and unit_idx + 1 < units.len) {
        val /= 1024.0;
        unit_idx += 1;
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ val, units[unit_idx] }) catch "?";
}

fn formatProgressBar(buf: *[12]u8, done: u64, total: u64) []const u8 {
    buf[0] = '[';
    buf[11] = ']';
    const pct: u64 = if (total > 0) @min(100, (done * 100) / total) else 0;
    const filled: usize = @intCast((pct * 10) / 100);
    for (0..10) |idx| {
        buf[1 + idx] = if (idx < filled) '#' else '-';
    }
    return buf[0..12];
}

fn runInteractiveTui(alloc: std.mem.Allocator, io: std.Io, base_url: []const u8, vault_id: []const u8, env_map: *const std.process.Environ.Map, has_gui: bool) !void {
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

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (entries.items) |e| {
            alloc.free(e.inode_id);
            alloc.free(e.name);
            alloc.free(e.kind);
        }
        entries.deinit(alloc);
    }

    var selected: usize = 0;
    var need_refresh = true;
    var show_transfers = false;
    var active_jobs: usize = 0;
    var jobs_list: std.ArrayListUnmanaged(JobSummary) = .empty;
    defer {
        for (jobs_list.items) |j| {
            alloc.free(j.pipeline);
            alloc.free(j.status);
        }
        jobs_list.deinit(alloc);
    }
    var search_query: ?[]u8 = null;
    defer if (search_query) |sq| alloc.free(sq);
    var status_msg_buf: [256]u8 = undefined;
    var status_msg: []const u8 = "Ready";

    while (true) {
        const current_parent = if (parent_stack.items.len > 0) parent_stack.items[parent_stack.items.len - 1] else "";

        if (need_refresh) {
            if (search_query) |sq| {
                fetchSearchEntries(alloc, io, base_url, vault_id, sq, &entries) catch |err| {
                    status_msg = @errorName(err);
                };
            } else {
                fetchDirEntries(alloc, io, base_url, vault_id, current_parent, &entries) catch |err| {
                    status_msg = @errorName(err);
                };
            }
            need_refresh = false;
        }

        if (entries.items.len > 0 and selected >= entries.items.len) {
            selected = entries.items.len - 1;
        }

        try writeFd(posix.STDOUT_FILENO, "\x1b[2J\x1b[H");
        if (show_transfers) {
            try printFd(alloc, posix.STDOUT_FILENO, "\x1b[1;36mVault Transfers & Jobs\x1b[0m | url: {s} | active: {d} (press 't' to return)\r\n", .{
                base_url,
                active_jobs,
            });
            try writeFd(posix.STDOUT_FILENO, "--------------------------------------------------------------------------------\r\n");
            if (jobs_list.items.len == 0) {
                try writeFd(posix.STDOUT_FILENO, "  (no background transfers/jobs yet)\r\n");
            } else {
                for (jobs_list.items) |j| {
                    var bar_buf: [12]u8 = undefined;
                    var done_buf: [32]u8 = undefined;
                    var total_buf: [32]u8 = undefined;
                    const is_done = std.mem.eql(u8, j.status, "completed");
                    const eff_done = if (is_done and j.total_bytes > 0) j.total_bytes else j.progress_bytes;
                    const bar = formatProgressBar(&bar_buf, eff_done, j.total_bytes);
                    const pct: u64 = if (is_done) 100 else if (j.total_bytes > 0) @min(100, (eff_done * 100) / j.total_bytes) else 0;
                    try printFd(alloc, posix.STDOUT_FILENO, "  #{d:<3} {s:<12} {s:<10} {s} {d:>3}% ({s} / {s})\r\n", .{
                        j.id,
                        j.pipeline,
                        j.status,
                        bar,
                        pct,
                        formatHumanSize(&done_buf, eff_done),
                        formatHumanSize(&total_buf, j.total_bytes),
                    });
                }
            }
        } else {
            try printFd(alloc, posix.STDOUT_FILENO, "\x1b[1;36mVault TUI\x1b[0m | url: {s} | vault: {s} | parent: {s} | jobs: {d}\r\n", .{
                base_url,
                vault_id,
                if (current_parent.len == 0) "/" else current_parent,
                active_jobs,
            });
            try writeFd(posix.STDOUT_FILENO, "--------------------------------------------------------------------------------\r\n");

            if (entries.items.len == 0) {
                try writeFd(posix.STDOUT_FILENO, "  (empty directory or daemon offline)\r\n");
            } else {
                for (entries.items, 0..) |e, idx| {
                    const marker = if (idx == selected) ">" else " ";
                    const is_dir = std.mem.eql(u8, e.kind, "dir") or std.mem.eql(u8, e.kind, "directory");
                    const kind = if (is_dir) "[DIR]" else "     ";
                    var sz_buf: [32]u8 = undefined;
                    const sz_str = formatHumanSize(&sz_buf, e.logical_size);
                    if (idx == selected) {
                        try printFd(alloc, posix.STDOUT_FILENO, "\x1b[7m{s} {s} {s} ({s})\x1b[0m\r\n", .{ marker, kind, e.name, sz_str });
                    } else {
                        try printFd(alloc, posix.STDOUT_FILENO, "{s} {s} {s} ({s})\r\n", .{ marker, kind, e.name, sz_str });
                    }
                }
            }
        }

        try writeFd(posix.STDOUT_FILENO, "--------------------------------------------------------------------------------\r\n");
        try writeFd(posix.STDOUT_FILENO, "\x1b[90mj/k: move | Enter: open | s: stream | t: transfers | n: mkdir | d: del | /: search | u: upload | g: GC | r: refresh | q: quit\x1b[0m\r\n");
        try printFd(alloc, posix.STDOUT_FILENO, "{s}\r\n", .{status_msg});

        var fds = [_]posix.pollfd{.{
            .fd = stdin_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const poll_rc = try posix.poll(&fds, 300);
        if (poll_rc == 0) {
            if (active_jobs > 0 or show_transfers) {
                if (getJobs(alloc, io, base_url)) |jobs_resp| {
                    defer alloc.free(jobs_resp);
                    if (std.json.parseFromSlice(struct {
                        jobs: []const JobSummary = &.{},
                    }, alloc, jobs_resp, .{ .ignore_unknown_fields = true })) |parsed_jobs| {
                        defer parsed_jobs.deinit();
                        for (jobs_list.items) |old| {
                            alloc.free(old.pipeline);
                            alloc.free(old.status);
                        }
                        jobs_list.clearRetainingCapacity();

                        var running_count: usize = 0;
                        for (parsed_jobs.value.jobs) |j| {
                            try jobs_list.append(alloc, .{
                                .id = j.id,
                                .pipeline = try alloc.dupe(u8, j.pipeline),
                                .status = try alloc.dupe(u8, j.status),
                                .progress_bytes = j.progress_bytes,
                                .total_bytes = j.total_bytes,
                            });
                            if (std.mem.eql(u8, j.status, "queued") or std.mem.eql(u8, j.status, "running")) {
                                running_count += 1;
                            }
                        }
                        if (running_count == 0 and active_jobs > 0) {
                            status_msg = "Background job(s) completed";
                            need_refresh = true;
                        }
                        active_jobs = running_count;
                    } else |_| {}
                } else |_| {}
            }
            continue;
        }

        var key_buf: [3]u8 = undefined;
        const n = try posix.read(stdin_fd, &key_buf);
        if (n == 0) break;

        if (key_buf[0] == 'q') {
            break;
        } else if (key_buf[0] == 't') {
            show_transfers = !show_transfers;
            if (show_transfers) {
                if (getJobs(alloc, io, base_url)) |jobs_resp| {
                    defer alloc.free(jobs_resp);
                    if (std.json.parseFromSlice(struct {
                        jobs: []const JobSummary = &.{},
                    }, alloc, jobs_resp, .{ .ignore_unknown_fields = true })) |parsed_jobs| {
                        defer parsed_jobs.deinit();
                        for (jobs_list.items) |old| {
                            alloc.free(old.pipeline);
                            alloc.free(old.status);
                        }
                        jobs_list.clearRetainingCapacity();
                        for (parsed_jobs.value.jobs) |j| {
                            try jobs_list.append(alloc, .{
                                .id = j.id,
                                .pipeline = try alloc.dupe(u8, j.pipeline),
                                .status = try alloc.dupe(u8, j.status),
                                .progress_bytes = j.progress_bytes,
                                .total_bytes = j.total_bytes,
                            });
                        }
                    } else |_| {}
                } else |_| {}
            }
        } else if (key_buf[0] == 'j' or (n == 3 and key_buf[0] == 0x1b and key_buf[1] == '[' and key_buf[2] == 'B')) {
            if (selected + 1 < entries.items.len) selected += 1;
        } else if (key_buf[0] == 'k' or (n == 3 and key_buf[0] == 0x1b and key_buf[1] == '[' and key_buf[2] == 'A')) {
            if (selected > 0) selected -= 1;
        } else if (key_buf[0] == 127 or key_buf[0] == 8) {
            if (search_query) |sq| {
                alloc.free(sq);
                search_query = null;
                selected = 0;
                need_refresh = true;
                status_msg = "Exited search";
            } else if (parent_stack.items.len > 0) {
                alloc.free(parent_stack.pop().?);
                selected = 0;
                need_refresh = true;
            }
        } else if (key_buf[0] == '/') {
            try writeFd(posix.STDOUT_FILENO, "\r\n");
            if (try promptRawLine(alloc, io, stdin_fd, "Search query: ", false, env_map)) |raw_q| {
                defer alloc.free(raw_q);
                const trimmed_q = std.mem.trim(u8, raw_q, " \t\r\n");
                if (search_query) |old| alloc.free(old);
                if (trimmed_q.len > 0) {
                    search_query = try alloc.dupe(u8, trimmed_q);
                    selected = 0;
                    need_refresh = true;
                    status_msg = std.fmt.bufPrint(&status_msg_buf, "Search: '{s}' (Backspace to clear)", .{trimmed_q}) catch "Search active";
                } else {
                    search_query = null;
                    need_refresh = true;
                    status_msg = "Search cleared";
                }
            } else {
                status_msg = "Search cancelled";
            }
        } else if (key_buf[0] == 'n') {
            if (current_parent.len == 0 or search_query != null) {
                status_msg = "Enter a partition/folder first before creating a folder";
                continue;
            }
            try writeFd(posix.STDOUT_FILENO, "\r\n");
            if (try promptRawLine(alloc, io, stdin_fd, "New folder name: ", false, env_map)) |raw_name| {
                defer alloc.free(raw_name);
                const trimmed = std.mem.trim(u8, raw_name, " \t\r\n");
                if (trimmed.len > 0) {
                    const mk_body = try std.fmt.allocPrint(
                        alloc,
                        "{{\"pipeline\":\"mkdir\",\"vault_id\":\"{s}\",\"parent_id\":\"{s}\",\"name\":\"{s}\"}}",
                        .{ vault_id, current_parent, trimmed },
                    );
                    defer alloc.free(mk_body);
                    if (postJob(alloc, io, base_url, mk_body)) |r| {
                        alloc.free(r);
                        need_refresh = true;
                        status_msg = std.fmt.bufPrint(&status_msg_buf, "Created folder '{s}'", .{trimmed}) catch "Folder created";
                    } else |err| {
                        status_msg = std.fmt.bufPrint(&status_msg_buf, "mkdir error: {s}", .{if (last_error_detail.len > 0) last_error_detail else @errorName(err)}) catch "mkdir failed";
                    }
                } else {
                    status_msg = "mkdir cancelled";
                }
            } else {
                status_msg = "mkdir cancelled";
            }
        } else if (key_buf[0] == 'd') {
            if (entries.items.len == 0) continue;
            if (current_parent.len == 0 and search_query == null) {
                status_msg = "Cannot delete root partition folders";
                continue;
            }
            const item = entries.items[selected];
            try writeFd(posix.STDOUT_FILENO, "\r\n");
            const prompt_lbl = try std.fmt.allocPrint(alloc, "Delete '{s}'? (y/N): ", .{item.name});
            defer alloc.free(prompt_lbl);
            if (try promptRawLine(alloc, io, stdin_fd, prompt_lbl, false, env_map)) |ans| {
                defer alloc.free(ans);
                const trimmed_ans = std.mem.trim(u8, ans, " \t\r\n");
                if (std.ascii.eqlIgnoreCase(trimmed_ans, "y") or std.ascii.eqlIgnoreCase(trimmed_ans, "yes")) {
                    const del_body = try std.fmt.allocPrint(
                        alloc,
                        "{{\"pipeline\":\"delete\",\"vault_id\":\"{s}\",\"inode_id\":\"{s}\"}}",
                        .{ vault_id, item.inode_id },
                    );
                    defer alloc.free(del_body);
                    if (postJob(alloc, io, base_url, del_body)) |r| {
                        alloc.free(r);
                        need_refresh = true;
                        status_msg = std.fmt.bufPrint(&status_msg_buf, "Deleted '{s}'", .{item.name}) catch "Deleted";
                    } else |err| {
                        status_msg = std.fmt.bufPrint(&status_msg_buf, "Delete error: {s}", .{if (last_error_detail.len > 0) last_error_detail else @errorName(err)}) catch "Delete failed";
                    }
                } else {
                    status_msg = "Delete cancelled";
                }
            } else {
                status_msg = "Delete cancelled";
            }
        } else if (key_buf[0] == 'g') {
            const gc_body = try std.fmt.allocPrint(alloc, "{{\"pipeline\":\"gc\",\"async\":true,\"vault_id\":\"{s}\"}}", .{vault_id});
            defer alloc.free(gc_body);
            if (postJob(alloc, io, base_url, gc_body)) |r| {
                alloc.free(r);
                active_jobs += 1;
                status_msg = "GC queued in background...";
            } else |err| {
                status_msg = @errorName(err);
            }
        } else if (key_buf[0] == 'u') {
            if (current_parent.len == 0 or search_query != null) {
                status_msg = "Enter a partition/folder first before uploading (press Enter on a [DIR])";
                continue;
            }
            try writeFd(posix.STDOUT_FILENO, "\r\n");
            if (try promptRawLine(alloc, io, stdin_fd, "Upload path (Tab to complete): ", true, env_map)) |raw_path| {
                defer alloc.free(raw_path);
                const input_trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
                if (input_trimmed.len > 0) {
                    const expanded_path = try expandPathVars(alloc, input_trimmed, env_map);
                    defer alloc.free(expanded_path);
                    const fname = std.fs.path.basename(expanded_path);
                    const up_body = try std.fmt.allocPrint(
                        alloc,
                        "{{\"pipeline\":\"upload\",\"async\":true,\"vault_id\":\"{s}\",\"parent_id\":\"{s}\",\"name\":\"{s}\",\"source_path\":\"{s}\"}}",
                        .{ vault_id, current_parent, fname, expanded_path },
                    );
                    defer alloc.free(up_body);
                    if (postJob(alloc, io, base_url, up_body)) |r| {
                        alloc.free(r);
                        active_jobs += 1;
                        status_msg = std.fmt.bufPrint(&status_msg_buf, "Queued upload '{s}'", .{fname}) catch "Upload queued";
                    } else |err| {
                        status_msg = std.fmt.bufPrint(&status_msg_buf, "Upload error: {s}", .{if (last_error_detail.len > 0) last_error_detail else @errorName(err)}) catch "Upload failed";
                    }
                } else {
                    status_msg = "Upload cancelled";
                }
            } else {
                status_msg = "Upload cancelled";
            }
        } else if (key_buf[0] == 'r') {
            const ref_body = try std.fmt.allocPrint(alloc, "{{\"pipeline\":\"refresh\",\"vault_id\":\"{s}\"}}", .{vault_id});
            defer alloc.free(ref_body);
            if (postJob(alloc, io, base_url, ref_body)) |r| {
                alloc.free(r);
                need_refresh = true;
                status_msg = "Refreshed from remote";
            } else |err| {
                need_refresh = true;
                status_msg = @errorName(err);
            }
        } else if (key_buf[0] == 's') {
            if (entries.items.len > 0) {
                const item = entries.items[selected];
                const is_dir = std.mem.eql(u8, item.kind, "dir") or std.mem.eql(u8, item.kind, "directory");
                if (!is_dir) {
                    const stream_url = try std.fmt.allocPrint(alloc, "{s}/stream/{s}/{s}", .{ base_url, item.inode_id, item.name });
                    defer alloc.free(stream_url);
                    if (has_gui) {
                        if (isMediaFile(item.name)) {
                            if (!spawnDetached(io, &.{ "mpv", stream_url })) {
                                if (!spawnDetached(io, &.{ "vlc", stream_url })) {
                                    _ = spawnDetached(io, &.{ "xdg-open", stream_url });
                                }
                            }
                        } else {
                            _ = spawnDetached(io, &.{ "xdg-open", stream_url });
                        }
                    }
                    status_msg = std.fmt.bufPrint(&status_msg_buf, "Streaming: {s}", .{item.name}) catch "Streaming";
                }
            }
        } else if (key_buf[0] == '\r' or key_buf[0] == '\n') {
            if (entries.items.len > 0) {
                const item = entries.items[selected];
                const is_dir = std.mem.eql(u8, item.kind, "dir") or std.mem.eql(u8, item.kind, "directory");
                if (is_dir) {
                    try parent_stack.append(alloc, try alloc.dupe(u8, item.inode_id));
                    selected = 0;
                    need_refresh = true;
                } else {
                    status_msg = "Opening file...";
                    status_msg = openInodeInViewer(alloc, io, base_url, vault_id, item.inode_id, item.name, stdin_fd, orig_termios, raw, has_gui) catch |err|
                        std.fmt.bufPrint(&status_msg_buf, "Open failed: {s}", .{@errorName(err)}) catch "Open failed";
                }
            }
        }
    }
    try writeFd(posix.STDOUT_FILENO, "\x1b[2J\x1b[H");
}

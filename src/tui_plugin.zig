const std = @import("std");
const sdk = @import("parabellum_sdk");
const tui = @import("tui_inbound");

const abi = sdk.abi;
const inbound = sdk.transport.inbound;

var transport_ctx_marker: u8 = 0;
var global_event_ring = tui.EventRing{};
var global_catalog_parsed: ?std.json.Parsed(sdk.capabilities.CapabilityCatalog) = null;
var global_kernel: ?*abi.extension.KernelHandle_ABI = null;
var global_api: ?*const abi.KernelApiVTable_ABI = null;

fn onTelemetryEvent(_: *abi.extension.SubscriberCtx_ABI, ev: *const abi.TelemetryEvent_ABI) callconv(.c) void {
    global_event_ring.pushAbiEvent(ev);
}

const telemetry_sub_vtable = abi.TelemetrySubscriberVTable_ABI{
    .on_event = onTelemetryEvent,
};

const Entry = struct {
    inode_id: []u8,
    name: []u8,
    is_dir: bool,
    logical_size: u64,

    fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.inode_id);
        alloc.free(self.name);
    }
};

const MenuAction = enum {
    upload,
    mkdir,
    preview,
    open_external,
    stream_play,
    view_hex,
    delete_node,
    refresh_dir,

    fn label(self: MenuAction) []const u8 {
        return switch (self) {
            .upload => "Upload File Here",
            .mkdir => "Create Subdirectory",
            .preview => "Preview in Output",
            .open_external => "Download & Open (xdg-open)",
            .stream_play => "Stream to Handler",
            .view_hex => "View Hex",
            .delete_node => "Delete",
            .refresh_dir => "Refresh Directory",
        };
    }
};

const VaultExplorer = struct {
    alloc: std.mem.Allocator,
    app: ?*tui.TuiApp = null,
    viewer: ?*VaultHexViewer = null,
    entries: std.ArrayList(Entry) = .empty,
    selected: usize = 0,
    current_parent_id: []u8 = &.{},
    history: std.ArrayList([]u8) = .empty,
    menu_open: bool = false,
    menu_items: [8]MenuAction = undefined,
    menu_count: usize = 0,
    menu_selected: usize = 0,

    fn init(alloc: std.mem.Allocator) VaultExplorer {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *VaultExplorer) void {
        for (self.entries.items) |*e| e.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        if (self.current_parent_id.len > 0) self.alloc.free(self.current_parent_id);
        for (self.history.items) |h| self.alloc.free(h);
        self.history.deinit(self.alloc);
    }

    fn clearEntries(self: *VaultExplorer) void {
        for (self.entries.items) |*e| e.deinit(self.alloc);
        self.entries.clearRetainingCapacity();
        self.selected = 0;
    }

    fn loadDir(self: *VaultExplorer, parent_id: []const u8, dispatcher: inbound.HostDispatcher) void {
        const owned_parent: []u8 = if (parent_id.len > 0)
            (self.alloc.dupe(u8, parent_id) catch return)
        else
            &.{};
        defer if (owned_parent.len > 0) self.alloc.free(owned_parent);

        var pbuf: [256]u8 = undefined;
        const payload = std.fmt.bufPrint(&pbuf, "{{\"parent_id\":\"{s}\"}}", .{owned_parent}) catch "{\"parent_id\":\"\"}";

        const resp = dispatcher.dispatch(.{
            .command_or_route = "ls",
            .payload = payload,
            .args_json = "{\"custom\":true,\"input\":\"job_json\"}",
        }) catch |err| {
            if (self.app) |a| a.setStatusFmt("Explorer ls failed: {s}", .{@errorName(err)});
            return;
        };
        if (resp.status_code < 200 or resp.status_code >= 300) {
            if (self.app) |a| a.setStatusFmt("Explorer ls -> HTTP {d}", .{resp.status_code});
            return;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, resp.body, .{}) catch return;
        defer parsed.deinit();

        const arr: []const std.json.Value = switch (parsed.value) {
            .array => |a| a.items,
            .object => |obj| blk: {
                if (obj.get("data_json")) |dj| {
                    if (dj == .string) {
                        const inner = std.json.parseFromSlice(std.json.Value, self.alloc, dj.string, .{}) catch return;
                        defer inner.deinit();
                        if (inner.value == .array) {
                            self.populateEntries(inner.value.array.items, owned_parent);
                        }
                        return;
                    }
                }
                break :blk &.{};
            },
            else => &.{},
        };
        self.populateEntries(arr, owned_parent);
    }

    fn populateEntries(self: *VaultExplorer, items: []const std.json.Value, parent_id: []const u8) void {
        const new_parent: []u8 = if (parent_id.len > 0)
            (self.alloc.dupe(u8, parent_id) catch &.{})
        else
            &.{};
        self.clearEntries();
        if (self.current_parent_id.len > 0) self.alloc.free(self.current_parent_id);
        self.current_parent_id = new_parent;

        for (items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const id_v = obj.get("inode_id") orelse continue;
            const name_v = obj.get("name") orelse continue;
            if (id_v != .string or name_v != .string) continue;
            const kind_str = if (obj.get("kind")) |kv| (if (kv == .string) kv.string else "file") else "file";
            const sz: u64 = if (obj.get("logical_size")) |sv| switch (sv) {
                .integer => |n| @intCast(@max(0, n)),
                else => 0,
            } else 0;

            self.entries.append(self.alloc, .{
                .inode_id = self.alloc.dupe(u8, id_v.string) catch continue,
                .name = self.alloc.dupe(u8, name_v.string) catch continue,
                .is_dir = std.mem.eql(u8, kind_str, "dir"),
                .logical_size = sz,
            }) catch continue;
        }
        if (self.app) |a| a.setStatusFmt("Explorer: {d} entries", .{self.entries.items.len});
    }

    fn onStart(ctx: ?*anyopaque, app: *tui.TuiApp, dispatcher: inbound.HostDispatcher) void {
        const self: *VaultExplorer = @ptrCast(@alignCast(ctx.?));
        self.app = app;
        self.loadDir("", dispatcher);
        app.focusPanelById("explorer");
    }

    fn openMenu(self: *VaultExplorer) void {
        var n: usize = 0;
        if (self.selected < self.entries.items.len) {
            const e = self.entries.items[self.selected];
            if (e.is_dir) {
                self.menu_items[n] = .upload;
                n += 1;
                self.menu_items[n] = .mkdir;
                n += 1;
                self.menu_items[n] = .delete_node;
                n += 1;
            } else {
                self.menu_items[n] = .preview;
                n += 1;
                self.menu_items[n] = .open_external;
                n += 1;
                self.menu_items[n] = .stream_play;
                n += 1;
                self.menu_items[n] = .view_hex;
                n += 1;
                self.menu_items[n] = .delete_node;
                n += 1;
            }
        } else {
            self.menu_items[n] = .upload;
            n += 1;
            self.menu_items[n] = .mkdir;
            n += 1;
        }
        self.menu_items[n] = .refresh_dir;
        n += 1;
        self.menu_count = n;
        self.menu_selected = 0;
        self.menu_open = true;
    }

    fn executeMenuAction(self: *VaultExplorer, act: MenuAction, dispatcher: inbound.HostDispatcher) !void {
        const app = self.app orelse return;
        const sel_opt: ?Entry = if (self.selected < self.entries.items.len) self.entries.items[self.selected] else null;
        const target_dir_id: []const u8 = if (sel_opt) |e|
            (if (e.is_dir) e.inode_id else self.current_parent_id)
        else
            self.current_parent_id;

        switch (act) {
            .upload => try app.openCapabilityForm("upload", &.{.{ .name = "parent_id", .value = target_dir_id }}),
            .mkdir => try app.openCapabilityForm("mkdir", &.{.{ .name = "parent_id", .value = target_dir_id }}),
            .preview => if (sel_opt) |e| {
                var pbuf: [256]u8 = undefined;
                const payload = std.fmt.bufPrint(&pbuf, "{{\"inode_id\":\"{s}\"}}", .{e.inode_id}) catch return;
                try app.dispatchCapabilityToOutput("preview", payload, dispatcher);
            },
            .open_external => if (sel_opt) |e| {
                var pbuf: [256]u8 = undefined;
                const payload = std.fmt.bufPrint(&pbuf, "{{\"inode_id\":\"{s}\"}}", .{e.inode_id}) catch return;
                try app.dispatchCapabilityToOutput("open", payload, dispatcher);
            },
            .stream_play => if (sel_opt) |e| {
                var pbuf: [256]u8 = undefined;
                const payload = std.fmt.bufPrint(&pbuf, "{{\"inode_id\":\"{s}\"}}", .{e.inode_id}) catch return;
                try app.dispatchCapabilityToOutput("stream_play", payload, dispatcher);
            },
            .view_hex => if (sel_opt) |e| {
                if (self.viewer) |v| v.openFile(e.inode_id, e.name, dispatcher);
            },
            .delete_node => if (sel_opt) |e| {
                var pbuf: [256]u8 = undefined;
                const payload = std.fmt.bufPrint(&pbuf, "{{\"inode_id\":\"{s}\"}}", .{e.inode_id}) catch return;
                try app.dispatchCapabilityToOutput("delete", payload, dispatcher);
                self.loadDir(self.current_parent_id, dispatcher);
            },
            .refresh_dir => self.loadDir(self.current_parent_id, dispatcher),
        }
    }

    fn render(ctx: ?*anyopaque, surface: tui.PanelSurface, focused: bool) void {
        const self: *const VaultExplorer = @ptrCast(@alignCast(ctx.?));
        if (surface.width < 2 or surface.height < 1) return;

        if (self.menu_open) {
            surface.drawText(0, 0, surface.width, "Actions (Enter:Run, Esc:Close)", .{ .fg = .yellow, .bold = true });
            var r: u16 = 1;
            while (r < surface.height and r - 1 < self.menu_count) : (r += 1) {
                const idx = r - 1;
                const sel = idx == self.menu_selected;
                const st = tui.Style{
                    .fg = if (sel) .black else .white,
                    .bg = if (sel) .cyan else .default,
                    .bold = sel,
                };
                if (sel) surface.fillRect(0, r, surface.width, 1, ' ', st);
                surface.drawText(0, r, surface.width, self.menu_items[idx].label(), st);
            }
            return;
        }

        if (self.entries.items.len == 0) {
            surface.drawText(0, 0, surface.width, "(empty - press 'a' for actions)", .{ .dim = true });
            return;
        }

        const h: usize = surface.height;
        const start: usize = if (self.selected >= h) self.selected - h + 1 else 0;
        var r: u16 = 0;
        while (r < surface.height and start + r < self.entries.items.len) : (r += 1) {
            const idx = start + r;
            const e = self.entries.items[idx];
            const sel = focused and idx == self.selected;
            const st = tui.Style{
                .fg = if (sel) .black else if (e.is_dir) .bright_cyan else .white,
                .bg = if (sel) .cyan else .default,
                .bold = sel or e.is_dir,
            };
            if (sel) surface.fillRect(0, r, surface.width, 1, ' ', st);

            var lbuf: [128]u8 = undefined;
            const line = if (e.is_dir)
                std.fmt.bufPrint(&lbuf, "▸ {s}/", .{e.name}) catch e.name
            else blk: {
                var hbuf: [24]u8 = undefined;
                const hsz = formatSize(&hbuf, e.logical_size);
                break :blk std.fmt.bufPrint(&lbuf, "  {s} ({s})", .{ e.name, hsz }) catch e.name;
            };
            surface.drawText(0, r, surface.width, line, st);
        }
    }

    fn handleKey(ctx: ?*anyopaque, key: tui.Key, dispatcher: inbound.HostDispatcher) anyerror!bool {
        const self: *VaultExplorer = @ptrCast(@alignCast(ctx.?));
        if (self.menu_open) {
            switch (key) {
                .escape => self.menu_open = false,
                .up => if (self.menu_selected > 0) {
                    self.menu_selected -= 1;
                },
                .down => if (self.menu_selected + 1 < self.menu_count) {
                    self.menu_selected += 1;
                },
                .enter => {
                    self.menu_open = false;
                    if (self.menu_selected < self.menu_count) {
                        try self.executeMenuAction(self.menu_items[self.menu_selected], dispatcher);
                    }
                },
                else => {},
            }
            return true;
        }

        switch (key) {
            .up => {
                if (self.selected > 0) self.selected -= 1;
                return true;
            },
            .down => {
                if (self.selected + 1 < self.entries.items.len) self.selected += 1;
                return true;
            },
            .enter, .right => {
                if (self.selected < self.entries.items.len) {
                    const e = self.entries.items[self.selected];
                    if (e.is_dir) {
                        const prev = try self.alloc.dupe(u8, self.current_parent_id);
                        try self.history.append(self.alloc, prev);
                        self.loadDir(e.inode_id, dispatcher);
                    } else if (self.app) |app| {
                        var pbuf: [256]u8 = undefined;
                        const payload = std.fmt.bufPrint(&pbuf, "{{\"inode_id\":\"{s}\"}}", .{e.inode_id}) catch return true;
                        try app.dispatchCapabilityToOutput("preview", payload, dispatcher);
                    }
                }
                return true;
            },
            .backspace, .left => {
                if (self.history.items.len > 0) {
                    const prev = self.history.pop().?;
                    defer self.alloc.free(prev);
                    self.loadDir(prev, dispatcher);
                }
                return true;
            },
            .char => |cp| {
                if (cp == 'b') {
                    if (self.history.items.len > 0) {
                        const prev = self.history.pop().?;
                        defer self.alloc.free(prev);
                        self.loadDir(prev, dispatcher);
                    }
                    return true;
                } else if (cp == 'r') {
                    self.loadDir(self.current_parent_id, dispatcher);
                    return true;
                } else if (cp == 'a') {
                    self.openMenu();
                    return true;
                }
            },
            else => {},
        }
        return false;
    }
};

const VaultQuotaPanel = struct {
    alloc: std.mem.Allocator,
    app: ?*tui.TuiApp = null,
    total_bytes: u64 = 0,
    used_bytes: u64 = 0,
    available_bytes: u64 = 0,
    node_count: u64 = 0,
    history: [24]u8 = @splat(0),
    history_len: usize = 0,
    tick_counter: usize = 0,
    has_data: bool = false,

    fn refresh(self: *VaultQuotaPanel, dispatcher: inbound.HostDispatcher) void {
        const resp = dispatcher.dispatch(.{
            .command_or_route = "quotas",
            .payload = "{}",
            .args_json = "{\"custom\":true,\"input\":\"job_json\"}",
        }) catch return;
        if (resp.status_code < 200 or resp.status_code >= 300) return;

        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, resp.body, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;

        var obj = parsed.value.object;
        if (obj.get("data_json")) |dj| {
            if (dj == .string) {
                const inner = std.json.parseFromSlice(std.json.Value, self.alloc, dj.string, .{}) catch return;
                defer inner.deinit();
                if (inner.value == .object) {
                    self.updateFromObject(inner.value.object);
                }
                return;
            }
        }
        self.updateFromObject(obj);
    }

    fn updateFromObject(self: *VaultQuotaPanel, obj: std.json.ObjectMap) void {
        self.total_bytes = jsonU64(obj.get("total_bytes"));
        self.used_bytes = jsonU64(obj.get("used_bytes"));
        self.available_bytes = jsonU64(obj.get("available_bytes"));
        self.node_count = jsonU64(obj.get("node_count"));
        self.has_data = true;

        const pct: u8 = if (self.total_bytes > 0)
            @intCast(@min(100, (@as(u128, self.used_bytes) * 100) / self.total_bytes))
        else
            0;

        if (self.history_len < self.history.len) {
            self.history[self.history_len] = pct;
            self.history_len += 1;
        } else {
            for (0..self.history.len - 1) |i| {
                self.history[i] = self.history[i + 1];
            }
            self.history[self.history.len - 1] = pct;
        }

        // Hide quota panel automatically if there is no remote quota (local VFS)
        if (self.app) |app| {
            for (app.panels.items) |*p| {
                if (std.mem.eql(u8, p.id, "quota")) {
                    p.visible = self.total_bytes > 0;
                    break;
                }
            }
        }
    }

    fn jsonU64(val_opt: ?std.json.Value) u64 {
        const val = val_opt orelse return 0;
        return switch (val) {
            .integer => |n| @intCast(@max(0, n)),
            else => 0,
        };
    }

    fn onTick(self: *VaultQuotaPanel, dispatcher: inbound.HostDispatcher) void {
        self.tick_counter += 1;
        if (self.tick_counter >= 50) { // ~5s at 100ms poll
            self.tick_counter = 0;
            self.refresh(dispatcher);
        }
    }

    fn render(ctx: ?*anyopaque, surface: tui.PanelSurface, _: bool) void {
        const self: *const VaultQuotaPanel = @ptrCast(@alignCast(ctx.?));
        if (surface.width < 10 or surface.height < 4) return;

        if (!self.has_data) {
            surface.drawText(0, 0, surface.width, "Loading quota...", .{ .dim = true });
            return;
        }
        if (self.total_bytes == 0) {
            surface.drawText(0, 0, surface.width, "Local VFS (no remote quota)", .{ .dim = true });
            return;
        }

        const pct_x10: u64 = @intCast((@as(u128, self.used_bytes) * 1000) / self.total_bytes);
        const pct_int = pct_x10 / 10;
        const pct_dec = pct_x10 % 10;

        // Row 0: Percentage + bar
        const bar_w: usize = @min(18, surface.width -| 9);
        const filled: usize = @intCast(@min(bar_w, (@as(u128, self.used_bytes) * bar_w) / self.total_bytes));
        var bar_buf: [64]u8 = undefined;
        var bi: usize = 0;
        bar_buf[bi] = '[';
        bi += 1;
        for (0..bar_w) |i| {
            bar_buf[bi] = if (i < filled) '#' else '-';
            bi += 1;
        }
        const tail = std.fmt.bufPrint(bar_buf[bi..], "] {d}.{d}%", .{ pct_int, pct_dec }) catch "]";
        const bar_color: tui.Color = if (pct_int >= 90) .red else if (pct_int >= 75) .yellow else .bright_green;
        surface.drawText(0, 0, surface.width, bar_buf[0 .. bi + tail.len], .{ .fg = bar_color, .bold = true });

        // Row 2-4: Used / Free / Nodes
        var ubuf: [24]u8 = undefined;
        var tbuf: [24]u8 = undefined;
        var abuf: [24]u8 = undefined;
        var line1: [64]u8 = undefined;
        const l1 = std.fmt.bufPrint(&line1, "Used : {s} / {s}", .{
            formatSize(&ubuf, self.used_bytes),
            formatSize(&tbuf, self.total_bytes),
        }) catch "";
        surface.drawText(0, 2, surface.width, l1, .{ .fg = .white });

        if (surface.height >= 4) {
            var line2: [64]u8 = undefined;
            const l2 = std.fmt.bufPrint(&line2, "Free : {s}", .{
                formatSize(&abuf, self.available_bytes),
            }) catch "";
            surface.drawText(0, 3, surface.width, l2, .{ .fg = .cyan });
        }

        if (surface.height >= 5) {
            var line3: [64]u8 = undefined;
            const l3 = std.fmt.bufPrint(&line3, "Nodes: {d}", .{self.node_count}) catch "";
            surface.drawText(0, 4, surface.width, l3, .{ .fg = .bright_black });
        }

        // Real-time sparkline graph
        if (surface.height >= 7 and self.history_len > 0) {
            surface.drawText(0, 5, surface.width, "Trend (0-100% / 5s):", .{ .fg = .yellow, .bold = true });
            const blocks = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
            var gx: u16 = 0;
            for (0..self.history_len) |i| {
                if (gx >= surface.width) break;
                const p: usize = self.history[i];
                const lvl: usize = @min(7, (p * 7) / 100);
                surface.drawText(gx, 6, 1, blocks[lvl], .{ .fg = bar_color });
                gx += 1;
            }
        }
    }

    fn handleKey(ctx: ?*anyopaque, key: tui.Key, dispatcher: inbound.HostDispatcher) anyerror!bool {
        const self: *VaultQuotaPanel = @ptrCast(@alignCast(ctx.?));
        switch (key) {
            .char => |cp| {
                if (cp == 'r') {
                    self.refresh(dispatcher);
                    return true;
                }
            },
            else => {},
        }
        return false;
    }
};

const VaultHexViewer = struct {
    const CHUNK_SIZE: usize = 8192;

    alloc: std.mem.Allocator,
    app: ?*tui.TuiApp = null,
    inode_id: [128]u8 = undefined,
    inode_id_len: usize = 0,
    file_name: [128]u8 = undefined,
    file_name_len: usize = 0,
    mime_type: [64]u8 = undefined,
    mime_type_len: usize = 0,
    total_size: u64 = 0,
    top_offset: u64 = 0,
    cache_start: u64 = 0,
    cache_len: usize = 0,
    last_bpr: usize = 16,
    last_vis_rows: usize = 24,
    needs_fetch: bool = false,
    cache_buf: [CHUNK_SIZE]u8 = undefined,

    fn bytesPerRow(width: u16) usize {
        const max_b: usize = (width -| 13) / 4;
        const aligned = (max_b / 4) * 4;
        return @max(4, @min(64, aligned));
    }

    fn openFile(self: *VaultHexViewer, inode_id: []const u8, name: []const u8, dispatcher: inbound.HostDispatcher) void {
        const id_len = @min(inode_id.len, self.inode_id.len);
        @memcpy(self.inode_id[0..id_len], inode_id[0..id_len]);
        self.inode_id_len = id_len;

        const n_len = @min(name.len, self.file_name.len);
        @memcpy(self.file_name[0..n_len], name[0..n_len]);
        self.file_name_len = n_len;

        self.mime_type_len = 0;
        self.total_size = 0;
        self.top_offset = 0;
        self.cache_start = 0;
        self.cache_len = 0;

        self.fetchChunk(0, dispatcher);
        if (self.app) |app| {
            app.setPanelVisible("output", false);
            app.setPanelVisible("hex_viewer", true);
            app.focusPanelById("hex_viewer");
        }
    }

    fn fetchChunk(self: *VaultHexViewer, chunk_start: u64, dispatcher: inbound.HostDispatcher) void {
        if (self.inode_id_len == 0) return;
        var pbuf: [320]u8 = undefined;
        const payload = std.fmt.bufPrint(
            &pbuf,
            "{{\"inode_id\":\"{s}\",\"offset\":{d},\"max_len\":{d},\"encoding\":\"base64\"}}",
            .{ self.inode_id[0..self.inode_id_len], chunk_start, CHUNK_SIZE },
        ) catch return;

        const resp = dispatcher.dispatch(.{
            .command_or_route = "read",
            .payload = payload,
            .args_json = "{\"custom\":true,\"input\":\"job_json\"}",
        }) catch |err| {
            if (self.app) |a| a.setStatusFmt("Read range failed: {s}", .{@errorName(err)});
            return;
        };
        if (resp.status_code < 200 or resp.status_code >= 300) {
            if (self.app) |a| a.setStatusFmt("Read range -> HTTP {d}", .{resp.status_code});
            return;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, resp.body, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        if (obj.get("total_size")) |ts| {
            if (ts == .integer and ts.integer >= 0) self.total_size = @intCast(ts.integer);
        }
        if (obj.get("mime_type")) |mt| {
            if (mt == .string) {
                const ml = @min(mt.string.len, self.mime_type.len);
                @memcpy(self.mime_type[0..ml], mt.string[0..ml]);
                self.mime_type_len = ml;
            }
        }
        if (obj.get("data")) |dv| {
            if (dv == .string) {
                const exact = std.base64.standard.Decoder.calcSizeForSlice(dv.string) catch 0;
                if (exact > 0 and exact <= CHUNK_SIZE) {
                    std.base64.standard.Decoder.decode(self.cache_buf[0..exact], dv.string) catch {
                        self.cache_len = 0;
                        return;
                    };
                    self.cache_start = chunk_start;
                    self.cache_len = exact;
                }
            }
        }
    }

    fn ensureOffsetLoaded(self: *VaultHexViewer, off: u64, dispatcher: inbound.HostDispatcher) void {
        if (self.total_size == 0) return;
        const vis_bytes: u64 = @as(u64, @max(1, self.last_vis_rows)) * @as(u64, @max(16, self.last_bpr));
        const margin: u64 = @min(CHUNK_SIZE - 512, vis_bytes + 512);
        const cache_end = self.cache_start + self.cache_len;
        const need_fetch = (self.cache_len == 0) or
            (off < self.cache_start) or
            (off + margin > cache_end and cache_end < self.total_size);
        if (need_fetch) {
            const bpr_mask: u64 = @as(u64, @max(1, self.last_bpr)) - 1;
            const win_start = if (self.last_bpr != 0 and (self.last_bpr & bpr_mask) == 0)
                (off -| 512) & ~bpr_mask
            else
                ((off -| 512) / @as(u64, @max(1, self.last_bpr))) * @as(u64, @max(1, self.last_bpr));
            self.fetchChunk(win_start, dispatcher);
            self.needs_fetch = false;
        }
    }

    fn onTick(self: *VaultHexViewer, dispatcher: inbound.HostDispatcher) void {
        if (self.needs_fetch) {
            self.needs_fetch = false;
            self.ensureOffsetLoaded(self.top_offset, dispatcher);
        }
    }

    fn close(self: *VaultHexViewer) void {
        if (self.app) |app| {
            app.setPanelVisible("hex_viewer", false);
            app.setPanelVisible("output", true);
            app.focusPanelById("explorer");
        }
    }

    fn render(ctx: ?*anyopaque, surface: tui.PanelSurface, _: bool) void {
        const self: *VaultHexViewer = @ptrCast(@alignCast(ctx.?));
        if (surface.height == 0 or surface.width == 0) return;

        const bpr = bytesPerRow(surface.width);
        const vis_rows: usize = surface.height -| 2;
        if (bpr != self.last_bpr or vis_rows != self.last_vis_rows) {
            self.last_bpr = bpr;
            self.last_vis_rows = vis_rows;
            self.top_offset = (self.top_offset / bpr) * bpr;
        }

        var sbuf: [24]u8 = undefined;
        const sz_str = formatSize(&sbuf, self.total_size);
        const mime = if (self.mime_type_len > 0) self.mime_type[0..self.mime_type_len] else "application/octet-stream";
        const fname = if (self.file_name_len > 0) self.file_name[0..self.file_name_len] else "(no file)";
        const pct: u64 = if (self.total_size > 0) @min(100, (self.top_offset * 100) / self.total_size) else 0;

        var hbuf: [192]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hbuf, "{s} | {s} | {s} | 0x{x:0>8} ({d}%) | {d}B/row", .{ fname, mime, sz_str, self.top_offset, pct, bpr }) catch fname;
        surface.drawText(0, 0, surface.width, hdr, .{ .fg = .bright_cyan, .bold = true });

        if (surface.height >= 2) {
            surface.drawText(0, 1, surface.width, "Scroll: Up/Dn/PgUp/PgDn/Home/End | Esc/q: Back to Explorer (8KB lazy window)", .{ .fg = .yellow });
        }

        if (self.total_size == 0) {
            if (surface.height >= 4) surface.drawText(0, 3, surface.width, "(empty file)", .{ .dim = true });
            return;
        }

        const vis_end = @min(self.total_size, self.top_offset + @as(u64, vis_rows) * @as(u64, bpr));
        const cache_end = self.cache_start + self.cache_len;
        if (self.cache_len == 0 or self.top_offset < self.cache_start or vis_end > cache_end) {
            self.needs_fetch = true;
        }

        var r: u16 = 2;
        while (r < surface.height) : (r += 1) {
            const row_off = self.top_offset + @as(u64, r - 2) * @as(u64, bpr);
            if (row_off >= self.total_size) break;

            var line: [320]u8 = undefined;
            var pos: usize = 0;
            const addr = std.fmt.bufPrint(line[pos..], "{x:0>8}: ", .{row_off}) catch break;
            pos += addr.len;

            const row_end = @min(self.total_size, row_off + bpr);
            const row_bytes: usize = @intCast(row_end - row_off);

            var i: usize = 0;
            while (i < bpr) : (i += 1) {
                if (i < row_bytes and row_off + i >= self.cache_start and row_off + i < cache_end) {
                    const b = self.cache_buf[@intCast((row_off + i) - self.cache_start)];
                    const hx = std.fmt.bufPrint(line[pos..], "{x:0>2} ", .{b}) catch break;
                    pos += hx.len;
                } else {
                    if (pos + 3 <= line.len) {
                        @memcpy(line[pos .. pos + 3], "   ");
                        pos += 3;
                    }
                }
            }
            if (pos + 2 <= line.len) {
                @memcpy(line[pos .. pos + 2], " |");
                pos += 2;
            }
            i = 0;
            while (i < row_bytes) : (i += 1) {
                if (pos >= line.len - 1) break;
                if (row_off + i >= self.cache_start and row_off + i < cache_end) {
                    const b = self.cache_buf[@intCast((row_off + i) - self.cache_start)];
                    line[pos] = if (b >= 32 and b < 127) b else '.';
                } else {
                    line[pos] = '?';
                }
                pos += 1;
            }
            if (pos < line.len) {
                line[pos] = '|';
                pos += 1;
            }
            surface.drawText(0, r, surface.width, line[0..pos], .{ .fg = .white });
        }
    }

    fn handleKey(ctx: ?*anyopaque, key: tui.Key, dispatcher: inbound.HostDispatcher) anyerror!bool {
        const self: *VaultHexViewer = @ptrCast(@alignCast(ctx.?));
        const bpr: u64 = @max(1, self.last_bpr);
        const page_bytes: u64 = bpr * @max(1, self.last_vis_rows);
        const max_off: u64 = if (self.total_size > 0) ((self.total_size - 1) / bpr) * bpr else 0;
        const end_off: u64 = if (self.total_size > page_bytes) ((self.total_size - page_bytes) / bpr) * bpr else 0;
        switch (key) {
            .escape => {
                self.close();
                return true;
            },
            .up => {
                self.top_offset -|= bpr;
                self.ensureOffsetLoaded(self.top_offset, dispatcher);
                return true;
            },
            .down => {
                if (self.top_offset + bpr <= max_off) {
                    self.top_offset += bpr;
                    self.ensureOffsetLoaded(self.top_offset, dispatcher);
                }
                return true;
            },
            .page_up => {
                self.top_offset -|= page_bytes;
                self.ensureOffsetLoaded(self.top_offset, dispatcher);
                return true;
            },
            .page_down => {
                self.top_offset = @min(max_off, self.top_offset + page_bytes);
                self.ensureOffsetLoaded(self.top_offset, dispatcher);
                return true;
            },
            .home => {
                self.top_offset = 0;
                self.ensureOffsetLoaded(self.top_offset, dispatcher);
                return true;
            },
            .end => {
                self.top_offset = end_off;
                self.ensureOffsetLoaded(self.top_offset, dispatcher);
                return true;
            },
            .char => |cp| {
                if (cp == 'q') {
                    self.close();
                    return true;
                } else if (cp == 'g') {
                    self.top_offset = 0;
                    self.ensureOffsetLoaded(self.top_offset, dispatcher);
                    return true;
                } else if (cp == 'G') {
                    self.top_offset = end_off;
                    self.ensureOffsetLoaded(self.top_offset, dispatcher);
                    return true;
                }
            },
            else => {},
        }
        return false;
    }
};

const VaultAppCtx = struct {
    explorer: *VaultExplorer,
    quota: *VaultQuotaPanel,
    viewer: *VaultHexViewer,

    fn onStart(ctx: ?*anyopaque, app: *tui.TuiApp, dispatcher: inbound.HostDispatcher) void {
        const self: *VaultAppCtx = @ptrCast(@alignCast(ctx.?));
        self.explorer.app = app;
        self.explorer.viewer = self.viewer;
        self.quota.app = app;
        self.viewer.app = app;
        self.explorer.loadDir("", dispatcher);
        self.quota.refresh(dispatcher);
        app.focusPanelById("explorer");
    }

    fn onTick(ctx: ?*anyopaque, _: *tui.TuiApp, dispatcher: inbound.HostDispatcher) void {
        const self: *VaultAppCtx = @ptrCast(@alignCast(ctx.?));
        self.quota.onTick(dispatcher);
        self.viewer.onTick(dispatcher);
    }

    fn onCapabilityComplete(
        ctx: ?*anyopaque,
        app: *tui.TuiApp,
        cap_id: []const u8,
        status_code: i32,
        dispatcher: inbound.HostDispatcher,
    ) void {
        if (!std.mem.eql(u8, cap_id, "read") and
            !std.mem.eql(u8, cap_id, "ls") and
            !std.mem.eql(u8, cap_id, "quotas"))
        {
            app.setPanelVisible("hex_viewer", false);
            app.setPanelVisible("output", true);
        }
        if (status_code < 200 or status_code >= 300) return;
        const self: *VaultAppCtx = @ptrCast(@alignCast(ctx.?));
        if (std.mem.eql(u8, cap_id, "upload") or
            std.mem.eql(u8, cap_id, "mkdir") or
            std.mem.eql(u8, cap_id, "delete"))
        {
            self.explorer.loadDir(self.explorer.current_parent_id, dispatcher);
            self.quota.refresh(dispatcher);
        }
    }
};

fn formatSize(buf: *[24]u8, bytes: u64) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "?";
    const f: f64 = @floatFromInt(bytes);
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.2}K", .{f / 1024.0}) catch "?";
    if (bytes < 1024 * 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.2}M", .{f / (1024.0 * 1024.0)}) catch "?";
    const tb: u64 = 1024 * 1024 * 1024 * 1024;
    if (bytes < tb) return std.fmt.bufPrint(buf, "{d:.2}G", .{f / (1024.0 * 1024.0 * 1024.0)}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.2}T", .{f / @as(f64, @floatFromInt(tb))}) catch "?";
}

fn vaultTuiServe(
    _: *abi.extension.TransportCtx_ABI,
    _: abi.Slice_ABI,
    _: abi.Slice_ABI,
    host_dispatcher: *anyopaque,
    dispatch_fn: abi.extension.HostDispatchFn_ABI,
) callconv(.c) abi.HostError_ABI {
    const alloc = std.heap.c_allocator;
    if (global_kernel) |k| {
        if (global_api) |api| {
            if (inbound.fetchCapabilityCatalog(alloc, k, api) catch null) |parsed| {
                if (global_catalog_parsed) |*old| old.deinit();
                global_catalog_parsed = parsed;
            }
        }
    }
    const catalog: sdk.capabilities.CapabilityCatalog = if (global_catalog_parsed) |cp|
        cp.value
    else
        .{
            .id = "vault",
            .name = "Parabellum Vault",
            .version = "2.0.3",
        };

    const dispatcher = inbound.HostDispatcher{
        .ptr = host_dispatcher,
        .dispatch_fn = dispatch_fn,
    };

    var explorer = VaultExplorer.init(alloc);
    defer explorer.deinit();

    var quota = VaultQuotaPanel{ .alloc = alloc };
    var viewer = VaultHexViewer{ .alloc = alloc };
    var app_ctx = VaultAppCtx{ .explorer = &explorer, .quota = &quota, .viewer = &viewer };

    const panels = [_]tui.CustomPanel{
        .{
            .id = "explorer",
            .title = "Explorer",
            .dock = .left,
            .visible = true,
            .ctx = &explorer,
            .render = VaultExplorer.render,
            .handle_key = VaultExplorer.handleKey,
        },
        .{
            .id = "quota",
            .title = "Drive Quota",
            .dock = .left,
            .visible = true,
            .preferred_height = 9,
            .ctx = &quota,
            .render = VaultQuotaPanel.render,
            .handle_key = VaultQuotaPanel.handleKey,
        },
        .{
            .id = "hex_viewer",
            .title = "Hex / File Viewer",
            .dock = .main_bottom,
            .visible = false,
            .ctx = &viewer,
            .render = VaultHexViewer.render,
            .handle_key = VaultHexViewer.handleKey,
        },
    };

    var app = tui.TuiApp.init(alloc, catalog, &global_event_ring, .{
        .show_sidebar = false,
        .form_on_demand = true,
        .logs_visible = false,
        .extra_panels = &panels,
        .on_start = VaultAppCtx.onStart,
        .on_start_ctx = &app_ctx,
        .on_tick = VaultAppCtx.onTick,
        .on_tick_ctx = &app_ctx,
        .on_capability_complete = VaultAppCtx.onCapabilityComplete,
        .on_capability_complete_ctx = &app_ctx,
    }) catch return .out_of_memory;
    defer app.deinit();

    app.run(dispatcher) catch |err| switch (err) {
        error.NotATerminal => return .invalid_argument,
        else => return .internal_error,
    };
    return .ok;
}

fn vaultTuiDeinit(_: *abi.extension.TransportCtx_ABI) callconv(.c) void {
    if (global_catalog_parsed) |*old| {
        old.deinit();
        global_catalog_parsed = null;
    }
}

const vault_tui_vtable = abi.InboundTransportVTable_ABI{
    .serve = vaultTuiServe,
    .deinit = vaultTuiDeinit,
};

fn registerVaultTui(kernel: *abi.extension.KernelHandle_ABI, api: *const abi.KernelApiVTable_ABI) anyerror!void {
    global_kernel = kernel;
    global_api = api;
    if (inbound.fetchCapabilityCatalog(std.heap.c_allocator, kernel, api) catch null) |parsed| {
        if (global_catalog_parsed) |*old| old.deinit();
        global_catalog_parsed = parsed;
    }
    _ = api.subscribe_telemetry(kernel, @ptrCast(&transport_ctx_marker), &telemetry_sub_vtable);
    const rc = api.register_inbound_transport(
        kernel,
        "vault_tui",
        @ptrCast(&transport_ctx_marker),
        &vault_tui_vtable,
    );
    if (rc != .ok) return error.RegisterInboundTransportFailed;
}

pub const manifest = sdk.extension.Extension.define(.{
    .name = "vault_tui",
    .version = .{ .major = 2, .minor = 0, .patch = 3 },
    .register = registerVaultTui,
});

comptime {
    @export(&manifest, .{ .name = abi.EXTENSION_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

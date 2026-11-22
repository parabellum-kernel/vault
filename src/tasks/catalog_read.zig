const std = @import("std");
const sdk = @import("parabellum_sdk");
const VaultState = @import("../VaultState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const CatalogReadInputs = struct {
    op: []const u8 = "ls",
    vault_id: []const u8 = "default",
    parent_id: []const u8 = "",
    query: []const u8 = "",
};

pub const CatalogReadOutputs = struct {
    op: []const u8,
    count: i64,
    data_json: []const u8,
};

pub const CatalogReadService = struct {
    state: *VaultState,
    logger: Logger,

    pub fn execute(self: *CatalogReadService, alloc: std.mem.Allocator, inputs: CatalogReadInputs) !CatalogReadOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");

        if (std.mem.eql(u8, inputs.op, "quotas")) {
            var q = try entry.vault.getQuotas(VaultState.unixNow(self.state.io));
            defer q.deinit(entry.vault.allocator);
            const json = try std.fmt.allocPrint(
                alloc,
                "{{\"total_bytes\":{d},\"used_bytes\":{d},\"available_bytes\":{d},\"node_count\":{d}}}",
                .{ q.total_bytes, q.used_bytes, q.available_bytes, q.nodes.len },
            );
            return .{ .op = "quotas", .count = @intCast(q.nodes.len), .data_json = json };
        }

        if (std.mem.eql(u8, inputs.op, "metrics")) {
            const rc = &entry.vault.session.range_cache;
            const json = try std.fmt.allocPrint(
                alloc,
                "{{\"cache_hits\":{d},\"cache_misses\":{d},\"cache_bytes\":{d},\"partition_count\":{d},\"mounted_vaults\":{d}}}",
                .{ rc.hits, rc.misses, rc.current_bytes, entry.partitions.partitions.count(), self.state.vaults.count() },
            );
            return .{ .op = "metrics", .count = 1, .data_json = json };
        }

        if (std.mem.eql(u8, inputs.op, "refresh")) {
            const updated = try entry.vault.refresh();
            const json = try std.fmt.allocPrint(alloc, "{{\"updated\":{}}}", .{updated});
            return .{ .op = "refresh", .count = if (updated) 1 else 0, .data_json = json };
        }

        if (std.mem.eql(u8, inputs.op, "search")) {
            var queue: std.ArrayListUnmanaged(?[]u8) = .empty;
            defer {
                for (queue.items) |item| {
                    if (item) |p| alloc.free(p);
                }
                queue.deinit(alloc);
            }
            try queue.append(alloc, if (inputs.parent_id.len == 0) null else try alloc.dupe(u8, inputs.parent_id));

            var aw: std.Io.Writer.Allocating = .init(alloc);
            errdefer aw.deinit();
            try aw.writer.writeByte('[');
            var match_count: i64 = 0;

            var head: usize = 0;
            while (head < queue.items.len) : (head += 1) {
                const cur_parent = queue.items[head];
                const children = try entry.vault.listDir(cur_parent);
                defer entry.vault.allocator.free(children);

                for (children) |c| {
                    if (c.kind == .dir) {
                        try queue.append(alloc, try alloc.dupe(u8, c.inode_id));
                    }
                    const matches = inputs.query.len == 0 or containsIgnoreCase(c.name, inputs.query);
                    if (matches) {
                        const sz: u64 = if (c.kind == .dir) try dirLogicalSize(&entry.vault, alloc, c.inode_id) else c.logical_size;
                        if (match_count > 0) try aw.writer.writeByte(',');
                        try aw.writer.print(
                            "{{\"inode_id\":\"{s}\",\"name\":\"{s}\",\"kind\":\"{s}\",\"logical_size\":{d},\"mtime\":{d}}}",
                            .{ c.inode_id, c.name, @tagName(c.kind), sz, c.mtime },
                        );
                        match_count += 1;
                    }
                }
            }
            try aw.writer.writeByte(']');
            self.logger.info("Search '{s}' matched {d} entries in vault '{s}'", .{ inputs.query, match_count, inputs.vault_id });
            return .{
                .op = "search",
                .count = match_count,
                .data_json = try aw.toOwnedSlice(),
            };
        }

        // Default: "ls"
        const parent: ?[]const u8 = if (inputs.parent_id.len == 0) null else inputs.parent_id;
        const children = try entry.vault.listDir(parent);
        defer entry.vault.allocator.free(children);

        var aw: std.Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        try aw.writer.writeByte('[');
        for (children, 0..) |c, i| {
            const sz: u64 = if (c.kind == .dir) try dirLogicalSize(&entry.vault, alloc, c.inode_id) else c.logical_size;
            if (i > 0) try aw.writer.writeByte(',');
            try aw.writer.print(
                "{{\"inode_id\":\"{s}\",\"name\":\"{s}\",\"kind\":\"{s}\",\"logical_size\":{d},\"mtime\":{d}}}",
                .{ c.inode_id, c.name, @tagName(c.kind), sz, c.mtime },
            );
        }
        try aw.writer.writeByte(']');

        self.logger.info("Listed {d} entries in vault '{s}'", .{ children.len, inputs.vault_id });
        return .{
            .op = "ls",
            .count = @intCast(children.len),
            .data_json = try aw.toOwnedSlice(),
        };
    }
};

fn dirLogicalSize(vault: anytype, alloc: std.mem.Allocator, dir_inode_id: []const u8) !u64 {
    var total: u64 = 0;
    var queue: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (queue.items) |id| alloc.free(id);
        queue.deinit(alloc);
    }
    try queue.append(alloc, try alloc.dupe(u8, dir_inode_id));

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const children = try vault.listDir(queue.items[head]);
        defer vault.allocator.free(children);
        for (children) |c| {
            if (c.kind == .dir) {
                try queue.append(alloc, try alloc.dupe(u8, c.inode_id));
            } else {
                total += c.logical_size;
            }
        }
    }
    return total;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

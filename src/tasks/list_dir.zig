const std = @import("std");
const sdk = @import("parabellum_sdk");
const DaemonState = @import("../DaemonState.zig");
const container = @import("../container.zig");

const Logger = sdk.task.Logger;

pub const LsInputs = struct {
    vault_id: []const u8 = "default",
    parent_id: []const u8 = "",
};

pub const LsOutputs = struct {
    count: i64,
    entries_json: []const u8,
};

pub const ListDirService = struct {
    state: *DaemonState,
    logger: Logger,

    pub fn execute(self: *ListDirService, alloc: std.mem.Allocator, inputs: LsInputs) !LsOutputs {
        const entry = try container.getOrMountVault(self.state, inputs.vault_id, "vault-desktop-01");
        const parent: ?[]const u8 = if (inputs.parent_id.len == 0) null else inputs.parent_id;

        const children = try entry.vault.listDir(parent);
        defer entry.vault.allocator.free(children);

        var aw: std.Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        try aw.writer.writeByte('[');
        for (children, 0..) |c, i| {
            if (i > 0) try aw.writer.writeByte(',');
            try aw.writer.print(
                "{{\"inode_id\":\"{s}\",\"name\":\"{s}\",\"kind\":\"{s}\",\"logical_size\":{d},\"mtime\":{d}}}",
                .{ c.inode_id, c.name, @tagName(c.kind), c.logical_size, c.mtime },
            );
        }
        try aw.writer.writeByte(']');

        self.logger.info("Listed {d} entries in vault '{s}'", .{ children.len, inputs.vault_id });
        return .{
            .count = @intCast(children.len),
            .entries_json = try aw.toOwnedSlice(),
        };
    }
};

const std = @import("std");

/// Minimal `.env` parser + `${VAR:-default}` interpolator (pure Zig, zero deps).
pub const EnvStore = struct {
    vars: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn init() EnvStore {
        return .{};
    }

    pub fn deinit(self: *EnvStore, allocator: std.mem.Allocator) void {
        var it = self.vars.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        self.vars.deinit(allocator);
    }

    pub fn put(self: *EnvStore, allocator: std.mem.Allocator, key: []const u8, val: []const u8) !void {
        if (self.vars.getPtr(key)) |existing| {
            const new_val = try allocator.dupe(u8, val);
            allocator.free(existing.*);
            existing.* = new_val;
            return;
        }
        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, val);
        errdefer allocator.free(v);
        try self.vars.put(allocator, k, v);
    }

    pub fn get(self: *const EnvStore, key: []const u8) ?[]const u8 {
        return self.vars.get(key);
    }

    pub fn parseDotEnv(self: *EnvStore, allocator: std.mem.Allocator, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = std.mem.trim(u8, line[0..eq], " \t");
            var v = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
                v = v[1 .. v.len - 1];
            }
            if (k.len > 0) try self.put(allocator, k, v);
        }
    }

    /// Expands `${VAR:-default}` and `${VAR}` expressions against `self`.
    pub fn interpolate(self: *const EnvStore, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();

        var i: usize = 0;
        while (i < input.len) {
            if (i + 1 < input.len and input[i] == '$' and input[i + 1] == '{') {
                if (std.mem.indexOfScalarPos(u8, input, i + 2, '}')) |close| {
                    const expr = input[i + 2 .. close];
                    if (std.mem.indexOf(u8, expr, ":-")) |sep| {
                        const key = expr[0..sep];
                        const def = expr[sep + 2 ..];
                        try aw.writer.writeAll(self.get(key) orelse def);
                    } else {
                        try aw.writer.writeAll(self.get(expr) orelse "");
                    }
                    i = close + 1;
                    continue;
                }
            }
            try aw.writer.writeByte(input[i]);
            i += 1;
        }
        return aw.toOwnedSlice();
    }
};

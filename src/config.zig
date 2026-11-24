const std = @import("std");
const EnvInterpolator = @import("parabellum_yaml").EnvInterpolator;
const PartitionManager = @import("PartitionManager.zig");

/// Declarative configuration loaded from `configs/.env` + `configs/vault.yaml`.
pub const AppConfig = struct {
    pub const PartitionSpec = struct {
        name: []u8,
        root_folder: []u8,
        quota_gb: u64 = 5,
        policy_kind: PartitionManager.PolicyKind = .most_available,

        pub fn deinit(self: *PartitionSpec, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.root_folder);
        }
    };

    vault_id: []u8,
    device_id: []u8,
    device_key_path: []u8,
    user_key_path: []u8,
    sa_keys_dir: []u8,
    bootstrap_cred: []u8,
    upload_policy: PartitionManager.PolicyKind = .most_available,
    read_cache_mb: usize = 64,
    pack_enabled: bool = true,
    small_file_threshold_mb: u64 = 8,
    max_pack_size_mb: u64 = 64,
    partitions: []PartitionSpec = &.{},

    pub fn initDefault(allocator: std.mem.Allocator) !AppConfig {
        return .{
            .vault_id = try allocator.dupe(u8, "default"),
            .device_id = try allocator.dupe(u8, "vault-desktop-01"),
            .device_key_path = try allocator.dupe(u8, "./data/device.key"),
            .user_key_path = try allocator.dupe(u8, "./configs/user_keys/oauth_user.json"),
            .sa_keys_dir = try allocator.dupe(u8, "./configs/sa_keys"),
            .bootstrap_cred = try allocator.dupe(u8, "./configs/sa_keys/vfs-sa-01.json"),
        };
    }

    pub fn deinit(self: *AppConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.vault_id);
        allocator.free(self.device_id);
        allocator.free(self.device_key_path);
        allocator.free(self.user_key_path);
        allocator.free(self.sa_keys_dir);
        allocator.free(self.bootstrap_cred);
        for (self.partitions) |*p| p.deinit(allocator);
        if (self.partitions.len > 0) allocator.free(self.partitions);
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, env_path: []const u8, yaml_path: []const u8) !AppConfig {
        var env_arena = std.heap.ArenaAllocator.init(allocator);
        defer env_arena.deinit();
        const env_alloc = env_arena.allocator();

        var env = EnvInterpolator.init(true);

        if (readFileAlloc(allocator, io, env_path)) |raw_env| {
            defer allocator.free(raw_env);
            try env.parseDotEnv(env_alloc, raw_env);
        } else |_| {}

        var cfg = try initDefault(allocator);
        errdefer cfg.deinit(allocator);

        if (readFileAlloc(allocator, io, yaml_path)) |raw_yaml| {
            defer allocator.free(raw_yaml);
            try parseVaultYaml(allocator, &env, raw_yaml, &cfg);
        } else |_| {}

        return cfg;
    }

    fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buf);
        return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    }

    fn stripCommentAndQuotes(raw: []const u8) []const u8 {
        var s = raw;
        var in_quotes = false;
        var q_char: u8 = 0;
        for (s, 0..) |ch, idx| {
            if ((ch == '"' or ch == '\'') and !in_quotes) {
                in_quotes = true;
                q_char = ch;
            } else if (in_quotes and ch == q_char) {
                in_quotes = false;
            } else if (!in_quotes and ch == '#') {
                s = s[0..idx];
                break;
            }
        }
        s = std.mem.trim(u8, s, " \t\r");
        if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
            s = s[1 .. s.len - 1];
        }
        return s;
    }

    fn parsePolicy(s: []const u8) PartitionManager.PolicyKind {
        if (std.mem.eql(u8, s, "first_fit")) return .first_fit;
        if (std.mem.eql(u8, s, "random")) return .random;
        if (std.mem.eql(u8, s, "pinned")) return .pinned;
        return .most_available;
    }

    pub fn parseVaultYaml(allocator: std.mem.Allocator, env: *const EnvInterpolator, raw_yaml: []const u8, cfg: *AppConfig) !void {
        var interp_arena = std.heap.ArenaAllocator.init(allocator);
        defer interp_arena.deinit();
        const ia = interp_arena.allocator();

        var parts = std.ArrayListUnmanaged(PartitionSpec).empty;
        errdefer {
            for (parts.items) |*p| p.deinit(allocator);
            parts.deinit(allocator);
        }

        const Section = enum { none, vault, pack, partitions };
        var section: Section = .none;
        var cur_part: ?PartitionSpec = null;
        errdefer if (cur_part) |*cp| cp.deinit(allocator);

        var lines = std.mem.splitScalar(u8, raw_yaml, '\n');
        while (lines.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            const indent = raw_line.len - std.mem.trimStart(u8, raw_line, " ").len;
            if (indent == 0) {
                if (cur_part) |cp| {
                    try parts.append(allocator, cp);
                    cur_part = null;
                }
                if (std.mem.startsWith(u8, trimmed, "vault:")) section = .vault else if (std.mem.startsWith(u8, trimmed, "partitions:")) section = .partitions else section = .none;
                continue;
            }

            if (section == .vault or section == .pack) {
                if (indent == 2 and std.mem.startsWith(u8, trimmed, "pack:")) {
                    section = .pack;
                    continue;
                }
                if (indent == 2 and section == .pack) section = .vault;
                const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
                const k = std.mem.trim(u8, trimmed[0..colon], " \t");
                const raw_v = stripCommentAndQuotes(trimmed[colon + 1 ..]);
                const v = try env.interpolate(ia, raw_v);

                if (section == .vault) {
                    if (std.mem.eql(u8, k, "id")) {
                        allocator.free(cfg.vault_id);
                        cfg.vault_id = try allocator.dupe(u8, v);
                    } else if (std.mem.eql(u8, k, "device_id")) {
                        allocator.free(cfg.device_id);
                        cfg.device_id = try allocator.dupe(u8, v);
                    } else if (std.mem.eql(u8, k, "device_key_path")) {
                        allocator.free(cfg.device_key_path);
                        cfg.device_key_path = try allocator.dupe(u8, v);
                    } else if (std.mem.eql(u8, k, "user_key_path")) {
                        allocator.free(cfg.user_key_path);
                        cfg.user_key_path = try allocator.dupe(u8, v);
                    } else if (std.mem.eql(u8, k, "sa_keys_dir")) {
                        allocator.free(cfg.sa_keys_dir);
                        cfg.sa_keys_dir = try allocator.dupe(u8, v);
                    } else if (std.mem.eql(u8, k, "bootstrap_cred")) {
                        allocator.free(cfg.bootstrap_cred);
                        cfg.bootstrap_cred = try allocator.dupe(u8, v);
                    } else if (std.mem.eql(u8, k, "upload_policy")) {
                        cfg.upload_policy = parsePolicy(v);
                    } else if (std.mem.eql(u8, k, "read_cache_mb")) {
                        cfg.read_cache_mb = std.fmt.parseInt(usize, v, 10) catch cfg.read_cache_mb;
                    }
                } else if (section == .pack) {
                    if (std.mem.eql(u8, k, "enabled")) {
                        cfg.pack_enabled = std.mem.eql(u8, v, "true");
                    } else if (std.mem.eql(u8, k, "small_file_threshold_mb")) {
                        cfg.small_file_threshold_mb = std.fmt.parseInt(u64, v, 10) catch cfg.small_file_threshold_mb;
                    } else if (std.mem.eql(u8, k, "max_pack_size_mb")) {
                        cfg.max_pack_size_mb = std.fmt.parseInt(u64, v, 10) catch cfg.max_pack_size_mb;
                    }
                }
            } else if (section == .partitions) {
                var item_line = trimmed;
                if (std.mem.startsWith(u8, item_line, "- ")) {
                    if (cur_part) |cp| try parts.append(allocator, cp);
                    cur_part = .{
                        .name = try allocator.dupe(u8, ""),
                        .root_folder = try allocator.dupe(u8, "/"),
                    };
                    item_line = std.mem.trim(u8, item_line[2..], " \t");
                }
                if (cur_part == null) continue;
                const colon = std.mem.indexOfScalar(u8, item_line, ':') orelse continue;
                const k = std.mem.trim(u8, item_line[0..colon], " \t");
                const raw_v = stripCommentAndQuotes(item_line[colon + 1 ..]);
                const v = try env.interpolate(ia, raw_v);

                if (std.mem.eql(u8, k, "name")) {
                    allocator.free(cur_part.?.name);
                    cur_part.?.name = try allocator.dupe(u8, v);
                } else if (std.mem.eql(u8, k, "root_folder")) {
                    allocator.free(cur_part.?.root_folder);
                    cur_part.?.root_folder = try allocator.dupe(u8, v);
                } else if (std.mem.eql(u8, k, "quota_gb")) {
                    cur_part.?.quota_gb = std.fmt.parseInt(u64, v, 10) catch 5;
                } else if (std.mem.eql(u8, k, "upload_policy")) {
                    cur_part.?.policy_kind = parsePolicy(v);
                }
            }
        }
        if (cur_part) |cp| try parts.append(allocator, cp);
        cfg.partitions = try parts.toOwnedSlice(allocator);
    }
};

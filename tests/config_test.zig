const std = @import("std");
const app = @import("vault_app");

const EnvInterpolator = app.env.EnvInterpolator;
const AppConfig = app.config.AppConfig;

test "EnvInterpolator parses .env and interpolates ${VAR:-default}" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvInterpolator.init(false);

    try env.parseDotEnv(alloc,
        \\# comment
        \\VAULT_ID="prod-vault"
        \\VAULT_PORT=9090
    );

    const s1 = try env.interpolate(alloc, "${VAULT_ID:-default}");
    try std.testing.expectEqualStrings("prod-vault", s1);

    const s2 = try env.interpolate(alloc, "${MISSING_VAR:-fallback}");
    try std.testing.expectEqualStrings("fallback", s2);
}

test "AppConfig loads configs/.env.example + configs/vault.yaml with partitions" {
    const alloc = std.testing.allocator;
    var cfg = try AppConfig.load(alloc, std.testing.io, "configs/.env.example", "configs/vault.yaml");
    defer cfg.deinit(alloc);

    try std.testing.expectEqualStrings("default", cfg.vault_id);
    try std.testing.expectEqualStrings("vault-desktop-01", cfg.device_id);
    try std.testing.expectEqualStrings("./configs/sa_keys", cfg.sa_keys_dir);
    try std.testing.expectEqual(@as(usize, 2), cfg.partitions.len);
    try std.testing.expectEqualStrings("official_docs", cfg.partitions[0].name);
    try std.testing.expectEqual(@as(u64, 5), cfg.partitions[0].quota_gb);
    try std.testing.expectEqualStrings("archives", cfg.partitions[1].name);
    try std.testing.expectEqual(@as(u64, 50), cfg.partitions[1].quota_gb);
}

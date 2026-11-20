const std = @import("std");
const VaultState = @import("vault_app").VaultState;

test "VaultState mounts vault and writes/reads partitions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var state = VaultState.init(allocator, io);
    defer state.deinit();

    const entry = try state.createInMemoryVault("default", "vault-test", 1700000000);
    const id = try entry.vault.write(null, "hello.txt", "vault daemon payload", .{}, 1700000010);
    defer allocator.free(id);

    var out: [20]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 20), try entry.vault.readAt(id, 0, &out));
    try std.testing.expectEqualStrings("vault daemon payload", &out);

    // Logical partitions: 10-byte cap -> first write succeeds, second fails, resize to 64 -> succeeds
    try entry.partitions.createPartition(
        &entry.vault,
        "official",
        "/official",
        10,
        .first_fit,
        &.{"mem:node-1"},
        1700000030,
    );
    const p_file1 = try entry.partitions.writeFile(&entry.vault, "official", "doc1.pdf", "12345", 1700000040);
    defer allocator.free(p_file1);

    try std.testing.expectError(
        error.PartitionQuotaExceeded,
        entry.partitions.writeFile(&entry.vault, "official", "doc2.pdf", "123456", 1700000050),
    );

    try entry.partitions.resizePartition("official", 64);
    const p_file2 = try entry.partitions.writeFile(&entry.vault, "official", "doc2.pdf", "123456", 1700000060);
    defer allocator.free(p_file2);
    try std.testing.expectEqual(@as(u64, 11), try entry.partitions.usedBytes(&entry.vault, "official"));
}


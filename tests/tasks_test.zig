const std = @import("std");
const sdk = @import("parabellum_sdk");
const app = @import("vault_app");

const catalog = app.catalog;
const container = app.container;

test "vault catalog exports 6 primitive Service tasks and executes full CRUD + GC + Quotas lifecycle" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 6), catalog.tasks.len);

    const state = container.acquireGlobalState();
    defer container.releaseGlobalState();
    const logger = sdk.task.Logger.noop();

    var mount_svc = catalog.MountService{ .state = state, .logger = logger };
    const mount_res = try mount_svc.execute(alloc, .{ .op = "init", .vault_id = "task-test", .device_id = "pc-01" });
    defer alloc.free(mount_res.vault_id);
    try std.testing.expectEqualStrings("ready", mount_res.status);

    var cw_svc = catalog.CatalogWriteService{ .state = state, .logger = logger };
    const dir_res = try cw_svc.execute(alloc, .{ .op = "mkdir", .vault_id = "task-test", .name = "docs" });
    defer alloc.free(dir_res.inode_id);

    var write_svc = catalog.WriteDataService{ .state = state, .logger = logger };
    const up_res = try write_svc.execute(alloc, .{
        .op = "file",
        .vault_id = "task-test",
        .parent_id = dir_res.inode_id,
        .name = "note.txt",
        .data = "hello from vault service!",
    });
    defer alloc.free(up_res.inode_id);
    try std.testing.expectEqual(@as(i64, 25), up_res.logical_size);

    var cr_svc = catalog.CatalogReadService{ .state = state, .logger = logger };
    const ls_res = try cr_svc.execute(alloc, .{ .op = "ls", .vault_id = "task-test", .parent_id = dir_res.inode_id });
    defer alloc.free(ls_res.data_json);
    try std.testing.expectEqual(@as(i64, 1), ls_res.count);
    try std.testing.expect(std.mem.indexOf(u8, ls_res.data_json, "note.txt") != null);

    const search_res = try cr_svc.execute(alloc, .{ .op = "search", .vault_id = "task-test", .query = "NOTE" });
    defer alloc.free(search_res.data_json);
    try std.testing.expectEqual(@as(i64, 1), search_res.count);
    try std.testing.expect(std.mem.indexOf(u8, search_res.data_json, "note.txt") != null);

    var read_svc = catalog.ReadDataService{ .state = state, .logger = logger };
    const read_res = try read_svc.execute(alloc, .{
        .op = "range",
        .vault_id = "task-test",
        .inode_id = up_res.inode_id,
        .offset = 6,
        .max_len = 4,
    });
    defer alloc.free(read_res.data);
    try std.testing.expectEqual(@as(i64, 4), read_res.bytes_read);
    try std.testing.expectEqualStrings("from", read_res.data);

    const stream_res = try read_svc.execute(alloc, .{
        .op = "stream",
        .vault_id = "task-test",
        .inode_id = up_res.inode_id,
        .range = "bytes=0-4",
    });
    defer alloc.free(stream_res.content_range);
    defer alloc.free(stream_res.data);
    try std.testing.expectEqual(@as(i64, 206), stream_res.status_code);
    try std.testing.expectEqual(@as(i64, 5), stream_res.bytes_read);
    try std.testing.expectEqualStrings("bytes 0-4/25", stream_res.content_range);
    try std.testing.expectEqualStrings("hello", stream_res.data);

    const q_res = try cr_svc.execute(alloc, .{ .op = "quotas", .vault_id = "task-test" });
    defer alloc.free(q_res.data_json);
    try std.testing.expectEqual(@as(i64, 1), q_res.count);
    try std.testing.expect(std.mem.indexOf(u8, q_res.data_json, "used_bytes") != null);

    const ref_res = try cr_svc.execute(alloc, .{ .op = "refresh", .vault_id = "task-test" });
    defer alloc.free(ref_res.data_json);
    try std.testing.expectEqualStrings("{\"updated\":false}", ref_res.data_json);

    const del_res = try cw_svc.execute(alloc, .{ .op = "delete", .vault_id = "task-test", .inode_id = up_res.inode_id });
    defer alloc.free(del_res.inode_id);
    try std.testing.expect(del_res.ok);

    var gc_svc = catalog.GcService{ .state = state, .logger = logger };
    const gc_res = try gc_svc.execute(alloc, .{ .vault_id = "task-test" });
    try std.testing.expectEqual(@as(i64, 1), gc_res.deleted_blobs);
}

const std = @import("std");
const sdk = @import("parabellum_sdk");
const app = @import("vault_app");

const catalog = app.catalog;
const container = app.container;

test "vault catalog exports 15 Service tasks and executes full CRUD + GC + Quotas lifecycle" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 15), catalog.tasks.len);

    const state = container.acquireGlobalState();
    defer container.releaseGlobalState();
    const logger = sdk.task.Logger.noop();

    var init_svc = catalog.InitVaultService{ .state = state, .logger = logger };
    const init_res = try init_svc.execute(alloc, .{ .vault_id = "task-test", .device_id = "pc-01" });
    defer alloc.free(init_res.vault_id);
    try std.testing.expectEqualStrings("ready", init_res.status);

    var mkdir_svc = catalog.MkdirService{ .state = state, .logger = logger };
    const dir_res = try mkdir_svc.execute(alloc, .{ .vault_id = "task-test", .name = "docs" });
    defer alloc.free(dir_res.inode_id);

    var upload_svc = catalog.UploadFileService{ .state = state, .logger = logger };
    const up_res = try upload_svc.execute(alloc, .{
        .vault_id = "task-test",
        .parent_id = dir_res.inode_id,
        .name = "note.txt",
        .data = "hello from vault service!",
    });
    defer alloc.free(up_res.inode_id);
    try std.testing.expectEqual(@as(i64, 25), up_res.logical_size);

    var ls_svc = catalog.ListDirService{ .state = state, .logger = logger };
    const ls_res = try ls_svc.execute(alloc, .{ .vault_id = "task-test", .parent_id = dir_res.inode_id });
    defer alloc.free(ls_res.entries_json);
    try std.testing.expectEqual(@as(i64, 1), ls_res.count);
    try std.testing.expect(std.mem.indexOf(u8, ls_res.entries_json, "note.txt") != null);

    var read_svc = catalog.ReadRangeService{ .state = state, .logger = logger };
    const read_res = try read_svc.execute(alloc, .{
        .vault_id = "task-test",
        .inode_id = up_res.inode_id,
        .offset = 6,
        .max_len = 4,
    });
    defer alloc.free(read_res.data);
    try std.testing.expectEqual(@as(i64, 4), read_res.bytes_read);
    try std.testing.expectEqualStrings("from", read_res.data);

    var quotas_svc = catalog.GetQuotasService{ .state = state, .logger = logger };
    const q_res = try quotas_svc.execute(alloc, .{ .vault_id = "task-test" });
    try std.testing.expect(q_res.used_bytes > 0);
    try std.testing.expectEqual(@as(i64, 1), q_res.node_count);

    var refresh_svc = catalog.RefreshCatalogService{ .state = state, .logger = logger };
    const ref_res = try refresh_svc.execute(alloc, .{ .vault_id = "task-test" });
    try std.testing.expectEqual(false, ref_res.updated);

    var del_svc = catalog.DeleteInodeService{ .state = state, .logger = logger };
    const del_res = try del_svc.execute(alloc, .{ .vault_id = "task-test", .inode_id = up_res.inode_id });
    try std.testing.expect(del_res.deleted);

    var gc_svc = catalog.RunGcService{ .state = state, .logger = logger };
    const gc_res = try gc_svc.execute(alloc, .{ .vault_id = "task-test" });
    try std.testing.expectEqual(@as(i64, 1), gc_res.deleted_blobs);

    // Rename, writePacked, partition_create/resize, metrics, jobs
    var part_create = catalog.PartitionCreateService{ .state = state, .logger = logger };
    _ = try part_create.execute(alloc, .{
        .vault_id = "task-test",
        .name = "thumbs",
        .root_folder = "/thumbs",
        .quota_bytes = 1024,
    });
    var part_resize = catalog.PartitionResizeService{ .state = state, .logger = logger };
    const r_part = try part_resize.execute(alloc, .{
        .vault_id = "task-test",
        .name = "thumbs",
        .new_quota_bytes = 2048,
    });
    try std.testing.expectEqual(@as(i64, 2048), r_part.new_quota_bytes);

    var packed_svc = catalog.WritePackedService{ .state = state, .logger = logger };
    const packed_res = try packed_svc.execute(alloc, .{
        .vault_id = "task-test",
        .files_json = "[{\"name\":\"a.txt\",\"data\":\"aaa\"},{\"name\":\"b.txt\",\"data\":\"bbb\"}]",
    });
    defer alloc.free(packed_res.inode_ids_json);
    try std.testing.expectEqual(@as(i64, 2), packed_res.count);

    var job_svc = catalog.EnqueueJobService{ .state = state, .logger = logger };
    const j_res = try job_svc.execute(alloc, .{ .vault_id = "task-test", .kind = "gc", .target_path = "/" });
    try std.testing.expect(j_res.job_id >= 1);

    var metrics_svc = catalog.GetMetricsService{ .state = state, .logger = logger };
    const m_res = try metrics_svc.execute(alloc, .{ .vault_id = "task-test" });
    try std.testing.expectEqual(@as(i64, 1), m_res.partition_count);
    try std.testing.expect(m_res.job_count >= 1);
}

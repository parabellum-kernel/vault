const sdk = @import("parabellum_sdk");
const catalog = @import("catalog.zig");

pub const manifest = catalog.manifest;

comptime {
    @export(&manifest, .{ .name = sdk.task.MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

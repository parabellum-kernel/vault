const std = @import("std");
const sdk = @import("parabellum_sdk");

test "inspect driver manifests" {
    const paths = [_][]const u8{
        "/home/ubuntu/.gemini/antigravity/scratch/parabellum/driver/zig-out/lib/libdriver_yaml.so",
        "/home/ubuntu/.gemini/antigravity/scratch/parabellum/driver/zig-out/lib/libdriver_sqlite.so",
    };
    for (paths) |p| {
        var lib = try std.DynLib.open(p);
        defer lib.close();
        const sym = lib.lookup(*const sdk.abi.DriverManifest_ABI, sdk.abi.DRIVER_MANIFEST_SYMBOL_NAME);
        if (sym) |m| {
            std.debug.print("Driver {s}: name='{s}' abi={d} (expected {d}) min_engine={d}.{d}.{d} engine={d}.{d}.{d}\n", .{
                p,
                m.nameSlice(),
                m.abi_version,
                sdk.abi.DRIVER_ABI_VERSION,
                m.min_engine_version.major,
                m.min_engine_version.minor,
                m.min_engine_version.patch,
                sdk.abi.common.SDK_VERSION.major,
                sdk.abi.common.SDK_VERSION.minor,
                sdk.abi.common.SDK_VERSION.patch,
            });
        } else {
            std.debug.print("Missing manifest in {s}\n", .{p});
        }
    }
}

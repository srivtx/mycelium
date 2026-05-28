const std = @import("std");
const onchain = @import("build/onchain.zig");

pub fn build(b: *std.Build) void {
    const mycelium = b.dependency("mycelium", .{});
    const program_name = "__NAME__";

    onchain.addProgram(b, .{
        .name = program_name,
        .root = "src/main.zig",
        .mycelium_root = mycelium.path("src/root.zig"),
        .step_name = program_name,
    });
}

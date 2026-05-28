//! Root build script for `mycelium`.
//!
//! Two build modes are exposed:
//!
//!   zig build              -> host-side library + tests
//!   zig build hello        -> examples/hello compiled to SBPFv3 .so
//!   zig build counter      -> examples/counter compiled to SBPFv3 .so
//!
//! On-chain programs are built in two passes:
//!   1. zig build-lib -target bpfel-freestanding -O ReleaseSmall
//!                    -fno-emit-bin -femit-llvm-bc=<name>.bc
//!   2. sbpf-linker --override-cpu-flag v3 -o <name>.so <name>.bc
//!
//! `sbpf-linker` must be on $PATH (`cargo install sbpf-linker`).

const std = @import("std");
const onchain = @import("build/onchain.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ----- Host library + tests --------------------------------------------
    const mycelium_mod = b.addModule("mycelium", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = mycelium_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run host-side unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // ----- On-chain program builds -----------------------------------------
    addOnchainProgram(b, .{
        .name = "hello",
        .root = "examples/hello/src/main.zig",
        .step_name = "hello",
    });
    addOnchainProgram(b, .{
        .name = "counter",
        .root = "examples/counter/src/main.zig",
        .step_name = "counter",
    });
    addOnchainProgram(b, .{
        .name = "bare",
        .root = "examples/bare/src/main.zig",
        .step_name = "bare",
    });
    addOnchainProgram(b, .{
        .name = "vault",
        .root = "examples/vault/src/main.zig",
        .step_name = "vault",
    });
    addOnchainProgram(b, .{
        .name = "escrow",
        .root = "examples/escrow/src/main.zig",
        .step_name = "escrow",
    });
    addOnchainProgram(b, .{
        .name = "vault_v2",
        .root = "examples/vault_v2/src/main.zig",
        .step_name = "vault_v2",
    });
    addOnchainProgram(b, .{
        .name = "escrow_v2",
        .root = "examples/escrow_v2/src/main.zig",
        .step_name = "escrow_v2",
    });
    addOnchainProgram(b, .{
        .name = "vault_v3",
        .root = "examples/vault_v3/src/main.zig",
        .step_name = "vault_v3",
    });
    addOnchainProgram(b, .{
        .name = "escrow_v3",
        .root = "examples/escrow_v3/src/main.zig",
        .step_name = "escrow_v3",
    });
    addOnchainProgram(b, .{
        .name = "counter_demo",
        .root = "examples/counter_demo/src/main.zig",
        .step_name = "counter_demo",
    });
}

const OnchainOptions = struct {
    name: []const u8,
    root: []const u8,
    step_name: []const u8,
};

fn addOnchainProgram(b: *std.Build, opts: OnchainOptions) void {
    onchain.addProgram(b, .{
        .name = opts.name,
        .root = opts.root,
        .mycelium_root = b.path("src/root.zig"),
        .step_name = opts.step_name,
    });
}

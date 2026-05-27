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

/// Adds a build step that produces `zig-out/lib/<name>.so` for the SBPFv3
/// runtime. We can't ask Zig's build system to emit a BPF shared object
/// directly because Zig links with `lld`, which doesn't produce SBPF.
/// Instead we emit LLVM bitcode and hand it to `sbpf-linker`.
fn addOnchainProgram(b: *std.Build, opts: OnchainOptions) void {
    const bc_path = b.pathJoin(&.{ b.cache_root.path orelse "zig-cache", b.fmt("{s}.bc", .{opts.name}) });
    const so_path = b.pathJoin(&.{ "zig-out", "lib", b.fmt("{s}.so", .{opts.name}) });

    // Step 1: Zig -> LLVM bitcode for bpfel-freestanding.
    // The new module syntax: -Mname=path declares a module; -Mroot=... is
    // the program's root module. Inter-module deps use --dep prefixes BEFORE
    // the module they apply to.
    //
    // We pin `-mcpu=v1` because the default `bpfel` CPU in Zig 0.16 is v3,
    // which enables the `alu32` feature. LLVM then emits SBPFv3 JMP32 opcodes
    // (e.g. 0x16 = JEQ32_IMM) that `sbpf-linker`'s SBPFv0 assembler can't
    // decode. v1 is the largest cpu without alu32 and is safe to target.
    const root_arg = b.fmt("-Mroot={s}", .{b.pathFromRoot(opts.root)});
    const dep_arg = b.fmt("-Mmycelium={s}", .{b.pathFromRoot("src/root.zig")});
    const emit_bc = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build-lib",
        "-target",
        "bpfel-freestanding",
        "-mcpu",
        "v1",
        "-O",
        "ReleaseSmall",
        "-fno-emit-bin",
        "-fstrip",
        b.fmt("-femit-llvm-bc={s}", .{bc_path}),
        "--dep",
        "mycelium",
        root_arg,
        dep_arg,
    });
    emit_bc.has_side_effects = true;

    // Step 2: sbpf-linker -> .so. The linker would otherwise strip `entrypoint`
    // because nothing internal references it; an explicit --export keeps it live.
    // NOTE: `sbpf-linker` v0.1.9 emits an SBPFv0 ELF (e_flags=0), which is the
    // most compatible format and is accepted by every Solana loader. The
    // `--override-cpu-flag v1` matches our Zig `-mcpu=v1` so LLVM and the
    // assembler agree on the instruction set.
    // NOTE on sbpf-linker -O: levels 2/3 enable LLVM passes that hoist string
    // literals out of .rodata and drop the lddw+r1/r2 argument setup before
    // extern syscall calls, producing a `call -1` with no operands set. The
    // runtime then jumps to an invalid PC and the program burns its entire CU
    // budget. -O 1 preserves the lowering we need.
    const link_so = b.addSystemCommand(&.{
        "sbpf-linker",
        "--override-cpu-flag",
        "v1",
        "--export",
        "entrypoint",
        "-O",
        "0",
        // Bump the BPF stack size above LLVM's default 512B/frame so that
        // larger handler graphs (multiple `framework.createPdaState` /
        // `framework.openState` calls inlined into the trampoline) do not
        // trip the "BPF stack limit exceeded" check.
        "--llvm-args=-bpf-stack-size=8192",
        "-o",
        so_path,
        bc_path,
    });
    link_so.step.dependOn(&emit_bc.step);
    link_so.has_side_effects = true;

    // Ensure zig-out/lib exists before we drop the .so in there.
    const ensure_dir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/lib" });
    link_so.step.dependOn(&ensure_dir.step);

    const step = b.step(opts.step_name, b.fmt("Build {s} as an SBPFv3 program (.so)", .{opts.name}));
    step.dependOn(&link_so.step);
}

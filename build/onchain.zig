//! Shared SBPF on-chain program build (Zig → bitcode → sbpf-linker → .so).
//! Used by the mycelium monorepo and by `mycelium init` scaffolded projects.

const std = @import("std");

pub const Options = struct {
    name: []const u8,
    /// Program root, relative to the consuming project's root (e.g. `src/main.zig`).
    root: []const u8,
    /// Lazy path to `mycelium` framework `src/root.zig` (from `b.dependency("mycelium", .{}).path("src/root.zig")` or `b.path("src/root.zig")` in the monorepo).
    mycelium_root: std.Build.LazyPath,
    /// `zig build` step name; defaults to `name`.
    step_name: ?[]const u8 = null,
};

pub fn addProgram(b: *std.Build, opts: Options) void {
    const step_name = opts.step_name orelse opts.name;
    const bc_path = b.pathJoin(&.{ b.cache_root.path orelse "zig-cache", b.fmt("{s}.bc", .{opts.name}) });
    const so_path = b.pathJoin(&.{ "zig-out", "lib", b.fmt("{s}.so", .{opts.name}) });

    const root_arg = b.fmt("-Mroot={s}", .{b.pathFromRoot(opts.root)});
    const mycelium_path = opts.mycelium_root.getPath(b);
    const dep_arg = b.fmt("-Mmycelium={s}", .{mycelium_path});

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

    const link_so = b.addSystemCommand(&.{
        "sbpf-linker",
        "--override-cpu-flag",
        "v1",
        "--export",
        "entrypoint",
        "-O",
        "0",
        "--llvm-args=-bpf-stack-size=8192",
        "-o",
        so_path,
        bc_path,
    });
    link_so.step.dependOn(&emit_bc.step);
    link_so.has_side_effects = true;

    const ensure_dir = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/lib" });
    link_so.step.dependOn(&ensure_dir.step);

    const step = b.step(step_name, b.fmt("Build {s} as an SBPF program (.so)", .{opts.name}));
    step.dependOn(&link_so.step);
}

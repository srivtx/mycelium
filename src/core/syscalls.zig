//! Solana syscalls — invoked via murmur3_32 function-pointer constants.
//!
//! ## Why function pointers, not `extern fn`?
//!
//! `sbpf-linker` (the only public Zig→SBPF toolchain) has a code-generation
//! bug: when an `extern fn` declaration is the target of a call, the LTO
//! pipeline drops the argument-setup instructions and ALSO strips the
//! `.rodata` section that holds any string literals passed in. The result is
//! a `call -1` with `r1..r5` uninitialized, which the runtime patches to a
//! syscall dispatch — and the syscall then reads garbage register values,
//! exhausting the compute budget or crashing.
//!
//! Both Zignocchio and Ziglana hit and worked around this the same way: bake
//! the syscall's murmur3_32 hash into the program as a function pointer
//! constant. The SBPF VM (SBPFv0 through v3) dispatches `call <hash>`
//! directly to the named syscall handler. Because the hash is a plain
//! integer constant baked into the .text section, there's no `extern`
//! declaration for the linker to special-case, and the argument setup
//! survives unscathed.
//!
//! ## Host-side test build
//!
//! When `builtin.cpu.arch != .bpfel`, the framework's host-side tests need
//! something that can actually be invoked. We provide weak C-callconv shims
//! and bind each name to either the hash-pointer (SBPF) or the shim (host).
//! Callers see the same `syscalls.sol_log_` symbol either way.

const builtin = @import("builtin");
const std = @import("std");

const is_sbf = builtin.cpu.arch == .bpfel or builtin.cpu.arch == .bpfeb;

// =====================================================================
// MurmurHash3 (32-bit) — comptime so every syscall gets its hash computed
// at compile time with zero runtime cost.
// =====================================================================

/// MurmurHash3 32-bit, seed = 0. Reference impl from
/// https://en.wikipedia.org/wiki/MurmurHash. Matches Solana's syscall
/// registration in `solana_bpf_loader_program::syscalls::register_syscalls`.
pub fn murmur3_32(comptime key: []const u8) u32 {
    @setEvalBranchQuota(100_000);
    const c1: u32 = 0xcc9e2d51;
    const c2: u32 = 0x1b873593;
    var h: u32 = 0;
    var i: usize = 0;
    const nblocks = key.len / 4;
    while (i < nblocks) : (i += 1) {
        var k: u32 = @as(u32, key[i * 4]) |
            (@as(u32, key[i * 4 + 1]) << 8) |
            (@as(u32, key[i * 4 + 2]) << 16) |
            (@as(u32, key[i * 4 + 3]) << 24);
        k = k *% c1;
        k = (k << 15) | (k >> 17);
        k = k *% c2;
        h ^= k;
        h = (h << 13) | (h >> 19);
        h = h *% 5 +% 0xe6546b64;
    }
    var k1: u32 = 0;
    const tail_start = nblocks * 4;
    const tail_len = key.len - tail_start;
    if (tail_len >= 3) k1 ^= @as(u32, key[tail_start + 2]) << 16;
    if (tail_len >= 2) k1 ^= @as(u32, key[tail_start + 1]) << 8;
    if (tail_len >= 1) {
        k1 ^= @as(u32, key[tail_start]);
        k1 = k1 *% c1;
        k1 = (k1 << 15) | (k1 >> 17);
        k1 = k1 *% c2;
        h ^= k1;
    }
    h ^= @as(u32, @intCast(key.len));
    h ^= h >> 16;
    h = h *% 0x85ebca6b;
    h ^= h >> 13;
    h = h *% 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

// =====================================================================
// Shared ABI structs used by the syscalls below.
// =====================================================================

pub const SolBytes = extern struct {
    addr: [*]const u8,
    len: u64,

    pub fn fromSlice(s: []const u8) SolBytes {
        return .{ .addr = s.ptr, .len = s.len };
    }
};

pub const AccountMetaC = extern struct {
    pubkey: *const [32]u8,
    is_writable: bool,
    is_signer: bool,
};

pub const InstructionC = extern struct {
    program_id: *const [32]u8,
    accounts: [*]const AccountMetaC,
    accounts_len: u64,
    data: [*]const u8,
    data_len: u64,
};

/// Layout the `sol_invoke_signed_c` syscall expects per account. The byte
/// layout matters; the alignment annotations on pointer fields don't (the
/// runtime reads bytes). We use `*align(1)` everywhere we point back into the
/// loader's input buffer because that buffer's lamports/data_len fields are
/// 1-byte-aligned within their per-account records (see `account/info.zig`).
pub const AccountInfoC = extern struct {
    key: *align(1) const [32]u8,
    lamports: *align(1) u64,
    data_len: u64,
    data: [*]u8,
    owner: *align(1) const [32]u8,
    rent_epoch: u64,
    is_signer: bool,
    is_writable: bool,
    executable: bool,
};

pub const SignerSeedC = extern struct {
    addr: [*]const u8,
    len: u64,
};

pub const SignerSeedsC = extern struct {
    addr: [*]const SignerSeedC,
    len: u64,
};

// =====================================================================
// Syscall bindings. Each one resolves to either a hash-as-function-pointer
// (on-chain) or a weak host shim (host tests).
// =====================================================================

fn Syscall(comptime Fn: type, comptime name: []const u8, comptime host_impl: anytype) Fn {
    return if (is_sbf)
        @as(Fn, @ptrFromInt(murmur3_32(name)))
    else
        host_impl;
}

pub const sol_log_: *align(1) const fn ([*]const u8, u64) callconv(.c) void =
    Syscall(*align(1) const fn ([*]const u8, u64) callconv(.c) void, "sol_log_", &host_sol_log_);

pub const sol_log_64_: *align(1) const fn (u64, u64, u64, u64, u64) callconv(.c) void =
    Syscall(*align(1) const fn (u64, u64, u64, u64, u64) callconv(.c) void, "sol_log_64_", &host_sol_log_64_);

pub const sol_log_compute_units_: *align(1) const fn () callconv(.c) void =
    Syscall(*align(1) const fn () callconv(.c) void, "sol_log_compute_units_", &host_sol_log_compute_units_);

pub const sol_log_pubkey: *align(1) const fn (*const [32]u8) callconv(.c) void =
    Syscall(*align(1) const fn (*const [32]u8) callconv(.c) void, "sol_log_pubkey", &host_sol_log_pubkey);

pub const sol_log_data: *align(1) const fn ([*]const SolBytes, u64) callconv(.c) void =
    Syscall(*align(1) const fn ([*]const SolBytes, u64) callconv(.c) void, "sol_log_data", &host_sol_log_data);

pub const sol_invoke_signed_c: *align(1) const fn (
    *const InstructionC,
    [*]const AccountInfoC,
    u64,
    [*]const SignerSeedsC,
    u64,
) callconv(.c) u64 = Syscall(
    *align(1) const fn (*const InstructionC, [*]const AccountInfoC, u64, [*]const SignerSeedsC, u64) callconv(.c) u64,
    "sol_invoke_signed_c",
    &host_sol_invoke_signed_c,
);

pub const sol_create_program_address: *align(1) const fn (
    [*]const SolBytes,
    u64,
    *const [32]u8,
    *[32]u8,
) callconv(.c) u64 = Syscall(
    *align(1) const fn ([*]const SolBytes, u64, *const [32]u8, *[32]u8) callconv(.c) u64,
    "sol_create_program_address",
    &host_sol_create_program_address,
);

pub const sol_try_find_program_address: *align(1) const fn (
    [*]const SolBytes,
    u64,
    *const [32]u8,
    *[32]u8,
    *u8,
) callconv(.c) u64 = Syscall(
    *align(1) const fn ([*]const SolBytes, u64, *const [32]u8, *[32]u8, *u8) callconv(.c) u64,
    "sol_try_find_program_address",
    &host_sol_try_find_program_address,
);

pub const sol_sha256: *align(1) const fn ([*]const SolBytes, u64, *[32]u8) callconv(.c) u64 =
    Syscall(*align(1) const fn ([*]const SolBytes, u64, *[32]u8) callconv(.c) u64, "sol_sha256", &host_sol_sha256);

pub const sol_keccak256: *align(1) const fn ([*]const SolBytes, u64, *[32]u8) callconv(.c) u64 =
    Syscall(*align(1) const fn ([*]const SolBytes, u64, *[32]u8) callconv(.c) u64, "sol_keccak256", &host_sol_keccak256);

pub const sol_blake3: *align(1) const fn ([*]const SolBytes, u64, *[32]u8) callconv(.c) u64 =
    Syscall(*align(1) const fn ([*]const SolBytes, u64, *[32]u8) callconv(.c) u64, "sol_blake3", &host_sol_blake3);

pub const sol_memcpy_: *align(1) const fn ([*]u8, [*]const u8, u64) callconv(.c) void =
    Syscall(*align(1) const fn ([*]u8, [*]const u8, u64) callconv(.c) void, "sol_memcpy_", &host_sol_memcpy_);

pub const sol_memmove_: *align(1) const fn ([*]u8, [*]const u8, u64) callconv(.c) void =
    Syscall(*align(1) const fn ([*]u8, [*]const u8, u64) callconv(.c) void, "sol_memmove_", &host_sol_memmove_);

pub const sol_memcmp_: *align(1) const fn ([*]const u8, [*]const u8, u64, *i32) callconv(.c) void =
    Syscall(*align(1) const fn ([*]const u8, [*]const u8, u64, *i32) callconv(.c) void, "sol_memcmp_", &host_sol_memcmp_);

pub const sol_memset_: *align(1) const fn ([*]u8, u8, u64) callconv(.c) void =
    Syscall(*align(1) const fn ([*]u8, u8, u64) callconv(.c) void, "sol_memset_", &host_sol_memset_);

pub const sol_get_clock_sysvar: *align(1) const fn (*[40]u8) callconv(.c) u64 =
    Syscall(*align(1) const fn (*[40]u8) callconv(.c) u64, "sol_get_clock_sysvar", &host_sol_get_clock_sysvar);

pub const sol_get_rent_sysvar: *align(1) const fn (*[24]u8) callconv(.c) u64 =
    Syscall(*align(1) const fn (*[24]u8) callconv(.c) u64, "sol_get_rent_sysvar", &host_sol_get_rent_sysvar);

pub const sol_get_epoch_schedule_sysvar: *align(1) const fn (*[40]u8) callconv(.c) u64 =
    Syscall(*align(1) const fn (*[40]u8) callconv(.c) u64, "sol_get_epoch_schedule_sysvar", &host_sol_get_epoch_schedule_sysvar);

pub const sol_get_last_restart_slot: *align(1) const fn (*[8]u8) callconv(.c) u64 =
    Syscall(*align(1) const fn (*[8]u8) callconv(.c) u64, "sol_get_last_restart_slot", &host_sol_get_last_restart_slot);

pub const sol_get_stack_height: *align(1) const fn () callconv(.c) u64 =
    Syscall(*align(1) const fn () callconv(.c) u64, "sol_get_stack_height", &host_sol_get_stack_height);

pub const sol_get_return_data: *align(1) const fn ([*]u8, u64, *[32]u8) callconv(.c) u64 =
    Syscall(*align(1) const fn ([*]u8, u64, *[32]u8) callconv(.c) u64, "sol_get_return_data", &host_sol_get_return_data);

pub const sol_set_return_data: *align(1) const fn ([*]const u8, u64) callconv(.c) void =
    Syscall(*align(1) const fn ([*]const u8, u64) callconv(.c) void, "sol_set_return_data", &host_sol_set_return_data);

pub const sol_remaining_compute_units: *align(1) const fn () callconv(.c) u64 =
    Syscall(*align(1) const fn () callconv(.c) u64, "sol_remaining_compute_units", &host_sol_remaining_compute_units);

pub const abort_: *align(1) const fn () callconv(.c) noreturn =
    Syscall(*align(1) const fn () callconv(.c) noreturn, "abort", &host_abort);

pub const sol_panic_: *align(1) const fn ([*]const u8, u64, u64, u64) callconv(.c) noreturn =
    Syscall(*align(1) const fn ([*]const u8, u64, u64, u64) callconv(.c) noreturn, "sol_panic_", &host_sol_panic_);

// =====================================================================
// Host-side shim implementations.
// =====================================================================

fn host_sol_log_(_: [*]const u8, _: u64) callconv(.c) void {}
fn host_sol_log_64_(_: u64, _: u64, _: u64, _: u64, _: u64) callconv(.c) void {}
fn host_sol_log_compute_units_() callconv(.c) void {}
fn host_sol_log_pubkey(_: *const [32]u8) callconv(.c) void {}
fn host_sol_log_data(_: [*]const SolBytes, _: u64) callconv(.c) void {}
fn host_sol_invoke_signed_c(
    _: *const InstructionC,
    _: [*]const AccountInfoC,
    _: u64,
    _: [*]const SignerSeedsC,
    _: u64,
) callconv(.c) u64 {
    return 1;
}
fn host_sol_create_program_address(_: [*]const SolBytes, _: u64, _: *const [32]u8, _: *[32]u8) callconv(.c) u64 {
    return 1;
}
fn host_sol_try_find_program_address(_: [*]const SolBytes, _: u64, _: *const [32]u8, _: *[32]u8, _: *u8) callconv(.c) u64 {
    return 1;
}
fn host_sol_sha256(_: [*]const SolBytes, _: u64, _: *[32]u8) callconv(.c) u64 {
    return 1;
}
fn host_sol_keccak256(_: [*]const SolBytes, _: u64, _: *[32]u8) callconv(.c) u64 {
    return 1;
}
fn host_sol_blake3(_: [*]const SolBytes, _: u64, _: *[32]u8) callconv(.c) u64 {
    return 1;
}
fn host_sol_memcpy_(dst: [*]u8, src: [*]const u8, n: u64) callconv(.c) void {
    @memcpy(dst[0..@intCast(n)], src[0..@intCast(n)]);
}
fn host_sol_memmove_(dst: [*]u8, src: [*]const u8, n: u64) callconv(.c) void {
    std.mem.copyForwards(u8, dst[0..@intCast(n)], src[0..@intCast(n)]);
}
fn host_sol_memcmp_(a: [*]const u8, b: [*]const u8, n: u64, out: *i32) callconv(.c) void {
    const order = std.mem.order(u8, a[0..@intCast(n)], b[0..@intCast(n)]);
    out.* = switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}
fn host_sol_memset_(dst: [*]u8, val: u8, n: u64) callconv(.c) void {
    @memset(dst[0..@intCast(n)], val);
}
fn host_sol_get_clock_sysvar(_: *[40]u8) callconv(.c) u64 {
    return 0;
}
fn host_sol_get_rent_sysvar(_: *[24]u8) callconv(.c) u64 {
    return 0;
}
fn host_sol_get_epoch_schedule_sysvar(_: *[40]u8) callconv(.c) u64 {
    return 0;
}
fn host_sol_get_last_restart_slot(_: *[8]u8) callconv(.c) u64 {
    return 0;
}
fn host_sol_get_stack_height() callconv(.c) u64 {
    return 1;
}
fn host_sol_get_return_data(_: [*]u8, _: u64, _: *[32]u8) callconv(.c) u64 {
    return 0;
}
fn host_sol_set_return_data(_: [*]const u8, _: u64) callconv(.c) void {}
fn host_sol_remaining_compute_units() callconv(.c) u64 {
    return 1_400_000;
}
fn host_abort() callconv(.c) noreturn {
    @panic("sol_abort");
}
fn host_sol_panic_(_: [*]const u8, _: u64, _: u64, _: u64) callconv(.c) noreturn {
    @panic("sol_panic_");
}

// =====================================================================
// Tests — verify murmur3_32 matches the canonical Solana hashes.
// =====================================================================

test "murmur3_32 of known syscall names" {
    // These hashes are documented in Zignocchio / Ziglana and match what the
    // Agave runtime's syscall registry computes for each name.
    try std.testing.expectEqual(@as(u32, 0x207559bd), murmur3_32("sol_log_"));
    try std.testing.expectEqual(@as(u32, 0xb6fc1a11), murmur3_32("abort"));
}

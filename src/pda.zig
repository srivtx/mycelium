//! Program-Derived Addresses (PDAs).
//!
//! A PDA is a 32-byte point that lies **off** the Ed25519 curve, derived from
//! a tuple `(seeds[], program_id, bump)`. Because it's off-curve, no private
//! key exists for it; the owning program signs for it instead, by passing
//! the same `(seeds[], bump)` back through a CPI's `signer_seeds` argument.
//!
//! This module exposes two operations:
//!
//!   * `createProgramAddress(seeds, program_id) -> Pubkey`
//!     Try to derive a PDA from EXACTLY the given seeds. Fails (returns
//!     `error.InvalidSeeds`) if the resulting point happens to land on the
//!     curve. The runtime does the SHA256 + curve check via syscall.
//!
//!   * `findProgramAddress(seeds, program_id) -> (Pubkey, u8)`
//!     Search for the largest `bump ∈ [0, 255]` such that
//!     `createProgramAddress(seeds ++ [bump], program_id)` succeeds. The
//!     runtime tries bumps `255, 254, …` from the top; in practice the first
//!     bump succeeds on most attempts so this is cheap, but for hot paths
//!     prefer storing the bump and using `createProgramAddress` with the
//!     stored bump appended as the final seed.
//!
//! Both operations are exposed by the Solana runtime as syscalls and have
//! Murmur3 hashes that our `core.syscalls` module already binds.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core/root.zig");

const Pubkey = core.Pubkey;
const SolBytes = core.syscalls.SolBytes;
const syscalls = core.syscalls;

const is_sbf = builtin.cpu.arch == .bpfel or builtin.cpu.arch == .bpfeb;

/// Maximum number of seeds the runtime accepts. Documented in
/// `solana_program::pubkey::MAX_SEEDS = 16` and matched here.
pub const MAX_SEEDS: usize = 16;

/// Maximum length of a single seed. `solana_program::pubkey::MAX_SEED_LEN = 32`.
pub const MAX_SEED_LEN: usize = 32;

/// Build a `SolBytes` array from a slice of byte-slice seeds. Validates the
/// per-seed length cap at runtime; on SBF we use a fixed-size stack array so
/// the caller doesn't allocate.
inline fn packSeeds(seeds: []const []const u8, out: *[MAX_SEEDS]SolBytes) !usize {
    if (seeds.len > MAX_SEEDS) return error.MaxSeedLengthExceeded;
    for (seeds, 0..) |s, i| {
        if (s.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;
        out[i] = .{ .addr = s.ptr, .len = s.len };
    }
    return seeds.len;
}

/// Derive a PDA from `(seeds, program_id)`. Errors with `InvalidSeeds` when
/// the resulting point lies on the curve.
pub fn createProgramAddress(seeds: []const []const u8, program_id: *const Pubkey) !Pubkey {
    var packed_seeds: [MAX_SEEDS]SolBytes = undefined;
    const n = try packSeeds(seeds, &packed_seeds);

    var out: Pubkey = undefined;
    const rc = syscalls.sol_create_program_address(
        &packed_seeds,
        @intCast(n),
        @ptrCast(program_id),
        @ptrCast(&out.bytes),
    );
    return if (rc == 0) out else error.InvalidSeeds;
}

/// Derive a PDA with an explicit bump byte appended to the seed list.
///
/// This is the fast path: a single SHA256 invocation, no curve-search loop.
/// Use this in hot handlers where you've stored the canonical bump (from a
/// prior `findProgramAddress`) in account state, or had the client compute
/// and pass it in the instruction data.
///
/// Cost: ~750 CU vs ~1.5K CU * (256 - bump) for `findProgramAddress`.
pub fn deriveWithBump(
    seeds: []const []const u8,
    bump: u8,
    program_id: *const Pubkey,
) !Pubkey {
    if (seeds.len + 1 > MAX_SEEDS) return error.MaxSeedLengthExceeded;
    var packed_seeds: [MAX_SEEDS]SolBytes = undefined;
    for (seeds, 0..) |s, i| {
        if (s.len > MAX_SEED_LEN) return error.MaxSeedLengthExceeded;
        packed_seeds[i] = .{ .addr = s.ptr, .len = s.len };
    }
    const bump_arr: [1]u8 = .{bump};
    packed_seeds[seeds.len] = .{ .addr = &bump_arr, .len = 1 };

    var out: Pubkey = undefined;
    const rc = syscalls.sol_create_program_address(
        &packed_seeds,
        @intCast(seeds.len + 1),
        @ptrCast(program_id),
        @ptrCast(&out.bytes),
    );
    return if (rc == 0) out else error.InvalidSeeds;
}

/// Convenience: derive `(seeds, bump)` and bail with `InvalidSeeds` unless it
/// equals `expected`. Common pattern for "verify the caller passed the
/// right PDA".
pub fn verifyDerivation(
    seeds: []const []const u8,
    bump: u8,
    program_id: *const Pubkey,
    expected: *const Pubkey,
) !void {
    const derived = try deriveWithBump(seeds, bump, program_id);
    if (!Pubkey.equals(&derived, expected)) return error.InvalidSeeds;
}

/// Find the canonical bump (the largest `u8` that yields an off-curve point)
/// for the given seed tuple. Returns the derived address and that bump.
///
/// For hot paths, store the bump from initialization and call
/// `createProgramAddress(seeds ++ &[_]u8{bump}, program_id)` instead — the
/// `find` form may try up to 255 bumps and costs a few thousand CUs.
pub fn findProgramAddress(seeds: []const []const u8, program_id: *const Pubkey) !struct { address: Pubkey, bump: u8 } {
    var packed_seeds: [MAX_SEEDS]SolBytes = undefined;
    const n = try packSeeds(seeds, &packed_seeds);

    var out: Pubkey = undefined;
    var bump: u8 = undefined;
    const rc = syscalls.sol_try_find_program_address(
        &packed_seeds,
        @intCast(n),
        @ptrCast(program_id),
        @ptrCast(&out.bytes),
        &bump,
    );
    return if (rc == 0) .{ .address = out, .bump = bump } else error.InvalidSeeds;
}

test "packSeeds rejects too-many seeds" {
    var out: [MAX_SEEDS]SolBytes = undefined;
    var seeds: [MAX_SEEDS + 1][]const u8 = undefined;
    for (&seeds) |*s| s.* = "x";
    try std.testing.expectError(error.MaxSeedLengthExceeded, packSeeds(&seeds, &out));
}

test "packSeeds rejects too-long seed" {
    var out: [MAX_SEEDS]SolBytes = undefined;
    const long: [MAX_SEED_LEN + 1]u8 = .{0} ** (MAX_SEED_LEN + 1);
    const seeds: []const []const u8 = &.{long[0..]};
    try std.testing.expectError(error.MaxSeedLengthExceeded, packSeeds(seeds, &out));
}

test "packSeeds happy path packs lengths and pointers" {
    var out: [MAX_SEEDS]SolBytes = undefined;
    const a: []const u8 = "hello";
    const b: []const u8 = "world!";
    const n = try packSeeds(&.{ a, b }, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 5), out[0].len);
    try std.testing.expectEqual(@as(u64, 6), out[1].len);
}

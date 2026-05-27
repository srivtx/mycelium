//! 32-byte Solana public key with comptime base58 support.
//!
//! On-chain, `Pubkey` is just `[32]u8`. We wrap it so that:
//!   - comparisons go through a single inlined helper (saves CUs vs `std.mem.eql`
//!     which loops byte-by-byte; we want four `u64` loads).
//!   - base58 decoding can run at comptime, so program-id literals are free.
//!
//! The base58 decoder is a faithful reimplementation of the Bitcoin / Solana
//! alphabet (`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`).
//! It is intentionally simple: O(n²) but n ≤ 44 and it only runs at comptime.

const std = @import("std");

pub const Pubkey = extern struct {
    bytes: [32]u8,

    pub const SIZE: usize = 32;
    pub const ZERO: Pubkey = .{ .bytes = .{0} ** 32 };

    /// Constant-time-ish equality. We compare 4×u64 chunks instead of 32 bytes
    /// to keep the SBPF cost low (4 loads + 4 cmps vs 32 of each). The Solana
    /// loader places the input buffer at a 16-byte-aligned MM_INPUT_START, but
    /// after the 1-byte dup marker each per-account record's `key` field sits
    /// at a 1-byte-aligned offset — so we deliberately accept `*align(1)`.
    pub inline fn equals(a: *const Pubkey, b: *const Pubkey) bool {
        const av: *align(1) const [4]u64 = @ptrCast(a);
        const bv: *align(1) const [4]u64 = @ptrCast(b);
        return av[0] == bv[0] and av[1] == bv[1] and av[2] == bv[2] and av[3] == bv[3];
    }

    pub inline fn isZero(self: *const Pubkey) bool {
        const av: *align(1) const [4]u64 = @ptrCast(self);
        return av[0] == 0 and av[1] == 0 and av[2] == 0 and av[3] == 0;
    }

    /// Compile-time base58 → 32 bytes. Use this for program-id constants:
    ///
    ///     const ID: Pubkey = Pubkey.fromBase58Comptime("11111111111111111111111111111111");
    pub fn fromBase58Comptime(comptime s: []const u8) Pubkey {
        @setEvalBranchQuota(100_000);
        return decodeBase58Const(s);
    }

    /// Runtime base58 decode. Returns `error.InvalidPubkey` on bad input.
    pub fn fromBase58(s: []const u8) !Pubkey {
        return decodeBase58Runtime(s);
    }
};

// =====================================================================
// Well-known program / sysvar IDs.
//
// These are baked in at compile time via the base58 decoder so the program
// pays zero runtime cost. They live next to `Pubkey` so callers can write
// `Pubkey.SYSTEM_PROGRAM_ID` consistently — but Zig disallows decls that
// reference the enclosing struct after its definition, so they sit at file
// scope. Re-exported from `mycelium.root` for convenience.
// =====================================================================

/// The System Program (`11111111111111111111111111111111`).
pub const SYSTEM_PROGRAM_ID: Pubkey = Pubkey.fromBase58Comptime("11111111111111111111111111111111");

/// Sysvar: rent. `SysvarRent111111111111111111111111111111111`.
pub const SYSVAR_RENT_ID: Pubkey = Pubkey.fromBase58Comptime("SysvarRent111111111111111111111111111111111");

/// Sysvar: clock. `SysvarC1ock11111111111111111111111111111111`.
pub const SYSVAR_CLOCK_ID: Pubkey = Pubkey.fromBase58Comptime("SysvarC1ock11111111111111111111111111111111");

/// Sysvar: instructions. `Sysvar1nstructions1111111111111111111111111`.
pub const SYSVAR_INSTRUCTIONS_ID: Pubkey = Pubkey.fromBase58Comptime("Sysvar1nstructions1111111111111111111111111");

test "SYSTEM_PROGRAM_ID decodes to all-zero bytes" {
    var all_zero = true;
    for (SYSTEM_PROGRAM_ID.bytes) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try std.testing.expect(all_zero);
}

const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

fn b58Index(c: u8) ?u8 {
    inline for (ALPHABET, 0..) |a, i| {
        if (a == c) return @intCast(i);
    }
    return null;
}

fn decodeBase58Const(comptime s: []const u8) Pubkey {
    var bytes: [32]u8 = .{0} ** 32;
    // Leading '1's are zero bytes.
    var zero_count: usize = 0;
    while (zero_count < s.len and s[zero_count] == '1') : (zero_count += 1) {}

    // Decode big-num: bytes[] = base58(s)
    var length: usize = 0;
    for (s) |c| {
        const v = b58Index(c) orelse @compileError("invalid base58 character in pubkey literal");
        var carry: u32 = @intCast(v);
        var j: usize = 0;
        while (j < length or carry != 0) : (j += 1) {
            if (j >= 32) @compileError("base58 literal decodes to more than 32 bytes");
            const idx = 31 - j;
            const x: u32 = @as(u32, bytes[idx]) * 58 + carry;
            bytes[idx] = @intCast(x & 0xff);
            carry = x >> 8;
            if (j >= length and bytes[idx] != 0) length = j + 1;
        }
    }

    // Pad with leading zeros from the '1' prefix.
    if (zero_count + length > 32) @compileError("base58 literal too long for Pubkey");
    // Bytes are already aligned to the right; that's what we want for a 32-byte key.
    return .{ .bytes = bytes };
}

fn decodeBase58Runtime(s: []const u8) !Pubkey {
    var bytes: [32]u8 = .{0} ** 32;
    var length: usize = 0;
    for (s) |c| {
        const v = b58Index(c) orelse return error.InvalidPubkey;
        var carry: u32 = @intCast(v);
        var j: usize = 0;
        while (j < length or carry != 0) : (j += 1) {
            if (j >= 32) return error.InvalidPubkey;
            const idx = 31 - j;
            const x: u32 = @as(u32, bytes[idx]) * 58 + carry;
            bytes[idx] = @intCast(x & 0xff);
            carry = x >> 8;
            if (j >= length and bytes[idx] != 0) length = j + 1;
        }
    }
    return .{ .bytes = bytes };
}

// ----- tests -----------------------------------------------------------------

test "Pubkey.equals identical" {
    var a: Pubkey = .{ .bytes = .{ 1, 2, 3 } ++ ([_]u8{0} ** 29) };
    var b: Pubkey = .{ .bytes = .{ 1, 2, 3 } ++ ([_]u8{0} ** 29) };
    try std.testing.expect(Pubkey.equals(&a, &b));
}

test "Pubkey.equals differing" {
    var a: Pubkey = .{ .bytes = .{0} ** 32 };
    var b: Pubkey = .{ .bytes = .{1} ++ ([_]u8{0} ** 31) };
    try std.testing.expect(!Pubkey.equals(&a, &b));
}

test "fromBase58 system program" {
    // The System program id is all-zeros, base58 = "11111111111111111111111111111111".
    const sys = comptime Pubkey.fromBase58Comptime("11111111111111111111111111111111");
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &sys.bytes);
}

test "fromBase58 runtime token program" {
    const token = try Pubkey.fromBase58("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
    // First byte is 6 ('B' in Solana lore), but we don't hardcode — round-trip via a known canonical bytestring:
    const expected: [32]u8 = .{
        0x06, 0xdd, 0xf6, 0xe1, 0xd7, 0x65, 0xa1, 0x93, 0xd9, 0xcb, 0xe1, 0x46, 0xce, 0xeb, 0x79, 0xac,
        0x1c, 0xb4, 0x85, 0xed, 0x5f, 0x5b, 0x37, 0x91, 0x3a, 0x8c, 0xf5, 0x85, 0x7e, 0xff, 0x00, 0xa9,
    };
    try std.testing.expectEqualSlices(u8, &expected, &token.bytes);
}

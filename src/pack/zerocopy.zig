//! Comptime zero-copy view codec.
//!
//! Given an `extern struct T`, produces a tiny set of helpers that interpret
//! a byte slice as a `*T` (or `*const T`) without copying or allocating.
//!
//! Constraints (checked at comptime):
//!   - `T` must be `extern struct` or `packed struct`, so its layout is stable.
//!   - All fields must be themselves byte-layout-stable (integers, packed/
//!     extern structs, fixed-size arrays of such).
//!
//! Runtime cost:
//!   - `load`/`loadConst`: one bounds check + one pointer cast.
//!   - `size`: comptime constant.
//!
//! This is the recommended codec for on-chain account data.

const std = @import("std");

pub fn ZeroCopy(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("ZeroCopy requires a struct type");
    const layout = info.@"struct".layout;
    if (layout != .@"extern" and layout != .@"packed") {
        @compileError("ZeroCopy requires extern or packed struct layout, got: " ++ @tagName(layout));
    }

    return struct {
        pub const SIZE: usize = @sizeOf(T);

        /// Borrow `data` as a `*align(1) T`. `data.len` must be >= `SIZE`.
        /// The result is `align(1)` because the data region typically doesn't
        /// satisfy `T`'s natural alignment; BPF and arm64 both allow
        /// misaligned access.
        pub fn load(data: []u8) error{AccountDataTooSmall}!*align(1) T {
            if (data.len < SIZE) return error.AccountDataTooSmall;
            return @ptrCast(data.ptr);
        }

        pub fn loadConst(data: []const u8) error{AccountDataTooSmall}!*align(1) const T {
            if (data.len < SIZE) return error.AccountDataTooSmall;
            return @ptrCast(data.ptr);
        }

        pub inline fn loadUnchecked(data: []u8) *align(1) T {
            return @ptrCast(data.ptr);
        }

        pub inline fn loadConstUnchecked(data: []const u8) *align(1) const T {
            return @ptrCast(data.ptr);
        }
    };
}

test "ZeroCopy round-trips a simple struct" {
    // Note: `extern struct` lays out fields in declaration order, padding each
    // to its natural alignment. The size is rounded up to the alignment of
    // the largest field. Here that means trailing pad after `bump`, so 48 not 41.
    const Counter = extern struct {
        owner: [32]u8,
        value: u64,
        bump: u8,
    };
    const Codec = ZeroCopy(Counter);
    try std.testing.expectEqual(@as(usize, 48), Codec.SIZE);

    var buf: [Codec.SIZE]u8 = .{0} ** Codec.SIZE;
    const c = try Codec.load(&buf);
    c.value = 0xDEADBEEFCAFEBABE;
    c.bump = 254;
    for (0..32) |i| c.owner[i] = @intCast(i);

    const c2 = try Codec.loadConst(&buf);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEFCAFEBABE), c2.value);
    try std.testing.expectEqual(@as(u8, 254), c2.bump);
    try std.testing.expectEqual(@as(u8, 7), c2.owner[7]);
}

test "ZeroCopy with packed struct rounds up to power-of-2 backing integer" {
    // Zig `packed struct` is bit-packed and stored in the smallest power-of-two
    // unsigned integer that fits. 72 bits -> u128 -> 16 bytes. If you want
    // arbitrary byte-tight layout, write an `extern struct` whose fields are
    // small enough to avoid padding (or use `[N]u8` byte arrays explicitly).
    const PackedCounter = packed struct {
        value: u64,
        bump: u8,
    };
    const Codec = ZeroCopy(PackedCounter);
    try std.testing.expectEqual(@as(usize, 16), Codec.SIZE);
}

test "ZeroCopy extern struct with byte-array fields is tight" {
    // Real Solana account layouts that need exact byte size should use
    // byte arrays for sub-word fields, mirroring the C SDK convention.
    const TightCounter = extern struct {
        value: [8]u8,
        bump: u8,
    };
    const Codec = ZeroCopy(TightCounter);
    try std.testing.expectEqual(@as(usize, 9), Codec.SIZE);
}

test "ZeroCopy rejects short buffers" {
    const State = extern struct { x: u64, y: u64 };
    const Codec = ZeroCopy(State);
    var buf: [4]u8 = .{0} ** 4;
    try std.testing.expectError(error.AccountDataTooSmall, Codec.load(&buf));
}

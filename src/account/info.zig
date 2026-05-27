//! Zero-copy AccountInfo view.
//!
//! The Solana loader passes the program a single contiguous buffer ("input").
//! For each account in the call, that buffer contains a record laid out as
//! (offsets measured from the dup byte at offset 0):
//!
//!   offset  size   field
//!   ------  -----  -----
//!     0      1     dup_byte               (0xFF if unique, else original index)
//!     1      1     is_signer
//!     2      1     is_writable
//!     3      1     executable
//!     4      4     original_data_len (u32) — reserved/padding
//!     8     32     key
//!    40     32     owner
//!    72      8     lamports (u64)
//!    80      8     data_len (u64)
//!    88     N      data
//!   88+N    K      alignment padding to 8B
//!   88+N+K 10240   realloc padding (MAX_PERMITTED_DATA_INCREASE)
//!   ...     8     rent_epoch (u64)
//!
//! `AccountInfo` is a thin pointer to **offset 1** of this record (i.e. past
//! the dup byte). All field offsets below are therefore expressed relative to
//! that "is_signer" position, which is the dup-byte offset minus 1:
//!
//!     record byte    relative to is_signer
//!     -----------    ---------------------
//!         8 (key)              7
//!        40 (owner)           39
//!        72 (lamports)        71
//!        80 (data_len)        79
//!        88 (data)            87
//!
//! Every accessor is a single inline pointer-arithmetic + load, so the
//! generated code is just that load.
//!
//! For duplicate accounts, `AccountInfo` holds the *original's* base pointer;
//! the duplicate's 7-byte padding slot is consumed only by the parser.

const std = @import("std");
const Pubkey = @import("../core/pubkey.zig").Pubkey;

/// Offsets relative to the byte *after* the dup marker (= `is_signer`'s byte).
pub const FieldOffset = struct {
    pub const is_signer: usize = 0;
    pub const is_writable: usize = 1;
    pub const executable: usize = 2;
    /// 4-byte slot at +3..+7. The Agave runtime uses this as `original_data_len`
    /// when `account-resize` is active, otherwise as zero padding.
    pub const original_data_len: usize = 3;
    pub const key: usize = 7;
    pub const owner: usize = 39;
    pub const lamports: usize = 71;
    pub const data_len: usize = 79;
    pub const data: usize = 87;
};

pub const AccountInfo = struct {
    /// Pointer to `is_signer`'s byte (i.e. one past the dup marker).
    /// For duplicates, this is the original account's `raw`.
    raw: [*]u8,

    pub inline fn isSigner(self: AccountInfo) bool {
        return self.raw[FieldOffset.is_signer] != 0;
    }

    pub inline fn isWritable(self: AccountInfo) bool {
        return self.raw[FieldOffset.is_writable] != 0;
    }

    pub inline fn executable(self: AccountInfo) bool {
        return self.raw[FieldOffset.executable] != 0;
    }

    pub inline fn key(self: AccountInfo) *const Pubkey {
        return @ptrCast(self.raw + FieldOffset.key);
    }

    pub inline fn owner(self: AccountInfo) *const Pubkey {
        return @ptrCast(self.raw + FieldOffset.owner);
    }

    /// **Mutable**. Lamport changes are reflected in the account post-execution.
    /// Returned as `*align(1)` because the account record's lamports field
    /// isn't guaranteed to be 8-byte-aligned within the input buffer; BPF
    /// allows misaligned loads and arm64 does as well.
    pub inline fn lamports(self: AccountInfo) *align(1) u64 {
        return @ptrCast(self.raw + FieldOffset.lamports);
    }

    pub inline fn dataLen(self: AccountInfo) usize {
        const ptr: *align(1) const u64 = @ptrCast(self.raw + FieldOffset.data_len);
        return @intCast(ptr.*);
    }

    pub inline fn dataLenPtr(self: AccountInfo) *align(1) u64 {
        return @ptrCast(self.raw + FieldOffset.data_len);
    }

    /// Mutable slice into the account's data region. Length is `dataLen()`.
    pub inline fn data(self: AccountInfo) []u8 {
        const len = self.dataLen();
        return (self.raw + FieldOffset.data)[0..len];
    }

    /// Cast `data()` to a typed `*T` view. Requires `T` to be an `extern struct`
    /// whose `@sizeOf` is <= `dataLen()`. The result is `*align(1) T` because
    /// the data region may not satisfy `T`'s natural alignment.
    pub inline fn dataAs(self: AccountInfo, comptime T: type) !*align(1) T {
        if (self.dataLen() < @sizeOf(T)) return error.AccountDataTooSmall;
        return @ptrCast(self.raw + FieldOffset.data);
    }

    pub inline fn dataAsConst(self: AccountInfo, comptime T: type) !*align(1) const T {
        if (self.dataLen() < @sizeOf(T)) return error.AccountDataTooSmall;
        return @ptrCast(self.raw + FieldOffset.data);
    }

    /// Realloc up to `MAX_PERMITTED_DATA_INCREASE` bytes beyond the original
    /// size. The loader pre-allocated that buffer so the underlying memory is
    /// already there; we just bump `data_len`.
    pub fn realloc(self: AccountInfo, new_len: usize, zero_init: bool) !void {
        const abi = @import("../core/abi.zig");
        const old_len = self.dataLen();
        // Reallocating to a *smaller* length is always fine.
        if (new_len > old_len) {
            const original_data_len_ptr: *align(1) const u32 = @ptrCast(self.raw + FieldOffset.original_data_len);
            const original = @as(usize, @intCast(original_data_len_ptr.*));
            // Pinocchio matches Anchor's rule: cumulative growth across the whole
            // tx is capped by `MAX_PERMITTED_DATA_INCREASE` relative to the
            // *original* account length the loader recorded.
            if (new_len > original + abi.MAX_PERMITTED_DATA_INCREASE) return error.InvalidRealloc;
        }
        self.dataLenPtr().* = @intCast(new_len);
        if (zero_init and new_len > old_len) {
            @memset((self.raw + FieldOffset.data + old_len)[0 .. new_len - old_len], 0);
        }
    }
};

// ----- tests -----------------------------------------------------------------

test "AccountInfo reads fields from a manufactured record" {
    // Manufacture an unaligned-after-dup-byte record of the kind the loader hands us.
    // The buffer must be aligned for u64 reads.
    var buf: [4096]u8 align(16) = undefined;
    @memset(&buf, 0);

    // Layout from offset 0 (which is "is_signer" — no dup byte in this test).
    buf[FieldOffset.is_signer] = 1;
    buf[FieldOffset.is_writable] = 1;
    buf[FieldOffset.executable] = 0;
    // key bytes 0..32
    for (0..32) |i| buf[FieldOffset.key + i] = @intCast(i);
    // owner: all 0xAB
    for (0..32) |i| buf[FieldOffset.owner + i] = 0xAB;
    // lamports = 1_000_000
    std.mem.writeInt(u64, buf[FieldOffset.lamports..][0..8], 1_000_000, .little);
    // data_len = 4, data = [0xDE, 0xAD, 0xBE, 0xEF]
    std.mem.writeInt(u64, buf[FieldOffset.data_len..][0..8], 4, .little);
    buf[FieldOffset.data + 0] = 0xDE;
    buf[FieldOffset.data + 1] = 0xAD;
    buf[FieldOffset.data + 2] = 0xBE;
    buf[FieldOffset.data + 3] = 0xEF;

    const info: AccountInfo = .{ .raw = &buf };
    try std.testing.expect(info.isSigner());
    try std.testing.expect(info.isWritable());
    try std.testing.expect(!info.executable());
    try std.testing.expectEqual(@as(u64, 1_000_000), info.lamports().*);
    try std.testing.expectEqual(@as(usize, 4), info.dataLen());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, info.data());
    try std.testing.expectEqual(@as(u8, 0xAB), info.owner().bytes[0]);
    try std.testing.expectEqual(@as(u8, 5), info.key().bytes[5]);
}

//! Lamport arithmetic on program-owned accounts.
//!
//! When a program owns an account (it's the value in the `owner` field), it
//! can mutate that account's `lamports` slot directly — no CPI needed. The
//! runtime enforces only one invariant on commit: the sum of all writable
//! accounts' lamports must be unchanged across the instruction. As long as
//! we move the same number of lamports OUT of one and INTO another (both
//! writable, both program-owned), the runtime accepts the change.
//!
//! `move` performs that paired mutation with overflow / underflow checks.
//! `take` reduces just one side (useful for closing accounts — the lamports
//! go to a recipient writable account).
//!
//! For transfers from accounts your program does NOT own — typically a user
//! wallet — you must CPI into the System Program (`programs.system.transfer`)
//! because System Program is the only owner that can give signing
//! permission for those funds.

const std = @import("std");
const AccountInfo = @import("info.zig").AccountInfo;
const ProgramError = @import("../core/error.zig").ProgramError;

/// Move `amount` lamports from `src` to `dst`. Both must be writable AND
/// owned by the calling program. Caller-side validation is left to the
/// caller; we only check for arithmetic over/underflow here.
pub fn move(src: AccountInfo, dst: AccountInfo, amount: u64) ProgramError!void {
    if (amount == 0) return;
    const src_ptr = src.lamports();
    const dst_ptr = dst.lamports();

    const new_src, const underflow = @subWithOverflow(src_ptr.*, amount);
    if (underflow != 0) return error.InsufficientFunds;

    const new_dst, const overflow = @addWithOverflow(dst_ptr.*, amount);
    if (overflow != 0) return error.ArithmeticOverflow;

    src_ptr.* = new_src;
    dst_ptr.* = new_dst;
}

/// Withdraw `amount` from a single program-owned account. Useful when the
/// destination accounting happens off-account (e.g. closing into a wallet
/// via System Program CPI in the same instruction). Prefer `move` if you
/// can — it documents the source/sink pairing.
pub fn debit(acc: AccountInfo, amount: u64) ProgramError!void {
    if (amount == 0) return;
    const p = acc.lamports();
    const new_val, const underflow = @subWithOverflow(p.*, amount);
    if (underflow != 0) return error.InsufficientFunds;
    p.* = new_val;
}

/// Add `amount` to a writable account's lamports.
pub fn credit(acc: AccountInfo, amount: u64) ProgramError!void {
    if (amount == 0) return;
    const p = acc.lamports();
    const new_val, const overflow = @addWithOverflow(p.*, amount);
    if (overflow != 0) return error.ArithmeticOverflow;
    p.* = new_val;
}

/// Close a program-owned account: drain all its lamports into `recipient`,
/// then zero its data. The runtime garbage-collects accounts whose lamports
/// hit zero at commit time, so the account effectively disappears.
///
/// Both `acc` and `recipient` must be writable. `acc` must be owned by the
/// calling program (we don't re-check here — caller is responsible).
///
/// Note we do NOT reassign ownership back to the System Program; that would
/// require a CPI. The lamports-to-zero deallocation is enough for the
/// runtime to forget the account.
pub fn close(acc: AccountInfo, recipient: AccountInfo) ProgramError!void {
    const balance = acc.lamports().*;
    try move(acc, recipient, balance);
    @memset(acc.data(), 0);
}

test "close drains and zeros the data" {
    var src_buf: [256]u8 align(16) = undefined;
    var dst_buf: [256]u8 align(16) = undefined;
    const src = makeInfo(&src_buf, false, true, 5_000);
    const dst = makeInfo(&dst_buf, false, true, 1_000);
    // give src 16 bytes of nonzero data
    std.mem.writeInt(u64, src_buf[FieldOffset.data_len..][0..8], 16, .little);
    for (0..16) |i| src_buf[FieldOffset.data + i] = 0xAA;

    try close(src, dst);
    try std.testing.expectEqual(@as(u64, 0), src.lamports().*);
    try std.testing.expectEqual(@as(u64, 6_000), dst.lamports().*);
    for (src.data()) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

// =====================================================================
// Tests — drive against manufactured AccountInfo records.
// =====================================================================

const FieldOffset = @import("info.zig").FieldOffset;

fn makeInfo(buf: *[256]u8, signer: bool, writable: bool, lamports: u64) AccountInfo {
    @memset(buf, 0);
    buf[FieldOffset.is_signer] = if (signer) 1 else 0;
    buf[FieldOffset.is_writable] = if (writable) 1 else 0;
    std.mem.writeInt(u64, buf[FieldOffset.lamports..][0..8], lamports, .little);
    return .{ .raw = buf };
}

test "move debits source and credits destination" {
    var src_buf: [256]u8 align(16) = undefined;
    var dst_buf: [256]u8 align(16) = undefined;
    const src = makeInfo(&src_buf, false, true, 1_000);
    const dst = makeInfo(&dst_buf, false, true, 500);

    try move(src, dst, 250);
    try std.testing.expectEqual(@as(u64, 750), src.lamports().*);
    try std.testing.expectEqual(@as(u64, 750), dst.lamports().*);
}

test "move zero is a no-op" {
    var src_buf: [256]u8 align(16) = undefined;
    var dst_buf: [256]u8 align(16) = undefined;
    const src = makeInfo(&src_buf, false, true, 100);
    const dst = makeInfo(&dst_buf, false, true, 200);

    try move(src, dst, 0);
    try std.testing.expectEqual(@as(u64, 100), src.lamports().*);
    try std.testing.expectEqual(@as(u64, 200), dst.lamports().*);
}

test "move underflow rejects the transfer" {
    var src_buf: [256]u8 align(16) = undefined;
    var dst_buf: [256]u8 align(16) = undefined;
    const src = makeInfo(&src_buf, false, true, 100);
    const dst = makeInfo(&dst_buf, false, true, 0);

    try std.testing.expectError(error.InsufficientFunds, move(src, dst, 101));
    // Source and destination must be unchanged after rejection.
    try std.testing.expectEqual(@as(u64, 100), src.lamports().*);
    try std.testing.expectEqual(@as(u64, 0), dst.lamports().*);
}

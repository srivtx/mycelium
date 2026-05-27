//! Account-validation primitives. Capability-based, composable, no macros.
//!
//! Every check is a free function that takes an `AccountInfo` (and any extra
//! context) and returns `!void`. They are designed to be readable in a chain:
//!
//!     try validate.mustBeSigner(payer);
//!     try validate.mustBeOwnedBy(state, &program_id);
//!     try validate.mustBeWritable(state);

const std = @import("std");
const Pubkey = @import("../core/pubkey.zig").Pubkey;
const ProgramError = @import("../core/error.zig").ProgramError;
const AccountInfo = @import("info.zig").AccountInfo;

pub fn mustBeSigner(acc: AccountInfo) ProgramError!void {
    if (!acc.isSigner()) return error.MissingRequiredSignature;
}

pub fn mustBeWritable(acc: AccountInfo) ProgramError!void {
    if (!acc.isWritable()) return error.Immutable;
}

pub fn mustBeOwnedBy(acc: AccountInfo, expected: *const Pubkey) ProgramError!void {
    if (!Pubkey.equals(acc.owner(), expected)) return error.IllegalOwner;
}

pub fn mustHaveKey(acc: AccountInfo, expected: *const Pubkey) ProgramError!void {
    if (!Pubkey.equals(acc.key(), expected)) return error.InvalidArgument;
}

pub fn mustBeExecutable(acc: AccountInfo) ProgramError!void {
    if (!acc.executable()) return error.InvalidAccountData;
}

pub fn mustHaveMinLamports(acc: AccountInfo, min: u64) ProgramError!void {
    if (acc.lamports().* < min) return error.InsufficientFunds;
}

pub fn mustHaveDataSize(acc: AccountInfo, expected: usize) ProgramError!void {
    if (acc.dataLen() != expected) return error.AccountDataTooSmall;
}

pub fn mustHaveAtLeastDataSize(acc: AccountInfo, min: usize) ProgramError!void {
    if (acc.dataLen() < min) return error.AccountDataTooSmall;
}

/// "Empty" — data is zero-length. Useful when the loader hands you an account
/// that the System Program just `create_account`'d for you (which is the
/// only legitimate empty-data account this program can see for its own use).
///
/// NOTE: do NOT additionally check `lamports == 0`. A freshly-created
/// rent-exempt account has non-zero lamports by definition. To detect
/// "already initialized" use a discriminator byte in your account data
/// (see `examples/counter` for the pattern).
pub fn mustBeEmpty(acc: AccountInfo) ProgramError!void {
    if (acc.dataLen() != 0) return error.AccountAlreadyInitialized;
}

/// Verify the account is the System Program (`11111111111111111111111111111111`).
pub fn mustBeSystemProgram(acc: AccountInfo) ProgramError!void {
    const Pubkey_mod = @import("../core/pubkey.zig");
    if (!Pubkey.equals(acc.key(), &Pubkey_mod.SYSTEM_PROGRAM_ID)) return error.IncorrectProgramId;
}

test "mustBeSigner gates on the flag" {
    var buf: [256]u8 align(16) = undefined;
    @memset(&buf, 0);
    buf[0] = 1; // is_signer
    const info: AccountInfo = .{ .raw = &buf };
    try mustBeSigner(info);

    buf[0] = 0;
    try std.testing.expectError(error.MissingRequiredSignature, mustBeSigner(info));
}

test "mustBeOwnedBy checks equality" {
    const info_mod = @import("info.zig");
    var buf: [256]u8 align(16) = undefined;
    @memset(&buf, 0);
    for (0..32) |i| buf[info_mod.FieldOffset.owner + i] = @intCast(i); // owner = 0..31
    const info: AccountInfo = .{ .raw = &buf };

    var matching: Pubkey = undefined;
    for (0..32) |i| matching.bytes[i] = @intCast(i);
    try mustBeOwnedBy(info, &matching);

    var wrong: Pubkey = .{ .bytes = .{0} ** 32 };
    try std.testing.expectError(error.IllegalOwner, mustBeOwnedBy(info, &wrong));
}

//! Solana program error model.
//!
//! On the wire an error is `u64`. The encoding (from
//! `solana_program_error::ProgramError`) is:
//!
//!   - `0`                  : success
//!   - `N << 32`            : builtin N (N >= 1, includes `CUSTOM_ZERO = 1 << 32`)
//!   - `code` (low 32 bits) : `Custom(code)` for `code != 0`
//!
//! So `Custom(0)` is the special value `1 << 32` (`CUSTOM_ZERO`), and any other
//! custom code is the bare `u32` zero-extended. Anything that does not match a
//! builtin sentinel decodes back to `Custom(low_32_bits)`.
//!
//! In Zig source we use a regular error set + a per-handler `u32` custom code,
//! since Zig's error union (`!void`) is the natural shape.

const std = @import("std");

pub const ProgramError = error{
    Custom,
    InvalidArgument,
    InvalidInstructionData,
    InvalidAccountData,
    AccountDataTooSmall,
    InsufficientFunds,
    IncorrectProgramId,
    MissingRequiredSignature,
    AccountAlreadyInitialized,
    UninitializedAccount,
    NotEnoughAccountKeys,
    AccountBorrowFailed,
    MaxSeedLengthExceeded,
    InvalidSeeds,
    BorshIoError,
    AccountNotRentExempt,
    UnsupportedSysvar,
    IllegalOwner,
    MaxAccountsDataAllocationsExceeded,
    InvalidRealloc,
    MaxInstructionTraceLengthExceeded,
    BuiltinProgramsMustConsumeComputeUnits,
    InvalidAccountOwner,
    ArithmeticOverflow,
    Immutable,
    IncorrectAuthority,
};

pub const ProgramResult = ProgramError!void;

pub const CUSTOM_ZERO: u64 = @as(u64, 1) << 32;

pub fn errorToU64(err: ProgramError, custom_code: u32) u64 {
    return switch (err) {
        // Canonical wire format: Custom(0) is the sentinel `CUSTOM_ZERO`,
        // every other custom code is the bare u32 zero-extended.
        error.Custom => if (custom_code == 0) CUSTOM_ZERO else @as(u64, custom_code),
        error.InvalidArgument => @as(u64, 2) << 32,
        error.InvalidInstructionData => @as(u64, 3) << 32,
        error.InvalidAccountData => @as(u64, 4) << 32,
        error.AccountDataTooSmall => @as(u64, 5) << 32,
        error.InsufficientFunds => @as(u64, 6) << 32,
        error.IncorrectProgramId => @as(u64, 7) << 32,
        error.MissingRequiredSignature => @as(u64, 8) << 32,
        error.AccountAlreadyInitialized => @as(u64, 9) << 32,
        error.UninitializedAccount => @as(u64, 10) << 32,
        error.NotEnoughAccountKeys => @as(u64, 11) << 32,
        error.AccountBorrowFailed => @as(u64, 12) << 32,
        error.MaxSeedLengthExceeded => @as(u64, 13) << 32,
        error.InvalidSeeds => @as(u64, 14) << 32,
        error.BorshIoError => @as(u64, 15) << 32,
        error.AccountNotRentExempt => @as(u64, 16) << 32,
        error.UnsupportedSysvar => @as(u64, 17) << 32,
        error.IllegalOwner => @as(u64, 18) << 32,
        error.MaxAccountsDataAllocationsExceeded => @as(u64, 19) << 32,
        error.InvalidRealloc => @as(u64, 20) << 32,
        error.MaxInstructionTraceLengthExceeded => @as(u64, 21) << 32,
        error.BuiltinProgramsMustConsumeComputeUnits => @as(u64, 22) << 32,
        error.InvalidAccountOwner => @as(u64, 23) << 32,
        error.ArithmeticOverflow => @as(u64, 24) << 32,
        error.Immutable => @as(u64, 25) << 32,
        error.IncorrectAuthority => @as(u64, 26) << 32,
    };
}

test "InvalidArgument round-trips" {
    try std.testing.expectEqual(@as(u64, 2) << 32, errorToU64(error.InvalidArgument, 0));
}

test "Custom(0) becomes CUSTOM_ZERO" {
    try std.testing.expectEqual(CUSTOM_ZERO, errorToU64(error.Custom, 0));
}

test "Custom(N) for N > 0 is just N (zero-extended)" {
    try std.testing.expectEqual(@as(u64, 0xdead_beef), errorToU64(error.Custom, 0xdead_beef));
    try std.testing.expectEqual(@as(u64, 1), errorToU64(error.Custom, 1));
}

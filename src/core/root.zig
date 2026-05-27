//! mycelium.core — raw Solana ABI primitives.
//!
//! Everything in this module is `extern`/`packed` where it matters for ABI
//! and has no runtime cost beyond what the source explicitly shows.

const std = @import("std");

pub const pubkey = @import("pubkey.zig");
pub const errors = @import("error.zig");
pub const abi = @import("abi.zig");
pub const syscalls = @import("syscalls.zig");
pub const entrypoint = @import("entrypoint.zig");

pub const Pubkey = pubkey.Pubkey;
pub const ProgramError = errors.ProgramError;
pub const ProgramResult = errors.ProgramResult;

// Re-exports of the well-known IDs from `pubkey.zig`.
pub const SYSTEM_PROGRAM_ID = pubkey.SYSTEM_PROGRAM_ID;
pub const SYSVAR_RENT_ID = pubkey.SYSVAR_RENT_ID;
pub const SYSVAR_CLOCK_ID = pubkey.SYSVAR_CLOCK_ID;
pub const SYSVAR_INSTRUCTIONS_ID = pubkey.SYSVAR_INSTRUCTIONS_ID;

test {
    std.testing.refAllDecls(@This());
}

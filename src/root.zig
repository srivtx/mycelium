//! mycelium — a systems-oriented Solana program framework in Zig.
//!
//! Underground, networked, foundational. Programs grow from a thin
//! comptime substrate that knows the ABI and stays out of the way at
//! runtime. No macros, no proc-macros, no runtime reflection — every
//! check lives where you can see it.
//!
//! Surface layout:
//!   - `core`      : raw ABI types, syscalls, errors, entrypoint scaffolding
//!   - `account`   : zero-copy AccountInfo + validation primitives
//!   - `pack`      : comptime serialization codegen
//!   - `pda`       : PDA derivation (syscall + native)
//!   - `cpi`       : Cross-program invocation builder
//!   - `dispatch`  : Comptime instruction dispatch from `union(enum)`
//!   - `testing`   : Pure-Zig mock execution context

const std = @import("std");

pub const core = @import("core/root.zig");
pub const account = @import("account/root.zig");
pub const pack = @import("pack/root.zig");
pub const dispatch = @import("dispatch.zig");
pub const pda = @import("pda.zig");
pub const cpi = @import("cpi.zig");
pub const programs = @import("programs/root.zig");
pub const accounts = @import("accounts.zig");
pub const framework = @import("framework.zig");

// Frequently-used re-exports.
pub const Pubkey = core.Pubkey;
pub const AccountInfo = account.AccountInfo;
pub const ProgramError = core.ProgramError;
pub const ProgramResult = core.ProgramResult;
pub const ExecutionContext = core.entrypoint.ExecutionContext;
pub const validate = account.validate;
pub const lamports = account.lamports;

/// Pointer-to-const ExecutionContext. The type every handler takes for its
/// first parameter; aliased here so handler signatures don't have to spell
/// `*const mycelium.ExecutionContext` in full each time.
pub const Ctx = *const ExecutionContext;

/// Compile-time padding helper. Use as a field type in `extern struct`s to
/// reserve N bytes of zero padding without the ugly `[N]u8 = .{0} ** N`
/// literal.
///
///     pub const State = extern struct {
///         x: u64,
///         flag: u8,
///         _pad: mycelium.Pad(7) = .{},   // brings the struct up to 16 bytes
///     };
pub fn Pad(comptime n: usize) type {
    return extern struct {
        bytes: [n]u8 = .{0} ** n,
    };
}

/// One-call program-and-entrypoint declaration. Use at the bottom of a
/// program file inside a `comptime` block:
///
///     comptime {
///         mycelium.entrypoint(.{
///             .instruction = Instruction,
///             .handlers = .{ .initialize = init, .deposit = deposit },
///         });
///     }
///
/// Equivalent to:
///
///     pub const program = mycelium.dispatch.program(cfg);
///     comptime { program.declareEntrypoint(); }
///
/// but without the intermediate `program` binding cluttering the file.
pub fn entrypoint(comptime cfg: anytype) void {
    const Prog = dispatch.program(cfg);
    Prog.declareEntrypoint();
}

/// Lets a program declare its expected program id at comptime:
///
///     comptime _ = mycelium.programId("MyProg11111111111111111111111111111111");
pub fn programId(comptime base58: []const u8) Pubkey {
    return Pubkey.fromBase58Comptime(base58);
}

test {
    std.testing.refAllDecls(@This());
    _ = core;
    _ = account;
    _ = pack;
    _ = dispatch;
    _ = pda;
    _ = cpi;
    _ = programs;
    _ = accounts;
    _ = framework;
}

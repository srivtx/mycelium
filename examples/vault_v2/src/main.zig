//! Vault, v2 — same semantics as `examples/vault`, rewritten on the new
//! framework primitives:
//!
//!   * `accounts.unpack(ctx, .{...})`   — declarative account-list parse
//!   * `system.createPdaAccount(...)`   — single-call PDA create + signer-seeds
//!   * `system.transferLamports(...)`   — single-call System Program transfer
//!   * `pda.verifyDerivation(...)`      — single-SHA256 PDA check (bump passed in)
//!   * `lamports.move(...)`             — direct paired-mutation transfer
//!
//! The handlers should read like the docstring at the top of the file: a
//! short list of what each instruction does. No more 14-line CPI dances.

const std = @import("std");
const mycelium = @import("mycelium");

const Pubkey = mycelium.Pubkey;
const ProgramResult = mycelium.ProgramResult;
const ExecutionContext = mycelium.ExecutionContext;
const accounts = mycelium.accounts;
const lamports = mycelium.lamports;
const pda = mycelium.pda;
const system = mycelium.programs.system;
const syscalls = mycelium.core.syscalls;

// =====================================================================
// On-chain state and seeds.
// =====================================================================

pub const State = extern struct {
    authority: Pubkey,
    bump: u8,
    initialized: u8,
    _pad: [6]u8 = .{0} ** 6,
};
const StateCodec = mycelium.pack.zerocopy.ZeroCopy(State);
const SEED_PREFIX: []const u8 = "vault";

// =====================================================================
// Instructions. Initialize takes the bump as part of the payload — the
// client computes it once via `findProgramAddressSync` and passes it in,
// which saves up to ~4.5 K CU per call.
// =====================================================================

pub const InitializePayload = extern struct {
    rent_lamports: u64,
    bump: u8,
    _pad: [7]u8 = .{0} ** 7,
};
pub const AmountPayload = extern struct { amount: u64 };

pub const Instruction = union(enum(u8)) {
    initialize: InitializePayload,
    deposit: AmountPayload,
    withdraw: AmountPayload,
};

// =====================================================================
// Handlers.
// =====================================================================

fn handleInitialize(ctx: *const ExecutionContext, payload: *const InitializePayload) ProgramResult {
    const a = try accounts.unpack(ctx, .{
        .authority = accounts.Role.signer_writable,
        .vault = accounts.Role.writable,
        .system_program = accounts.Role.system_program,
    });

    // Verify the vault address derives from (SEED, authority, bump). One
    // SHA256 — no iteration loop.
    try pda.verifyDerivation(
        &.{ SEED_PREFIX, &a.authority.key().bytes },
        payload.bump,
        ctx.program_id,
        a.vault.key(),
    );

    // The PDA must be a fresh System-owned, zero-data account; otherwise
    // someone already initialized it.
    if (a.vault.dataLen() != 0) return error.AccountAlreadyInitialized;

    // CPI: create + assign + fund, signing as the PDA.
    try system.createPdaAccount(
        a.authority,
        a.vault,
        a.system_program,
        payload.rent_lamports,
        @sizeOf(State),
        ctx.program_id,
        &.{ SEED_PREFIX, &a.authority.key().bytes, &[_]u8{payload.bump} },
    );

    const state = try StateCodec.load(a.vault.data());
    state.authority = a.authority.key().*;
    state.bump = payload.bump;
    state.initialized = 1;

    logMsg("vault: initialized");
    return;
}

fn handleDeposit(ctx: *const ExecutionContext, payload: *const AmountPayload) ProgramResult {
    const a = try accounts.unpack(ctx, .{
        .from = accounts.Role.signer_writable,
        .vault = accounts.Role.writable,
        .system_program = accounts.Role.system_program,
    });
    try mycelium.validate.mustBeOwnedBy(a.vault, ctx.program_id);
    _ = try requireInitialized(a.vault);

    if (payload.amount == 0) return error.InvalidInstructionData;
    try system.transferLamports(a.from, a.vault, a.system_program, payload.amount);

    logMsg("vault: deposit");
    return;
}

fn handleWithdraw(ctx: *const ExecutionContext, payload: *const AmountPayload) ProgramResult {
    const a = try accounts.unpack(ctx, .{
        .authority = accounts.Role.signer,
        .vault = accounts.Role.writable,
        .recipient = accounts.Role.writable,
    });
    try mycelium.validate.mustBeOwnedBy(a.vault, ctx.program_id);

    const state = try requireInitialized(a.vault);
    if (!Pubkey.equals(&state.authority, a.authority.key())) return error.IncorrectAuthority;

    if (payload.amount == 0) return error.InvalidInstructionData;
    try lamports.move(a.vault, a.recipient, payload.amount);

    logMsg("vault: withdraw");
    return;
}

inline fn requireInitialized(vault: mycelium.AccountInfo) !*align(1) State {
    const state = try StateCodec.load(vault.data());
    if (state.initialized == 0) return error.UninitializedAccount;
    return state;
}

inline fn logMsg(comptime msg: []const u8) void {
    syscalls.sol_log_(msg.ptr, msg.len);
}

pub const program = mycelium.dispatch.program(.{
    .instruction = Instruction,
    .handlers = .{
        .initialize = handleInitialize,
        .deposit = handleDeposit,
        .withdraw = handleWithdraw,
    },
});

comptime {
    program.declareEntrypoint();
}

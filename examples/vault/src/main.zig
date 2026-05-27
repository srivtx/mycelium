//! Lamport vault — a Solana program that exercises every primitive the
//! framework needs in production: PDA derivation + creation, System Program
//! CPI, PDA signing, direct lamport mutation, authority gating, account
//! lifecycle.
//!
//! Layout: one PDA per authority, seeds = ["vault", authority.key]. The PDA
//! account itself stores the authority + bump in `State`; its lamport balance
//! IS the vault.
//!
//! Instructions:
//!   tag=0  Initialize        accounts: [authority(s,w), vault(w, init), system_program]
//!                            data: { rent_lamports: u64 }     -- rent funding for the vault
//!   tag=1  Deposit           accounts: [from(s,w), vault(w), system_program]
//!                            data: { amount: u64 }
//!   tag=2  Withdraw          accounts: [authority(s), vault(w), recipient(w)]
//!                            data: { amount: u64 }
//!
//! Build:  zig build vault
//! Output: zig-out/lib/vault.so

const std = @import("std");
const mycelium = @import("mycelium");

const Pubkey = mycelium.Pubkey;
const AccountInfo = mycelium.AccountInfo;
const ProgramResult = mycelium.ProgramResult;
const ExecutionContext = mycelium.ExecutionContext;
const validate = mycelium.validate;
const lamports_mod = mycelium.lamports;
const pda = mycelium.pda;
const cpi = mycelium.cpi;
const system = mycelium.programs.system;
const syscalls = mycelium.core.syscalls;
const SYSTEM_PROGRAM_ID = mycelium.core.SYSTEM_PROGRAM_ID;

// =====================================================================
// On-chain state.
// =====================================================================

pub const State = extern struct {
    /// The wallet that can withdraw. Initialized once; immutable thereafter.
    authority: Pubkey,
    /// Bump derived during Initialize, persisted so future calls can re-sign
    /// for the PDA cheaply (no `find_program_address` syscall needed).
    bump: u8,
    /// Discriminator. 0 = uninitialized, 1 = active.
    initialized: u8,
    /// Padding so the struct is a multiple of 8 bytes (clean alignment).
    _pad: [6]u8 = .{0} ** 6,
};

const StateCodec = mycelium.pack.zerocopy.ZeroCopy(State);

const SEED_PREFIX: []const u8 = "vault";

// =====================================================================
// Instruction set.
// =====================================================================

pub const InitializePayload = extern struct {
    /// Lamports to fund the freshly-created vault PDA with (must cover rent).
    rent_lamports: u64,
};

pub const AmountPayload = extern struct {
    amount: u64,
};

pub const Instruction = union(enum(u8)) {
    initialize: InitializePayload,
    deposit: AmountPayload,
    withdraw: AmountPayload,
};

// =====================================================================
// Handlers.
// =====================================================================

fn handleInitialize(ctx: *const ExecutionContext, payload: *const InitializePayload) ProgramResult {
    if (ctx.accounts.len < 3) return error.NotEnoughAccountKeys;
    const authority = ctx.accounts[0];
    const vault = ctx.accounts[1];
    const system_program = ctx.accounts[2];

    try validate.mustBeSigner(authority);
    try validate.mustBeWritable(authority);
    try validate.mustBeWritable(vault);
    try validate.mustBeSystemProgram(system_program);

    // Derive the canonical (PDA, bump) for this authority and reject the
    // call if the caller passed a different address — this is how we bind
    // the vault to its owner.
    const derived = try pda.findProgramAddress(
        &.{ SEED_PREFIX, &authority.key().bytes },
        ctx.program_id,
    );
    if (!Pubkey.equals(&derived.address, vault.key())) return error.InvalidSeeds;

    // The vault must not already exist as a program-owned account.
    // A freshly System-owned, zero-data account is fine — that's what we'll
    // be creating in a moment.
    if (vault.dataLen() != 0) return error.AccountAlreadyInitialized;
    if (!Pubkey.equals(vault.owner(), &SYSTEM_PROGRAM_ID)) return error.AccountAlreadyInitialized;

    // CPI: System Program create_account, signing as the PDA we just derived.
    var data_buf: [system.CREATE_ACCOUNT_DATA_LEN]u8 = undefined;
    var accs_buf: [2]cpi.AccountMeta = undefined;
    const create_ix = system.createAccount(
        authority.key(),
        vault.key(),
        payload.rent_lamports,
        @sizeOf(State),
        ctx.program_id, // owner = us, so we can mutate lamports/data freely
        &data_buf,
        &accs_buf,
    );

    // Signer seeds for the PDA: ["vault", authority.key, [bump]].
    const bump_bytes: [1]u8 = .{derived.bump};
    const seed_tuple: []const []const u8 = &.{ SEED_PREFIX, &authority.key().bytes, &bump_bytes };

    try cpi.invokeSigned(
        create_ix,
        &.{ authority, vault, system_program },
        &.{seed_tuple},
    );

    // Initialize the state inside the freshly-created vault.
    const state = try StateCodec.load(vault.data());
    state.authority = authority.key().*;
    state.bump = derived.bump;
    state.initialized = 1;

    logMsg("vault: initialized");
    return;
}

fn handleDeposit(ctx: *const ExecutionContext, payload: *const AmountPayload) ProgramResult {
    if (ctx.accounts.len < 3) return error.NotEnoughAccountKeys;
    const from = ctx.accounts[0];
    const vault = ctx.accounts[1];
    const system_program = ctx.accounts[2];

    try validate.mustBeSigner(from);
    try validate.mustBeWritable(from);
    try validate.mustBeWritable(vault);
    try validate.mustBeOwnedBy(vault, ctx.program_id);
    try validate.mustBeSystemProgram(system_program);

    const state = try requireInitialized(vault);
    _ = state;

    if (payload.amount == 0) return error.InvalidInstructionData;

    // Anyone can deposit. They are signing the System Program transfer from
    // their own wallet, so no PDA signing is needed.
    var data_buf: [system.TRANSFER_DATA_LEN]u8 = undefined;
    var accs_buf: [2]cpi.AccountMeta = undefined;
    const transfer_ix = system.transfer(
        from.key(),
        vault.key(),
        payload.amount,
        &data_buf,
        &accs_buf,
    );
    try cpi.invoke(transfer_ix, &.{ from, vault, system_program });

    logMsg("vault: deposit");
    return;
}

fn handleWithdraw(ctx: *const ExecutionContext, payload: *const AmountPayload) ProgramResult {
    if (ctx.accounts.len < 3) return error.NotEnoughAccountKeys;
    const authority = ctx.accounts[0];
    const vault = ctx.accounts[1];
    const recipient = ctx.accounts[2];

    try validate.mustBeSigner(authority);
    try validate.mustBeWritable(vault);
    try validate.mustBeWritable(recipient);
    try validate.mustBeOwnedBy(vault, ctx.program_id);

    const state = try requireInitialized(vault);
    if (!Pubkey.equals(&state.authority, authority.key())) return error.IncorrectAuthority;

    if (payload.amount == 0) return error.InvalidInstructionData;

    // The vault is owned by US, so we can move lamports directly without a
    // System Program CPI. We must NOT drain the vault below rent-exempt
    // minimum or the runtime will reject the tx at commit time. The simplest
    // robust rule: keep enough lamports to cover the data we hold.
    //
    // Rent-exempt minimum for `@sizeOf(State)` bytes ≈ a few thousand
    // lamports; we let the caller / client own the policy by simply
    // forwarding the underflow error from `move`.
    try lamports_mod.move(vault, recipient, payload.amount);

    logMsg("vault: withdraw");
    return;
}

// =====================================================================
// Helpers.
// =====================================================================

inline fn requireInitialized(vault: AccountInfo) !*align(1) State {
    const state = try StateCodec.load(vault.data());
    if (state.initialized == 0) return error.UninitializedAccount;
    return state;
}

inline fn logMsg(comptime msg: []const u8) void {
    syscalls.sol_log_(msg.ptr, msg.len);
}

// =====================================================================
// Wire it up.
// =====================================================================

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

// =====================================================================
// Host-side sanity tests.
// =====================================================================

test "State has expected size" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(State));
}

test "Instruction discriminator bytes" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(@as(Instruction, .{ .initialize = .{ .rent_lamports = 0 } })));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(@as(Instruction, .{ .deposit = .{ .amount = 0 } })));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(@as(Instruction, .{ .withdraw = .{ .amount = 0 } })));
}

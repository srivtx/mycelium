//! Lamport-for-lamports escrow.
//!
//! The maker locks N lamports in a per-trade PDA and posts a price P. Any
//! taker can then pay P lamports to the maker and receive the locked N
//! lamports (the escrow account is closed). The maker can also cancel and
//! reclaim the N lamports.
//!
//! Escrow PDA seeds: ["escrow", maker.key, escrow_id_bytes]
//! Why the id byte: lets one maker have multiple concurrent trades.
//!
//! Instructions (tag, accounts, data):
//!   tag=0  Initialize { amount, price, id }
//!     accounts: [maker(s,w), escrow(w, init), system_program]
//!   tag=1  Take {}
//!     accounts: [taker(s,w), maker(w), escrow(w), system_program]
//!   tag=2  Cancel {}
//!     accounts: [maker(s,w), escrow(w)]
//!
//! Build:  zig build escrow
//! Output: zig-out/lib/escrow.so

const std = @import("std");
const mycelium = @import("mycelium");

const Pubkey = mycelium.Pubkey;
const AccountInfo = mycelium.AccountInfo;
const ProgramResult = mycelium.ProgramResult;
const ExecutionContext = mycelium.ExecutionContext;
const validate = mycelium.validate;
const lamports = mycelium.lamports;
const pda = mycelium.pda;
const cpi = mycelium.cpi;
const system = mycelium.programs.system;
const syscalls = mycelium.core.syscalls;
const SYSTEM_PROGRAM_ID = mycelium.core.SYSTEM_PROGRAM_ID;

// =====================================================================
// On-chain state.
// =====================================================================

pub const State = extern struct {
    maker: Pubkey,
    amount: u64,      // lamports locked by the maker, paid to taker
    price: u64,       // lamports the taker must pay, paid to maker
    id: u64,          // arbitrary disambiguator chosen by the maker
    bump: u8,
    initialized: u8,
    _pad: [6]u8 = .{0} ** 6,
};

const StateCodec = mycelium.pack.zerocopy.ZeroCopy(State);

const SEED_PREFIX: []const u8 = "escrow";

// =====================================================================
// Instruction set.
// =====================================================================

pub const InitializePayload = extern struct {
    amount: u64,
    price: u64,
    id: u64,
    rent_lamports: u64,
};

pub const Instruction = union(enum(u8)) {
    initialize: InitializePayload,
    take,
    cancel,
};

// =====================================================================
// Handlers.
// =====================================================================

fn handleInitialize(ctx: *const ExecutionContext, payload: *const InitializePayload) ProgramResult {
    if (ctx.accounts.len < 3) return error.NotEnoughAccountKeys;
    const maker = ctx.accounts[0];
    const escrow = ctx.accounts[1];
    const system_program = ctx.accounts[2];

    try validate.mustBeSigner(maker);
    try validate.mustBeWritable(maker);
    try validate.mustBeWritable(escrow);
    try validate.mustBeSystemProgram(system_program);

    if (payload.amount == 0 or payload.price == 0) return error.InvalidInstructionData;

    // Derive (PDA, bump) from (SEED_PREFIX, maker.key, id_bytes).
    var id_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &id_bytes, payload.id, .little);

    const derived = try pda.findProgramAddress(
        &.{ SEED_PREFIX, &maker.key().bytes, &id_bytes },
        ctx.program_id,
    );
    if (!Pubkey.equals(&derived.address, escrow.key())) return error.InvalidSeeds;

    if (escrow.dataLen() != 0) return error.AccountAlreadyInitialized;
    if (!Pubkey.equals(escrow.owner(), &SYSTEM_PROGRAM_ID)) return error.AccountAlreadyInitialized;

    // Lamports to put on the PDA = rent + the locked amount. The locked
    // amount lives inside the PDA's balance until Take or Cancel.
    const total_lamports = payload.rent_lamports + payload.amount;

    // CPI: create_account, signing as the PDA.
    var data_buf: [system.CREATE_ACCOUNT_DATA_LEN]u8 = undefined;
    var accs_buf: [2]cpi.AccountMeta = undefined;
    const create_ix = system.createAccount(
        maker.key(),
        escrow.key(),
        total_lamports,
        @sizeOf(State),
        ctx.program_id,
        &data_buf,
        &accs_buf,
    );

    const bump_bytes: [1]u8 = .{derived.bump};
    const seed_tuple: []const []const u8 = &.{ SEED_PREFIX, &maker.key().bytes, &id_bytes, &bump_bytes };
    try cpi.invokeSigned(
        create_ix,
        &.{ maker, escrow, system_program },
        &.{seed_tuple},
    );

    // Populate state.
    const state = try StateCodec.load(escrow.data());
    state.maker = maker.key().*;
    state.amount = payload.amount;
    state.price = payload.price;
    state.id = payload.id;
    state.bump = derived.bump;
    state.initialized = 1;

    logMsg("escrow: initialized");
    return;
}

fn handleTake(ctx: *const ExecutionContext) ProgramResult {
    if (ctx.accounts.len < 4) return error.NotEnoughAccountKeys;
    const taker = ctx.accounts[0];
    const maker = ctx.accounts[1];
    const escrow = ctx.accounts[2];
    const system_program = ctx.accounts[3];

    try validate.mustBeSigner(taker);
    try validate.mustBeWritable(taker);
    try validate.mustBeWritable(maker);
    try validate.mustBeWritable(escrow);
    try validate.mustBeOwnedBy(escrow, ctx.program_id);
    try validate.mustBeSystemProgram(system_program);

    const state = try requireInitialized(escrow);

    // Anchor the maker by key — caller could pass the wrong maker otherwise.
    if (!Pubkey.equals(&state.maker, maker.key())) return error.IncorrectAuthority;

    // 1) Taker → Maker: CPI System Program transfer, signed by taker.
    {
        var data_buf: [system.TRANSFER_DATA_LEN]u8 = undefined;
        var accs_buf: [2]cpi.AccountMeta = undefined;
        const ix = system.transfer(taker.key(), maker.key(), state.price, &data_buf, &accs_buf);
        try cpi.invoke(ix, &.{ taker, maker, system_program });
    }

    // 2) Escrow → Taker: direct lamport mutation (we own the escrow).
    //    Move only the locked `amount`, then close the rest (rent) into the
    //    taker as well so the escrow account disappears. Equivalent to
    //    paying the rent rebate to the taker.
    try lamports.close(escrow, taker);

    logMsg("escrow: taken");
    return;
}

fn handleCancel(ctx: *const ExecutionContext) ProgramResult {
    if (ctx.accounts.len < 2) return error.NotEnoughAccountKeys;
    const maker = ctx.accounts[0];
    const escrow = ctx.accounts[1];

    try validate.mustBeSigner(maker);
    try validate.mustBeWritable(maker);
    try validate.mustBeWritable(escrow);
    try validate.mustBeOwnedBy(escrow, ctx.program_id);

    const state = try requireInitialized(escrow);
    if (!Pubkey.equals(&state.maker, maker.key())) return error.IncorrectAuthority;

    // Refund: drain the escrow into the maker (rebate includes rent).
    try lamports.close(escrow, maker);

    logMsg("escrow: cancelled");
    return;
}

// =====================================================================
// Helpers.
// =====================================================================

inline fn requireInitialized(escrow: AccountInfo) !*align(1) State {
    const state = try StateCodec.load(escrow.data());
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
        .take = handleTake,
        .cancel = handleCancel,
    },
});

comptime {
    program.declareEntrypoint();
}

// =====================================================================
// Host-side sanity checks.
// =====================================================================

test "State has the expected size" {
    // 32 (maker) + 8 (amount) + 8 (price) + 8 (id) + 1 + 1 + 6 = 64
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(State));
}

//! Escrow, v2 — same semantics as `examples/escrow`, rewritten on the new
//! framework primitives. Bump is passed in the Initialize payload so we
//! avoid `findProgramAddress`'s up-to-255-iteration bump search.

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

pub const State = extern struct {
    maker: Pubkey,
    amount: u64,
    price: u64,
    id: u64,
    bump: u8,
    initialized: u8,
    _pad: [6]u8 = .{0} ** 6,
};
const StateCodec = mycelium.pack.zerocopy.ZeroCopy(State);
const SEED_PREFIX: []const u8 = "escrow";

pub const InitializePayload = extern struct {
    amount: u64,
    price: u64,
    id: u64,
    rent_lamports: u64,
    bump: u8,
    _pad: [7]u8 = .{0} ** 7,
};

pub const Instruction = union(enum(u8)) {
    initialize: InitializePayload,
    take,
    cancel,
};

fn handleInitialize(ctx: *const ExecutionContext, payload: *const InitializePayload) ProgramResult {
    const a = try accounts.unpack(ctx, .{
        .maker = accounts.Role.signer_writable,
        .escrow = accounts.Role.writable,
        .system_program = accounts.Role.system_program,
    });

    if (payload.amount == 0 or payload.price == 0) return error.InvalidInstructionData;

    var id_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &id_bytes, payload.id, .little);

    try pda.verifyDerivation(
        &.{ SEED_PREFIX, &a.maker.key().bytes, &id_bytes },
        payload.bump,
        ctx.program_id,
        a.escrow.key(),
    );

    if (a.escrow.dataLen() != 0) return error.AccountAlreadyInitialized;

    try system.createPdaAccount(
        a.maker,
        a.escrow,
        a.system_program,
        payload.rent_lamports + payload.amount,
        @sizeOf(State),
        ctx.program_id,
        &.{ SEED_PREFIX, &a.maker.key().bytes, &id_bytes, &[_]u8{payload.bump} },
    );

    const state = try StateCodec.load(a.escrow.data());
    state.maker = a.maker.key().*;
    state.amount = payload.amount;
    state.price = payload.price;
    state.id = payload.id;
    state.bump = payload.bump;
    state.initialized = 1;

    logMsg("escrow: initialized");
    return;
}

fn handleTake(ctx: *const ExecutionContext) ProgramResult {
    const a = try accounts.unpack(ctx, .{
        .taker = accounts.Role.signer_writable,
        .maker = accounts.Role.writable,
        .escrow = accounts.Role.writable,
        .system_program = accounts.Role.system_program,
    });
    try mycelium.validate.mustBeOwnedBy(a.escrow, ctx.program_id);

    const state = try requireInitialized(a.escrow);
    if (!Pubkey.equals(&state.maker, a.maker.key())) return error.IncorrectAuthority;

    try system.transferLamports(a.taker, a.maker, a.system_program, state.price);
    try lamports.close(a.escrow, a.taker);

    logMsg("escrow: taken");
    return;
}

fn handleCancel(ctx: *const ExecutionContext) ProgramResult {
    const a = try accounts.unpack(ctx, .{
        .maker = accounts.Role.signer_writable,
        .escrow = accounts.Role.writable,
    });
    try mycelium.validate.mustBeOwnedBy(a.escrow, ctx.program_id);

    const state = try requireInitialized(a.escrow);
    if (!Pubkey.equals(&state.maker, a.maker.key())) return error.IncorrectAuthority;

    try lamports.close(a.escrow, a.maker);

    logMsg("escrow: cancelled");
    return;
}

inline fn requireInitialized(escrow: mycelium.AccountInfo) !*align(1) State {
    const state = try StateCodec.load(escrow.data());
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
        .take = handleTake,
        .cancel = handleCancel,
    },
});

comptime {
    program.declareEntrypoint();
}

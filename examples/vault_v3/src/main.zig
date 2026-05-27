//! Vault — theoretical-minimum form on the recipe layer.
//!
//! The whole program: state, three instructions, three handlers, entrypoint —
//! under 60 lines, no scaffolding, no helper functions, every check in plain
//! sight.

const mycelium = @import("mycelium");
const accs = mycelium.accounts;
const fw = mycelium.framework;
const sys = mycelium.programs.system;

pub const State = extern struct {
    authority: mycelium.Pubkey,
    bump: u8,
    initialized: u8,
    _pad: mycelium.Pad(6) = .{},
};

pub const Init = extern struct { rent: u64, bump: u8, _pad: mycelium.Pad(7) = .{} };
pub const Amount = extern struct { amount: u64 };

pub const Ix = union(enum(u8)) {
    initialize: Init,
    deposit: Amount,
    withdraw: Amount,
};

const SEED: []const u8 = "vault";

fn initialize(ctx: mycelium.Ctx, p: *const Init) !void {
    const a = try accs.unpack(ctx, .{ .authority = accs.sw, .vault = accs.w, .sys = accs.sys });
    const s = try fw.createPdaState(State, .{
        .payer = a.authority, .pda = a.vault, .system_program = a.sys,
        .program_id = ctx.program_id,
        .seeds = &.{ SEED, &a.authority.key().bytes },
        .bump = p.bump, .rent_lamports = p.rent,
    });
    s.authority = a.authority.key().*;
    s.bump = p.bump;
    s.initialized = 1;
}

fn deposit(ctx: mycelium.Ctx, p: *const Amount) !void {
    const a = try accs.unpack(ctx, .{ .from = accs.sw, .vault = accs.w, .sys = accs.sys });
    _ = try fw.owned(State, a.vault, ctx.program_id);
    if (p.amount == 0) return error.InvalidInstructionData;
    try sys.transferLamports(a.from, a.vault, a.sys, p.amount);
}

fn withdraw(ctx: mycelium.Ctx, p: *const Amount) !void {
    const a = try accs.unpack(ctx, .{ .authority = accs.s, .vault = accs.w, .recipient = accs.w });
    _ = try fw.gate(State, a.vault, ctx.program_id, a.authority, "authority");
    if (p.amount == 0) return error.InvalidInstructionData;
    try mycelium.lamports.move(a.vault, a.recipient, p.amount);
}

comptime {
    mycelium.entrypoint(.{
        .instruction = Ix,
        .handlers = .{ .initialize = initialize, .deposit = deposit, .withdraw = withdraw },
    });
}

//! Escrow — theoretical-minimum form on the recipe layer.
//!
//! Lamport-for-lamports escrow: maker locks `amount` and posts a `price`;
//! taker pays `price` to take the lock; maker may cancel and reclaim.

const std = @import("std");
const mycelium = @import("mycelium");
const accs = mycelium.accounts;
const fw = mycelium.framework;
const sys = mycelium.programs.system;

pub const State = extern struct {
    maker: mycelium.Pubkey,
    amount: u64,
    price: u64,
    id: u64,
    bump: u8,
    initialized: u8,
    _pad: mycelium.Pad(6) = .{},
};

pub const Init = extern struct {
    amount: u64,
    price: u64,
    id: u64,
    rent: u64,
    bump: u8,
    _pad: mycelium.Pad(7) = .{},
};

pub const Ix = union(enum(u8)) {
    initialize: Init,
    take,
    cancel,
};

const SEED: []const u8 = "escrow";

fn initialize(ctx: mycelium.Ctx, p: *const Init) !void {
    if (p.amount == 0 or p.price == 0) return error.InvalidInstructionData;
    const a = try accs.unpack(ctx, .{ .maker = accs.sw, .escrow = accs.w, .sys = accs.sys });

    var id_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &id_bytes, p.id, .little);

    const s = try fw.createPdaState(State, .{
        .payer = a.maker, .pda = a.escrow, .system_program = a.sys,
        .program_id = ctx.program_id,
        .seeds = &.{ SEED, &a.maker.key().bytes, &id_bytes },
        .bump = p.bump, .rent_lamports = p.rent + p.amount,
    });
    s.maker = a.maker.key().*;
    s.amount = p.amount;
    s.price = p.price;
    s.id = p.id;
    s.bump = p.bump;
    s.initialized = 1;
}

fn take(ctx: mycelium.Ctx) !void {
    const a = try accs.unpack(ctx, .{ .taker = accs.sw, .maker = accs.w, .escrow = accs.w, .sys = accs.sys });
    const s = try fw.gate(State, a.escrow, ctx.program_id, a.maker, "maker");
    try sys.transferLamports(a.taker, a.maker, a.sys, s.price);
    try mycelium.lamports.close(a.escrow, a.taker);
}

fn cancel(ctx: mycelium.Ctx) !void {
    const a = try accs.unpack(ctx, .{ .maker = accs.sw, .escrow = accs.w });
    try fw.closeState(State, a.escrow, a.maker, .{
        .owner = ctx.program_id, .authority = a.maker, .authority_field = "maker",
    });
}

comptime {
    mycelium.entrypoint(.{
        .instruction = Ix,
        .handlers = .{ .initialize = initialize, .take = take, .cancel = cancel },
    });
}

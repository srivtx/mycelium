//! `__NAME__` — a mycelium program.
//!
//! Scaffolded by `mycelium new __NAME__`. A minimal counter that initializes
//! a PDA-owned state account and lets the authority increment it.
//!
//! Wire format:
//!   tag=0 InitializePayload { rent: u64, bump: u8, _pad: [7]u8 }
//!   tag=1 IncrementPayload  { delta: u64 }

const mycelium = @import("mycelium");
const accs = mycelium.accounts;
const fw = mycelium.framework;

pub const State = extern struct {
    authority: mycelium.Pubkey,
    counter: u64,
    bump: u8,
    initialized: u8,
    _pad: mycelium.Pad(6) = .{},
};

pub const Init = extern struct { rent: u64, bump: u8, _pad: mycelium.Pad(7) = .{} };
pub const Inc = extern struct { delta: u64 };

pub const Ix = union(enum(u8)) {
    initialize: Init,
    increment: Inc,
};

const SEED: []const u8 = "__NAME__";

fn initialize(ctx: mycelium.Ctx, p: *const Init) !void {
    const a = try accs.unpack(ctx, .{ .authority = accs.sw, .state = accs.w, .sys = accs.sys });
    const s = try fw.createPdaState(State, .{
        .payer = a.authority, .pda = a.state, .system_program = a.sys,
        .program_id = ctx.program_id,
        .seeds = &.{ SEED, &a.authority.key().bytes },
        .bump = p.bump, .rent_lamports = p.rent,
    });
    s.authority = a.authority.key().*;
    s.counter = 0;
    s.bump = p.bump;
    s.initialized = 1;
}

fn increment(ctx: mycelium.Ctx, p: *const Inc) !void {
    const a = try accs.unpack(ctx, .{ .authority = accs.s, .state = accs.w });
    const s = try fw.gate(State, a.state, ctx.program_id, a.authority, "authority");
    s.counter +%= p.delta;
}

comptime {
    mycelium.entrypoint(.{
        .instruction = Ix,
        .handlers = .{ .initialize = initialize, .increment = increment },
    });
}

//! Counter program — minimal end-to-end demo of mycelium.
//!
//! Account layout: a single mutable account owned by this program, whose
//! data is exactly `@sizeOf(State)` bytes (zero-copy `extern struct`).
//!
//! Instructions:
//!   tag=0  Initialize           accounts: [counter (mut, init), authority (signer)]
//!   tag=1  Increment            accounts: [counter (mut),       authority (signer)]
//!   tag=2  AddAmount  : payload  accounts: [counter (mut),       authority (signer)]
//!   tag=3  Reset                accounts: [counter (mut),        authority (signer)]
//!
//! Build:  zig build counter
//! Output: zig-out/lib/counter.so

const std = @import("std");
const mycelium = @import("mycelium");

const Pubkey = mycelium.Pubkey;
const AccountInfo = mycelium.AccountInfo;
const ProgramResult = mycelium.ProgramResult;
const ExecutionContext = mycelium.ExecutionContext;
const validate = mycelium.validate;
const syscalls = mycelium.core.syscalls;

// =====================================================================
// State stored in the counter account. extern struct => exact byte layout.
// =====================================================================

pub const State = extern struct {
    /// The pubkey that may increment/reset.
    authority: Pubkey,
    /// Current counter value.
    value: u64,
    /// 1 if initialized, 0 if not. Guards re-initialization.
    initialized: u8,
    /// Trailing padding to keep the struct an exact multiple of 8 bytes.
    _pad: [7]u8 = .{0} ** 7,
};

const StateCodec = mycelium.pack.zerocopy.ZeroCopy(State);

// =====================================================================
// Instruction set. A tagged union with explicit u8 discriminator and
// named payload types (so handlers can reference them by name).
// =====================================================================

pub const AddAmountPayload = extern struct {
    amount: u64,
};

pub const Instruction = union(enum(u8)) {
    initialize,
    increment,
    add_amount: AddAmountPayload,
    reset,
};

// =====================================================================
// Handlers. Each handler validates accounts explicitly — no macros.
// =====================================================================

fn handleInitialize(ctx: *const ExecutionContext) ProgramResult {
    if (ctx.accounts.len < 2) return error.NotEnoughAccountKeys;
    const counter = ctx.accounts[0];
    const authority = ctx.accounts[1];

    try validate.mustBeOwnedBy(counter, ctx.program_id);
    try validate.mustBeWritable(counter);
    try validate.mustBeSigner(authority);
    try validate.mustHaveDataSize(counter, StateCodec.SIZE);

    const state = try StateCodec.load(counter.data());
    if (state.initialized != 0) return error.AccountAlreadyInitialized;

    state.authority = authority.key().*;
    state.value = 0;
    state.initialized = 1;

    logMsg("counter initialized");
    return;
}

fn handleIncrement(ctx: *const ExecutionContext) ProgramResult {
    const state = try loadAndAuthorize(ctx);
    state.value, const overflowed = @addWithOverflow(state.value, 1);
    if (overflowed != 0) return error.ArithmeticOverflow;
    return;
}

fn handleAddAmount(ctx: *const ExecutionContext, payload: *const AddAmountPayload) ProgramResult {
    const state = try loadAndAuthorize(ctx);
    state.value, const overflowed = @addWithOverflow(state.value, payload.amount);
    if (overflowed != 0) return error.ArithmeticOverflow;
    return;
}

fn handleReset(ctx: *const ExecutionContext) ProgramResult {
    const state = try loadAndAuthorize(ctx);
    state.value = 0;
    return;
}

/// Common prefix: counter must be initialized, owned by us, writable; the
/// signer must match the stored authority. Returns a mutable view of state.
inline fn loadAndAuthorize(ctx: *const ExecutionContext) !*align(1) State {
    if (ctx.accounts.len < 2) return error.NotEnoughAccountKeys;
    const counter = ctx.accounts[0];
    const authority = ctx.accounts[1];

    try validate.mustBeOwnedBy(counter, ctx.program_id);
    try validate.mustBeWritable(counter);
    try validate.mustBeSigner(authority);

    const state = try StateCodec.load(counter.data());
    if (state.initialized == 0) return error.UninitializedAccount;
    if (!Pubkey.equals(&state.authority, authority.key())) return error.IncorrectAuthority;
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
        .increment = handleIncrement,
        .add_amount = handleAddAmount,
        .reset = handleReset,
    },
});

comptime {
    program.declareEntrypoint();
}

// =====================================================================
// Host-side tests (run via `zig build test` from the example directory,
// or as part of integration tests later).
// =====================================================================

test "State has expected size" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(State));
}

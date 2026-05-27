//! The "framework" layer — opinionated recipes that compose the lower-level
//! primitives into the patterns every Solana program writes over and over:
//!
//!   * `createPdaState(...)` — create a fresh PDA-owned account, verify its
//!     derivation, fund it, and return a typed `*State` pointer for the
//!     caller to fill in.
//!   * `openState(...)`      — load an existing state account with the full
//!     gauntlet of standard checks: owner, discriminator, optional authority.
//!   * `closeState(...)`     — validate then drain into a recipient
//!     (account disappears at commit time).
//!
//! Design goals:
//!   - Each recipe is a single function with one named-struct argument; the
//!     code reads like a sentence at the call site.
//!   - Every check that should happen on the slow path *does* happen.
//!     Edge cases (mis-sized state, wrong owner, replayed init, bumped
//!     bumps, stale discriminators) surface as named `ProgramError` values.
//!   - Comptime guards catch mis-specs at compile time: e.g. referring to
//!     a field name that the State struct does not have is a compile error,
//!     not a runtime mystery.
//!   - The generated SBPF is byte-identical to the hand-written equivalent;
//!     the recipes are pure inlinable comptime sugar, not runtime overhead.

const std = @import("std");
const core = @import("core/root.zig");
const account = @import("account/root.zig");
const pda_mod = @import("pda.zig");
const system = @import("programs/system.zig");
const ZeroCopy = @import("pack/zerocopy.zig").ZeroCopy;
const lamports_mod = @import("account/lamports.zig");

const Pubkey = core.Pubkey;
const AccountInfo = account.AccountInfo;
const ProgramError = core.ProgramError;
const validate = account.validate;

// =====================================================================
// createPdaState — Initialize handler recipe.
// =====================================================================

pub const CreatePdaStateOpts = struct {
    /// The wallet that funds the new account's rent. Must be a signer.
    payer: AccountInfo,
    /// The PDA-to-be. Must be writable, currently empty + System-owned.
    pda: AccountInfo,
    /// System Program account. Required for the CPI.
    system_program: AccountInfo,
    /// The program that will own the new account (= your `ctx.program_id`).
    program_id: *const Pubkey,
    /// PDA seeds *without* the trailing bump. The bump is appended internally
    /// when signing the CPI.
    seeds: []const []const u8,
    /// Canonical bump for these seeds. Should come from the instruction data
    /// (cheap, deterministic) — the client computes it via
    /// `PublicKey.findProgramAddressSync` and passes it in.
    bump: u8,
    /// Lamports to put on the new account. Must be ≥ rent-exempt minimum for
    /// `@sizeOf(State)` bytes, or the runtime will reject the CPI.
    rent_lamports: u64,
};

/// Allocate, fund, and assign a fresh PDA-owned account; return a typed
/// pointer into its zero-initialized data region.
///
/// The caller then fills the state by assigning to the returned `*State`:
///
///     const state = try framework.createPdaState(State, .{ ... });
///     state.authority = a.payer.key().*;
///     state.bump = bump;
///     state.initialized = 1;
///
/// All edge cases this function handles:
///   - PDA derivation verified (1× SHA256, no curve-search loop).
///   - `pda` must be empty + System-owned, otherwise `AccountAlreadyInitialized`.
///   - Seed count bounded by `pda.MAX_SEEDS`; over-length seeds rejected.
///   - Bump byte lifetime managed (stays live through the syscall).
///   - CPI runs with PDA signer-seeds attached; if it fails, the error is
///     surfaced (as `error.Custom`).
pub fn createPdaState(
    comptime State: type,
    opts: CreatePdaStateOpts,
) ProgramError!*align(1) State {
    // 1. Verify the supplied (seeds, bump) actually derive to `pda.key()`.
    //    Reuses createProgramAddress under the hood — single SHA256.
    try pda_mod.verifyDerivation(opts.seeds, opts.bump, opts.program_id, opts.pda.key());

    // 2. The PDA must be a fresh, System-owned, zero-data account. Any other
    //    state means somebody already touched it.
    if (opts.pda.dataLen() != 0) return error.AccountAlreadyInitialized;
    if (!Pubkey.equals(opts.pda.owner(), &core.SYSTEM_PROGRAM_ID)) {
        return error.AccountAlreadyInitialized;
    }

    // 3. Build signer-seeds = seeds ++ [bump]. The bump byte must stay live
    //    through the inner syscall; that syscall returns before this function
    //    does, so a stack-local is safe.
    if (opts.seeds.len + 1 > pda_mod.MAX_SEEDS) return error.MaxSeedLengthExceeded;
    var signer_seeds_buf: [pda_mod.MAX_SEEDS][]const u8 = undefined;
    for (opts.seeds, 0..) |s, i| signer_seeds_buf[i] = s;
    const bump_byte: [1]u8 = .{opts.bump};
    signer_seeds_buf[opts.seeds.len] = &bump_byte;
    const signer_seeds = signer_seeds_buf[0 .. opts.seeds.len + 1];

    // 4. CPI: create the account, signing as the PDA.
    try system.createPdaAccount(
        opts.payer,
        opts.pda,
        opts.system_program,
        opts.rent_lamports,
        @sizeOf(State),
        opts.program_id,
        signer_seeds,
    );

    // 5. Return a typed view into the (zero-initialized) data region.
    //    `dataAs` re-checks the size guard; it should always succeed because
    //    we just sized the account to `@sizeOf(State)`.
    return ZeroCopy(State).load(opts.pda.data()) catch return error.AccountDataTooSmall;
}

// =====================================================================
// openState — non-Initialize handler recipe.
// =====================================================================

/// Load and validate a state account that the calling program owns.
///
/// `opts` is an anonymous struct. Recognized fields (all comptime-checked):
///
///   .owner               (required, *const Pubkey)
///     Expected owner. Usually `ctx.program_id`. Fails `IllegalOwner`.
///
///   .authority           (optional, AccountInfo)
///     Account whose key is compared against `authority_field`. If
///     `authority_field` is set, `.authority` is required.
///     NOTE: this function does NOT verify the account is a signer; the
///     unpack spec is where you express signing requirements. This option
///     is the "stored key must match this account" check, full stop.
///
///   .authority_field     (optional, comptime []const u8)
///     Name of a `Pubkey` field in `State`. Verified to equal
///     `authority.key()`. Fails `IncorrectAuthority`.
///     Compile-error if the field does not exist.
///
///   .discriminator_field (optional, comptime []const u8, default "initialized")
///     Name of a `u8` field in `State`. Non-zero means initialized.
///     Pass `""` to skip the discriminator check entirely.
///     Compile-error if the named field does not exist on State.
///
/// Returns a writable `*align(1) State` pointing into the live account data.
pub fn openState(
    comptime State: type,
    acc: AccountInfo,
    opts: anytype,
) ProgramError!*align(1) State {
    const O = @TypeOf(opts);

    // ---- comptime validation of the opts spec ----
    if (!@hasField(O, "owner")) @compileError("openState requires opts.owner");

    const has_auth_field = @hasField(O, "authority_field");
    const has_auth_acc = @hasField(O, "authority");
    if (has_auth_field and !has_auth_acc) {
        @compileError("openState: opts.authority_field requires opts.authority");
    }
    if (has_auth_field) {
        if (!@hasField(State, opts.authority_field)) {
            @compileError("openState: State has no field named '" ++ opts.authority_field ++ "'");
        }
    }

    // Resolve discriminator field name. Default is "initialized"; pass
    // `.discriminator_field = ""` to skip the check entirely. If a
    // non-empty name is given, the field MUST exist on State — typoing
    // the name should not silently disable the check.
    const disc_field: []const u8 = comptime blk: {
        if (@hasField(O, "discriminator_field")) break :blk opts.discriminator_field;
        break :blk "initialized";
    };
    comptime {
        if (disc_field.len > 0 and !@hasField(State, disc_field)) {
            @compileError("openState: State has no field named '" ++ disc_field ++
                "'. Pass .discriminator_field = \"\" to skip the init check.");
        }
    }

    // ---- runtime checks ----
    try validate.mustBeOwnedBy(acc, opts.owner);

    const state = try ZeroCopy(State).load(acc.data());

    if (comptime disc_field.len > 0) {
        const disc = @field(state.*, disc_field);
        if (@TypeOf(disc) != u8) {
            @compileError("openState: discriminator field '" ++ disc_field ++ "' must be u8");
        }
        if (disc == 0) return error.UninitializedAccount;
    }

    if (has_auth_field) {
        const expected: Pubkey = @field(state.*, opts.authority_field);
        if (!Pubkey.equals(&expected, opts.authority.key())) {
            return error.IncorrectAuthority;
        }
    }

    return state;
}

// =====================================================================
// Shorthand wrappers around openState.
//
// These exist purely to keep the most common call-sites to a single line.
// The implementation is just a forwarding call to openState; the compiler
// inlines them away and the generated SBPF is identical.
// =====================================================================

/// "Account must be owned by `owner` and its `initialized` byte must be
/// non-zero." The minimum check before reading any state.
///
///     const state = try fw.owned(State, a.vault, ctx.program_id);
pub fn owned(
    comptime State: type,
    acc: AccountInfo,
    owner: *const Pubkey,
) ProgramError!*align(1) State {
    return openState(State, acc, .{ .owner = owner });
}

/// "Account must be owned by `owner`, initialized, and have its
/// `<field>` Pubkey field equal to `authority.key()`."
///
/// `field` is a comptime string. Mis-spelling it is a compile error.
///
///     const state = try fw.gate(State, a.vault, ctx.program_id, a.authority, "authority");
pub fn gate(
    comptime State: type,
    acc: AccountInfo,
    owner: *const Pubkey,
    authority: AccountInfo,
    comptime field: []const u8,
) ProgramError!*align(1) State {
    return openState(State, acc, .{
        .owner = owner,
        .authority = authority,
        .authority_field = field,
    });
}

// =====================================================================
// closeState — drain + zero + (let runtime) deallocate.
// =====================================================================

/// Run the same validation as `openState`, then drain the account's lamports
/// into `recipient` and zero its data. The runtime garbage-collects the
/// account once lamports hit zero, so the account disappears at commit.
pub fn closeState(
    comptime State: type,
    acc: AccountInfo,
    recipient: AccountInfo,
    opts: anytype,
) ProgramError!void {
    _ = try openState(State, acc, opts);
    try lamports_mod.close(acc, recipient);
}

// =====================================================================
// Tests — only the parts exercisable host-side. The CPI paths run on the
// validator and are covered by the integration scripts.
// =====================================================================

const testing = std.testing;
const FieldOffset = account.info.FieldOffset;

const TestState = extern struct {
    authority: Pubkey,
    bump: u8,
    initialized: u8,
    _pad: [6]u8 = .{0} ** 6,
};

fn mkAcc(buf: *[1024]u8, owner: *const Pubkey, signer: bool, writable: bool, data_len: u64, key: *const Pubkey) AccountInfo {
    @memset(buf, 0);
    buf[FieldOffset.is_signer] = if (signer) 1 else 0;
    buf[FieldOffset.is_writable] = if (writable) 1 else 0;
    @memcpy(buf[FieldOffset.key..][0..32], &key.bytes);
    @memcpy(buf[FieldOffset.owner..][0..32], &owner.bytes);
    std.mem.writeInt(u64, buf[FieldOffset.data_len..][0..8], data_len, .little);
    return .{ .raw = buf };
}

test "openState: happy path with authority check" {
    var owner_pk: Pubkey = .{ .bytes = .{0xAA} ** 32 };
    var signer_pk: Pubkey = .{ .bytes = .{0xBB} ** 32 };
    var acc_key: Pubkey = .{ .bytes = .{0xCC} ** 32 };

    var acc_buf: [1024]u8 align(16) = undefined;
    const acc = mkAcc(&acc_buf, &owner_pk, false, true, @sizeOf(TestState), &acc_key);
    // Populate state: authority=signer_pk, initialized=1.
    @memcpy(acc_buf[FieldOffset.data..][0..32], &signer_pk.bytes);
    acc_buf[FieldOffset.data + 32] = 7; // bump
    acc_buf[FieldOffset.data + 33] = 1; // initialized

    var signer_buf: [1024]u8 align(16) = undefined;
    const signer = mkAcc(&signer_buf, &core.SYSTEM_PROGRAM_ID, true, false, 0, &signer_pk);

    const state = try openState(TestState, acc, .{
        .owner = &owner_pk,
        .authority = signer,
        .authority_field = "authority",
    });
    try testing.expectEqual(@as(u8, 7), state.bump);
}

test "openState: wrong owner -> IllegalOwner" {
    var wrong_owner: Pubkey = .{ .bytes = .{0x11} ** 32 };
    var expected_owner: Pubkey = .{ .bytes = .{0x22} ** 32 };
    var acc_key: Pubkey = .{ .bytes = .{0xCC} ** 32 };

    var buf: [1024]u8 align(16) = undefined;
    const acc = mkAcc(&buf, &wrong_owner, false, true, @sizeOf(TestState), &acc_key);
    buf[FieldOffset.data + 33] = 1; // initialized

    try testing.expectError(error.IllegalOwner, openState(TestState, acc, .{
        .owner = &expected_owner,
    }));
}

test "openState: zero discriminator -> UninitializedAccount" {
    var owner_pk: Pubkey = .{ .bytes = .{0xAA} ** 32 };
    var acc_key: Pubkey = .{ .bytes = .{0xCC} ** 32 };

    var buf: [1024]u8 align(16) = undefined;
    const acc = mkAcc(&buf, &owner_pk, false, true, @sizeOf(TestState), &acc_key);
    // initialized stays at 0 (data is memset to zero)

    try testing.expectError(error.UninitializedAccount, openState(TestState, acc, .{
        .owner = &owner_pk,
    }));
}

test "openState: authority mismatch -> IncorrectAuthority" {
    var owner_pk: Pubkey = .{ .bytes = .{0xAA} ** 32 };
    var stored_authority: Pubkey = .{ .bytes = .{0xBB} ** 32 };
    var different_signer_pk: Pubkey = .{ .bytes = .{0xDD} ** 32 };
    var acc_key: Pubkey = .{ .bytes = .{0xCC} ** 32 };

    var acc_buf: [1024]u8 align(16) = undefined;
    const acc = mkAcc(&acc_buf, &owner_pk, false, true, @sizeOf(TestState), &acc_key);
    @memcpy(acc_buf[FieldOffset.data..][0..32], &stored_authority.bytes);
    acc_buf[FieldOffset.data + 33] = 1; // initialized

    var signer_buf: [1024]u8 align(16) = undefined;
    const signer = mkAcc(&signer_buf, &core.SYSTEM_PROGRAM_ID, true, false, 0, &different_signer_pk);

    try testing.expectError(error.IncorrectAuthority, openState(TestState, acc, .{
        .owner = &owner_pk,
        .authority = signer,
        .authority_field = "authority",
    }));
}

test "openState: empty discriminator_field skips the init check" {
    var owner_pk: Pubkey = .{ .bytes = .{0xAA} ** 32 };
    var acc_key: Pubkey = .{ .bytes = .{0xCC} ** 32 };

    var buf: [1024]u8 align(16) = undefined;
    const acc = mkAcc(&buf, &owner_pk, false, true, @sizeOf(TestState), &acc_key);
    // initialized = 0, but we pass discriminator_field = ""

    const state = try openState(TestState, acc, .{
        .owner = &owner_pk,
        .discriminator_field = "",
    });
    try testing.expectEqual(@as(u8, 0), state.initialized);
}

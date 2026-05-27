//! Declarative account-list unpacking.
//!
//! Every Solana handler we have written so far starts with the same four
//! statements:
//!
//!   if (ctx.accounts.len < N) return error.NotEnoughAccountKeys;
//!   const a = ctx.accounts[0];
//!   const b = ctx.accounts[1];
//!   ...
//!   try validate.mustBeSigner(a);
//!   try validate.mustBeWritable(b);
//!   try validate.mustBeSystemProgram(c);
//!
//! `accounts.unpack` collapses that into a single comptime-driven call:
//!
//!   const a = try accounts.unpack(ctx, .{
//!       .authority      = .signer_writable,
//!       .vault          = .writable,
//!       .system_program = .system_program,
//!   });
//!   // a.authority, a.vault, a.system_program are AccountInfo.
//!
//! `inline for` unrolls the field loop at comptime, so the generated SBPF
//! is byte-identical to the hand-written version above — same CU.
//!
//! Design constraints honoured:
//!   - No proc macros, no #[derive]. The spec is a plain anonymous struct
//!     of Zig enum literals; you can read it as data.
//!   - Roles are limited to *shape* checks (count + signer + writable +
//!     well-known program-id). Program-specific checks (ownership, key,
//!     state discriminator) stay in the handler where they belong.
//!   - Failure errors are the standard `ProgramError`s the runtime expects.

const std = @import("std");
const core = @import("core/root.zig");
const account = @import("account/root.zig");

const ExecutionContext = core.entrypoint.ExecutionContext;
const AccountInfo = account.AccountInfo;
const validate = account.validate;
const ProgramError = core.ProgramError;

/// Role descriptor for one entry in an `unpack` spec. Enum tags expand at
/// comptime to the corresponding validate.* call (or to nothing for `.any`).
pub const Role = enum {
    /// No role check beyond presence. Useful for accounts whose semantics
    /// the handler will check itself (e.g. "owned by program + state.init=1").
    any,
    /// `is_writable == true`.
    writable,
    /// `is_signer == true`.
    signer,
    /// `is_signer && is_writable`.
    signer_writable,
    /// `key == 11111111111111111111111111111111`.
    system_program,
    /// `key == SysvarRent...`.
    sysvar_rent,
    /// `key == SysvarC1ock...`.
    sysvar_clock,
};

// Short prefix-free aliases for compact spec literals. The verbose
// `Role.x` form remains available for users who prefer to be explicit.
//
//     .authority = accounts.sw          // signer + writable
//     .vault     = accounts.w           // writable
//     .sys_prog  = accounts.sys         // System Program id
pub const any = Role.any;
pub const w = Role.writable;
pub const s = Role.signer;
pub const sw = Role.signer_writable;
pub const sys = Role.system_program;
pub const rent = Role.sysvar_rent;
pub const clock = Role.sysvar_clock;

/// Build the typed output struct for a given spec. Each field of the spec
/// becomes a field of the output, same name, but typed as `AccountInfo`.
fn Unpacked(comptime Spec: type) type {
    const ti = @typeInfo(Spec).@"struct";
    comptime var names: [ti.fields.len][]const u8 = undefined;
    comptime var types: [ti.fields.len]type = undefined;
    inline for (ti.fields, 0..) |f, i| {
        names[i] = f.name;
        types[i] = AccountInfo;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

/// Verify one account against its declared role. Inlined; one or two
/// boolean checks per role at most.
inline fn checkRole(acc: AccountInfo, role: Role) ProgramError!void {
    return switch (role) {
        .any => {},
        .writable => validate.mustBeWritable(acc),
        .signer => validate.mustBeSigner(acc),
        .signer_writable => {
            try validate.mustBeSigner(acc);
            try validate.mustBeWritable(acc);
        },
        .system_program => validate.mustBeSystemProgram(acc),
        .sysvar_rent => validate.mustHaveKey(acc, &core.SYSVAR_RENT_ID),
        .sysvar_clock => validate.mustHaveKey(acc, &core.SYSVAR_CLOCK_ID),
    };
}

/// Decode `ctx.accounts` into a named bundle, validating each entry's role.
///
/// `spec` is an anonymous struct literal whose field NAMES become the output
/// names and whose field VALUES are `Role` enum literals. Order matters —
/// the i-th spec field is bound to `ctx.accounts[i]`. Passing fewer accounts
/// than the spec declares yields `error.NotEnoughAccountKeys`.
///
/// All work is done at comptime; the runtime cost is exactly one length
/// check plus the role checks you'd write by hand.
pub fn unpack(ctx: *const ExecutionContext, comptime spec: anytype) ProgramError!Unpacked(@TypeOf(spec)) {
    const Spec = @TypeOf(spec);
    const ti = @typeInfo(Spec).@"struct";
    if (ctx.accounts.len < ti.fields.len) return error.NotEnoughAccountKeys;

    var out: Unpacked(Spec) = undefined;
    inline for (ti.fields, 0..) |f, i| {
        const role: Role = @field(spec, f.name);
        const acc = ctx.accounts[i];
        try checkRole(acc, role);
        @field(out, f.name) = acc;
    }
    return out;
}

// =====================================================================
// Tests.
// =====================================================================

const FieldOffset = account.info.FieldOffset;

fn makeAccount(buf: *[256]u8, signer: bool, writable: bool, key: *const core.Pubkey) AccountInfo {
    @memset(buf, 0);
    buf[FieldOffset.is_signer] = if (signer) 1 else 0;
    buf[FieldOffset.is_writable] = if (writable) 1 else 0;
    @memcpy(buf[FieldOffset.key..][0..32], &key.bytes);
    return .{ .raw = buf };
}

test "unpack: happy path binds names and runs role checks" {
    var b0: [256]u8 align(16) = undefined;
    var b1: [256]u8 align(16) = undefined;
    var b2: [256]u8 align(16) = undefined;

    const some_key: core.Pubkey = .{ .bytes = .{1} ** 32 };
    const accs = [_]AccountInfo{
        makeAccount(&b0, true, true, &some_key),
        makeAccount(&b1, false, true, &some_key),
        makeAccount(&b2, false, false, &core.SYSTEM_PROGRAM_ID),
    };

    const ctx: ExecutionContext = .{
        .program_id = &core.Pubkey.ZERO,
        .accounts = &accs,
        .data = &.{},
    };

    const a = try unpack(&ctx, .{
        .authority = Role.signer_writable,
        .vault = Role.writable,
        .system_program = Role.system_program,
    });

    // Field bindings work and refer to the same underlying buffers.
    try std.testing.expect(a.authority.isSigner());
    try std.testing.expect(a.vault.isWritable());
    try std.testing.expect(core.Pubkey.equals(a.system_program.key(), &core.SYSTEM_PROGRAM_ID));
}

test "unpack: missing account returns NotEnoughAccountKeys" {
    const ctx: ExecutionContext = .{
        .program_id = &core.Pubkey.ZERO,
        .accounts = &.{},
        .data = &.{},
    };
    try std.testing.expectError(error.NotEnoughAccountKeys, unpack(&ctx, .{
        .x = Role.signer,
    }));
}

test "unpack: wrong role surfaces the right error" {
    var b: [256]u8 align(16) = undefined;
    const k: core.Pubkey = .{ .bytes = .{0} ** 32 };
    const accs = [_]AccountInfo{makeAccount(&b, false, false, &k)}; // not signer

    const ctx: ExecutionContext = .{
        .program_id = &core.Pubkey.ZERO,
        .accounts = &accs,
        .data = &.{},
    };
    try std.testing.expectError(error.MissingRequiredSignature, unpack(&ctx, .{
        .who = Role.signer,
    }));
}

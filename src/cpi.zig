//! Cross-Program Invocation (CPI).
//!
//! The Solana runtime exposes one CPI primitive: `sol_invoke_signed_c`. It
//! takes an `Instruction` (program-id + accounts-metadata + data), a parallel
//! list of `AccountInfo`s already known to the calling program, and an
//! optional list of "signer seeds" tuples — one tuple per PDA the calling
//! program is signing for. The runtime hashes those seeds back into the same
//! address and grants signer status for that account during the inner call.
//!
//! This module exposes two high-level functions:
//!
//!   * `invoke(ix, account_infos)` — call without PDA signing
//!   * `invokeSigned(ix, account_infos, signer_seeds)` — call with PDA signing
//!
//! Plus an `Instruction` struct that builds the C-shaped payload from
//! Zig-native types. Per-program wrapper modules (`programs/system.zig`,
//! etc.) sit on top.

const std = @import("std");
const core = @import("core/root.zig");
const account = @import("account/root.zig");

const Pubkey = core.Pubkey;
const AccountInfo = account.AccountInfo;
const syscalls = core.syscalls;
const InstructionC = syscalls.InstructionC;
const AccountInfoC = syscalls.AccountInfoC;
const AccountMetaC = syscalls.AccountMetaC;
const SignerSeedC = syscalls.SignerSeedC;
const SignerSeedsC = syscalls.SignerSeedsC;
const SolBytes = syscalls.SolBytes;
const ProgramError = core.ProgramError;

/// Account metadata for a CPI. Mirrors `solana_program::instruction::AccountMeta`
/// but as a flat value type (no allocator). The caller is responsible for
/// passing the *same* account in the parallel `account_infos` slice.
pub const AccountMeta = struct {
    pubkey: *const Pubkey,
    is_writable: bool,
    is_signer: bool,

    pub fn writable(pubkey: *const Pubkey) AccountMeta {
        return .{ .pubkey = pubkey, .is_writable = true, .is_signer = false };
    }
    pub fn readonly(pubkey: *const Pubkey) AccountMeta {
        return .{ .pubkey = pubkey, .is_writable = false, .is_signer = false };
    }
    pub fn signer(pubkey: *const Pubkey) AccountMeta {
        return .{ .pubkey = pubkey, .is_writable = false, .is_signer = true };
    }
    pub fn writableSigner(pubkey: *const Pubkey) AccountMeta {
        return .{ .pubkey = pubkey, .is_writable = true, .is_signer = true };
    }
};

/// A complete CPI target. Built on the stack; no heap.
pub const Instruction = struct {
    program_id: *const Pubkey,
    accounts: []const AccountMeta,
    data: []const u8,
};

/// Convert one `AccountInfo` (which points into the loader's input buffer)
/// into the C ABI shape `sol_invoke_signed_c` expects.
inline fn toAccountInfoC(acc: AccountInfo) AccountInfoC {
    return .{
        .key = @ptrCast(acc.key()),
        .lamports = acc.lamports(),
        .data_len = acc.dataLen(),
        .data = (acc.raw + @import("account/info.zig").FieldOffset.data),
        .owner = @ptrCast(acc.owner()),
        .rent_epoch = 0, // ignored by the modern runtime
        .is_signer = acc.isSigner(),
        .is_writable = acc.isWritable(),
        .executable = acc.executable(),
    };
}

/// Hard upper bound on the number of accounts a CPI can reference. The
/// runtime allows up to 256 but in practice 16 is plenty for any single
/// instruction we'd build from Zig. Keep this small to keep stack usage low.
pub const MAX_CPI_ACCOUNTS: usize = 16;

/// Invoke another program without PDA signing.
pub fn invoke(ix: Instruction, account_infos: []const AccountInfo) ProgramError!void {
    return invokeSigned(ix, account_infos, &.{});
}

/// Invoke another program, optionally signing as one or more PDAs.
///
/// `signer_seeds` is a list of seed-tuples; each tuple is the same seed list
/// you'd pass to `pda.createProgramAddress` (no trailing bump byte — the bump
/// goes in the tuple too if you want it). For each tuple, the runtime hashes
/// it back to a PDA and grants signer status to that address in the inner
/// call frame. Programs sign for *themselves* this way; you can't sign for
/// arbitrary keys.
pub fn invokeSigned(
    ix: Instruction,
    account_infos: []const AccountInfo,
    signer_seeds: []const []const []const u8,
) ProgramError!void {
    if (ix.accounts.len > MAX_CPI_ACCOUNTS) return error.NotEnoughAccountKeys;
    if (account_infos.len > MAX_CPI_ACCOUNTS) return error.NotEnoughAccountKeys;

    // Pack `AccountMeta`s into the C-ABI shape.
    var metas: [MAX_CPI_ACCOUNTS]AccountMetaC = undefined;
    for (ix.accounts, 0..) |m, i| {
        metas[i] = .{
            .pubkey = @ptrCast(m.pubkey),
            .is_writable = m.is_writable,
            .is_signer = m.is_signer,
        };
    }

    // Pack `AccountInfo`s.
    var infos: [MAX_CPI_ACCOUNTS]AccountInfoC = undefined;
    for (account_infos, 0..) |a, i| infos[i] = toAccountInfoC(a);

    // Pack signer seeds. Each tuple is a contiguous block of SolBytes.
    // We allocate worst-case storage on the stack: 8 tuples × MAX_SEEDS seeds.
    const MAX_TUPLES: usize = 8;
    const MAX_SEEDS_PER_TUPLE: usize = @import("pda.zig").MAX_SEEDS;
    if (signer_seeds.len > MAX_TUPLES) return error.InvalidSeeds;

    var seed_storage: [MAX_TUPLES * MAX_SEEDS_PER_TUPLE]SignerSeedC = undefined;
    var tuples: [MAX_TUPLES]SignerSeedsC = undefined;
    var cursor: usize = 0;
    for (signer_seeds, 0..) |tuple, ti| {
        if (tuple.len > MAX_SEEDS_PER_TUPLE) return error.MaxSeedLengthExceeded;
        const base = cursor;
        for (tuple) |s| {
            if (s.len > 32) return error.MaxSeedLengthExceeded;
            seed_storage[cursor] = .{ .addr = s.ptr, .len = s.len };
            cursor += 1;
        }
        tuples[ti] = .{
            .addr = @ptrCast(&seed_storage[base]),
            .len = @intCast(tuple.len),
        };
    }

    const ix_c = InstructionC{
        .program_id = @ptrCast(ix.program_id),
        .accounts = &metas,
        .accounts_len = @intCast(ix.accounts.len),
        .data = ix.data.ptr,
        .data_len = @intCast(ix.data.len),
    };

    const rc = syscalls.sol_invoke_signed_c(
        &ix_c,
        &infos,
        @intCast(account_infos.len),
        &tuples,
        @intCast(signer_seeds.len),
    );
    if (rc != 0) {
        // The runtime returns the inner program's error code verbatim. We
        // surface a generic Custom here; callers that need the precise code
        // should call the syscall directly.
        return error.Custom;
    }
}

test "AccountMeta constructors set the right flags" {
    var pk: Pubkey = .{ .bytes = .{0} ** 32 };
    try std.testing.expect(AccountMeta.writable(&pk).is_writable);
    try std.testing.expect(!AccountMeta.writable(&pk).is_signer);
    try std.testing.expect(AccountMeta.signer(&pk).is_signer);
    try std.testing.expect(!AccountMeta.signer(&pk).is_writable);
    try std.testing.expect(AccountMeta.writableSigner(&pk).is_signer);
    try std.testing.expect(AccountMeta.writableSigner(&pk).is_writable);
    try std.testing.expect(!AccountMeta.readonly(&pk).is_signer);
    try std.testing.expect(!AccountMeta.readonly(&pk).is_writable);
}

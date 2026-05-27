//! Typed wrappers around the System Program's instruction set.
//!
//! The System Program (`11111111111111111111111111111111`) is a built-in,
//! universally-trusted Solana program. It owns every account at creation
//! time and is the only program that can:
//!
//!   - create new accounts (`CreateAccount`)
//!   - hand them off to a new owner (`Assign`)
//!   - transfer lamports between accounts that the caller signs for
//!     (`Transfer`)
//!   - reserve space inside an existing account (`Allocate`)
//!
//! For accounts your program already owns, you don't need a CPI to move
//! lamports — you can directly mutate `lamports().*` on both sides (see
//! `account/lamports.zig`). The System Program is only needed when crossing
//! ownership boundaries.
//!
//! Instructions here build `cpi.Instruction` values; the caller invokes them
//! through `cpi.invoke` or `cpi.invokeSigned`. Encoding is Borsh: u32 tag
//! followed by little-endian fields, with no length prefixes for fixed-size
//! payloads.

const std = @import("std");
const core = @import("../core/root.zig");
const cpi = @import("../cpi.zig");

const Pubkey = core.Pubkey;
const AccountInfo = @import("../account/info.zig").AccountInfo;
const ProgramError = core.ProgramError;
const SYSTEM_PROGRAM_ID = core.SYSTEM_PROGRAM_ID;

/// Instruction tags, per `solana_system_interface::SystemInstruction`.
pub const Tag = enum(u32) {
    create_account = 0,
    assign = 1,
    transfer = 2,
    create_account_with_seed = 3,
    advance_nonce_account = 4,
    withdraw_nonce_account = 5,
    initialize_nonce_account = 6,
    authorize_nonce_account = 7,
    allocate = 8,
    allocate_with_seed = 9,
    assign_with_seed = 10,
    transfer_with_seed = 11,
    upgrade_nonce_account = 12,
};

// =====================================================================
// Instruction builders. Each returns a `cpi.Instruction` whose `data`
// points into a stack buffer owned by the caller — the helper takes that
// buffer as an out-parameter so the lifetime is explicit.
// =====================================================================

/// `CreateAccount { lamports, space, owner }` — total 52 bytes of data.
pub const CREATE_ACCOUNT_DATA_LEN: usize = 4 + 8 + 8 + 32;

pub fn createAccount(
    from: *const Pubkey,
    new: *const Pubkey,
    lamports: u64,
    space: u64,
    owner: *const Pubkey,
    data_buf: *[CREATE_ACCOUNT_DATA_LEN]u8,
    accounts_buf: *[2]cpi.AccountMeta,
) cpi.Instruction {
    std.mem.writeInt(u32, data_buf[0..4], @intFromEnum(Tag.create_account), .little);
    std.mem.writeInt(u64, data_buf[4..12], lamports, .little);
    std.mem.writeInt(u64, data_buf[12..20], space, .little);
    @memcpy(data_buf[20..52], &owner.bytes);

    accounts_buf[0] = cpi.AccountMeta.writableSigner(from);
    accounts_buf[1] = cpi.AccountMeta.writableSigner(new);

    return .{
        .program_id = &SYSTEM_PROGRAM_ID,
        .accounts = accounts_buf,
        .data = data_buf,
    };
}

/// `Transfer { lamports }` — total 12 bytes.
pub const TRANSFER_DATA_LEN: usize = 4 + 8;

pub fn transfer(
    from: *const Pubkey,
    to: *const Pubkey,
    lamports: u64,
    data_buf: *[TRANSFER_DATA_LEN]u8,
    accounts_buf: *[2]cpi.AccountMeta,
) cpi.Instruction {
    std.mem.writeInt(u32, data_buf[0..4], @intFromEnum(Tag.transfer), .little);
    std.mem.writeInt(u64, data_buf[4..12], lamports, .little);

    accounts_buf[0] = cpi.AccountMeta.writableSigner(from);
    accounts_buf[1] = cpi.AccountMeta.writable(to);

    return .{
        .program_id = &SYSTEM_PROGRAM_ID,
        .accounts = accounts_buf,
        .data = data_buf,
    };
}

/// `Allocate { space }` — total 12 bytes. Sets the account's data length.
pub const ALLOCATE_DATA_LEN: usize = 4 + 8;

pub fn allocate(
    account: *const Pubkey,
    space: u64,
    data_buf: *[ALLOCATE_DATA_LEN]u8,
    accounts_buf: *[1]cpi.AccountMeta,
) cpi.Instruction {
    std.mem.writeInt(u32, data_buf[0..4], @intFromEnum(Tag.allocate), .little);
    std.mem.writeInt(u64, data_buf[4..12], space, .little);

    accounts_buf[0] = cpi.AccountMeta.writableSigner(account);

    return .{
        .program_id = &SYSTEM_PROGRAM_ID,
        .accounts = accounts_buf,
        .data = data_buf,
    };
}

/// `Assign { owner }` — total 36 bytes. Changes the account's owner.
pub const ASSIGN_DATA_LEN: usize = 4 + 32;

pub fn assign(
    account: *const Pubkey,
    owner: *const Pubkey,
    data_buf: *[ASSIGN_DATA_LEN]u8,
    accounts_buf: *[1]cpi.AccountMeta,
) cpi.Instruction {
    std.mem.writeInt(u32, data_buf[0..4], @intFromEnum(Tag.assign), .little);
    @memcpy(data_buf[4..36], &owner.bytes);

    accounts_buf[0] = cpi.AccountMeta.writableSigner(account);

    return .{
        .program_id = &SYSTEM_PROGRAM_ID,
        .accounts = accounts_buf,
        .data = data_buf,
    };
}

// =====================================================================
// High-level orchestration helpers.
// =====================================================================

/// Create a fresh account owned by `owner`, funded with `lamports`, sized
/// to `space` bytes, signing as the PDA whose seeds are `signer_seeds`.
///
/// Use this when the new account itself is a PDA — i.e. the calling program
/// owns the address space. This is the single most common pattern in the
/// vault / escrow / config-PDA / state-PDA family of programs.
///
/// `signer_seeds` is the seed tuple **including the bump byte at the end**:
///
///     try system.createPdaAccount(
///         payer, vault, system_program,
///         rent_lamports, @sizeOf(State), program_id,
///         &.{ "vault", &authority.key().bytes, &[_]u8{bump} },
///     );
pub fn createPdaAccount(
    payer: AccountInfo,
    new_account: AccountInfo,
    system_program: AccountInfo,
    lamports: u64,
    space: u64,
    owner: *const Pubkey,
    signer_seeds: []const []const u8,
) ProgramError!void {
    var data_buf: [CREATE_ACCOUNT_DATA_LEN]u8 = undefined;
    var accs_buf: [2]cpi.AccountMeta = undefined;
    const ix = createAccount(
        payer.key(),
        new_account.key(),
        lamports,
        space,
        owner,
        &data_buf,
        &accs_buf,
    );
    try cpi.invokeSigned(
        ix,
        &.{ payer, new_account, system_program },
        &.{signer_seeds},
    );
}

/// Convenience for the basic `System::Transfer` CPI. Saves the caller from
/// allocating the data/accounts buffers themselves.
pub fn transferLamports(
    from: AccountInfo,
    to: AccountInfo,
    system_program: AccountInfo,
    amount: u64,
) ProgramError!void {
    var data_buf: [TRANSFER_DATA_LEN]u8 = undefined;
    var accs_buf: [2]cpi.AccountMeta = undefined;
    const ix = transfer(from.key(), to.key(), amount, &data_buf, &accs_buf);
    try cpi.invoke(ix, &.{ from, to, system_program });
}

// =====================================================================
// Tests — verify the byte-for-byte encoding of each instruction.
// =====================================================================

test "transfer encoding matches Borsh format" {
    var data: [TRANSFER_DATA_LEN]u8 = undefined;
    var accs: [2]cpi.AccountMeta = undefined;
    const from: Pubkey = .{ .bytes = .{1} ** 32 };
    const to: Pubkey = .{ .bytes = .{2} ** 32 };
    _ = transfer(&from, &to, 0xDEAD_BEEF_CAFE_BABE, &data, &accs);

    // tag = 2 (Transfer), then u64 LE.
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, data[0..4], .little));
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE_BABE), std.mem.readInt(u64, data[4..12], .little));
}

test "createAccount encoding" {
    var data: [CREATE_ACCOUNT_DATA_LEN]u8 = undefined;
    var accs: [2]cpi.AccountMeta = undefined;
    const from: Pubkey = .{ .bytes = .{1} ** 32 };
    const new: Pubkey = .{ .bytes = .{2} ** 32 };
    const owner: Pubkey = .{ .bytes = .{3} ** 32 };
    _ = createAccount(&from, &new, 1_000_000, 48, &owner, &data, &accs);

    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, data[0..4], .little));
    try std.testing.expectEqual(@as(u64, 1_000_000), std.mem.readInt(u64, data[4..12], .little));
    try std.testing.expectEqual(@as(u64, 48), std.mem.readInt(u64, data[12..20], .little));
    try std.testing.expectEqualSlices(u8, &owner.bytes, data[20..52]);
}

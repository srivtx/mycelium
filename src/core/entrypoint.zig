//! Entrypoint scaffolding.
//!
//! Solana programs export a single C function:
//!
//!     pub export fn entrypoint(input: [*]u8) callconv(.c) u64
//!
//! `declareEntrypoint(handler)` returns a wrapper that:
//!   1. parses the loader's input buffer into an `ExecutionContext`,
//!   2. invokes `handler(ctx)`,
//!   3. maps the resulting `!void` to the `u64` exit code Solana expects.
//!
//! Usage:
//!
//!     const mycelium = @import("mycelium");
//!     fn process(ctx: *const mycelium.core.entrypoint.ExecutionContext)
//!         mycelium.ProgramResult { ... }
//!     comptime { mycelium.core.entrypoint.declareEntrypoint(process); }
//!
//! The parser is `noinline` so its 8 KB of stack (`accounts_buf`) stays in a
//! dedicated frame, leaving the user handler with a clean ~4 KB to work with.

const std = @import("std");
const builtin = @import("builtin");

const abi = @import("abi.zig");
const errors = @import("error.zig");
const Pubkey = @import("pubkey.zig").Pubkey;
const AccountInfo = @import("../account/info.zig").AccountInfo;

const MAX_ACCOUNTS = abi.MAX_TX_ACCOUNTS;

pub const ExecutionContext = struct {
    program_id: *const Pubkey,
    accounts: []const AccountInfo,
    data: []const u8,
};

pub const Handler = *const fn (*const ExecutionContext) errors.ProgramResult;

/// Registers an `entrypoint` C symbol that drives `handler`. Call this from
/// your program's root file in a `comptime` block.
///
/// `custom_code_for_panic` is the u32 returned when the handler errors with
/// `error.Custom`. (Pinocchio-style: each program decides its own custom
/// code mapping; we keep a single sentinel for simplicity.)
pub fn declareEntrypoint(comptime handler: Handler) void {
    declareEntrypointWithCustom(handler, 0);
}

/// Like `declareEntrypoint` but lets the program supply a custom-code value
/// when the handler returns `error.Custom`.
pub fn declareEntrypointWithCustom(
    comptime handler: Handler,
    comptime custom_code: u32,
) void {
    const Trampoline = struct {
        pub fn entrypoint(input: [*]u8) callconv(.c) u64 {
            var accounts_buf: [MAX_ACCOUNTS]AccountInfo = undefined;
            var ctx: ExecutionContext = undefined;
            parseInput(input, &accounts_buf, &ctx) catch |e| {
                return errors.errorToU64(e, custom_code);
            };
            handler(&ctx) catch |e| {
                return errors.errorToU64(e, custom_code);
            };
            return 0;
        }
    };
    @export(&Trampoline.entrypoint, .{ .name = "entrypoint", .linkage = .strong });
}

/// Decodes the loader's input buffer into `out_ctx`.
///
/// We use an out-parameter rather than `return ExecutionContext` because the
/// SBPF/BPF ABI does not support aggregate returns (sret); LLVM refuses to
/// codegen them and errors out at link time.
///
/// **Invariants the loader provides**:
///   - `input` is 8-byte aligned (actually 16-aligned, but we only need 8).
///   - All slices we return point back into `input`; the loader keeps it alive
///     for the program's lifetime.
///
/// **Invariants we enforce**:
///   - `num_accounts <= MAX_ACCOUNTS`. Programs with more accounts can change
///     this bound at comptime by re-declaring the entrypoint module.
pub noinline fn parseInput(
    input: [*]u8,
    accounts_buf: *[MAX_ACCOUNTS]AccountInfo,
    out_ctx: *ExecutionContext,
) errors.ProgramError!void {
    var off: usize = 0;

    // ---- num_accounts ----
    const num_accounts: usize = @intCast(readU64(input, off));
    off += 8;
    if (num_accounts > MAX_ACCOUNTS) return error.NotEnoughAccountKeys;

    // ---- accounts ----
    var i: usize = 0;
    while (i < num_accounts) : (i += 1) {
        const dup = input[off];
        off += 1;
        if (dup == abi.NON_DUP_MARKER) {
            // Unique account. record_base points to `is_signer` (one past dup).
            const record_base = input + off;
            accounts_buf[i] = .{ .raw = record_base };

            // Header from record_base = is_signer(1) + is_writable(1) + executable(1)
            // + original_data_len(4) + key(32) + owner(32) + lamports(8) + data_len(8)
            // = 87 bytes. Advance past it; `off - 8` now points at data_len.
            off += 87;
            const data_len: usize = @intCast(readU64(input, off - 8));
            off += data_len;
            off = std.mem.alignForward(usize, off, 8);
            off += abi.MAX_PERMITTED_DATA_INCREASE;
            off += 8; // rent_epoch
        } else {
            // Duplicate. Copy the original's pointer.
            const orig_idx: usize = @intCast(dup);
            if (orig_idx >= i) return error.InvalidAccountData;
            accounts_buf[i] = accounts_buf[orig_idx];
            // 7 padding bytes follow the dup marker.
            off += 7;
        }
    }

    // ---- instruction data ----
    const data_len: usize = @intCast(readU64(input, off));
    off += 8;
    const data_ptr = input + off;
    off += data_len;

    // ---- program_id ----
    const program_id: *const Pubkey = @ptrCast(input + off);

    out_ctx.* = .{
        .program_id = program_id,
        .accounts = accounts_buf[0..num_accounts],
        .data = data_ptr[0..data_len],
    };
}

inline fn readU64(input: [*]u8, off: usize) u64 {
    const p: *align(1) const u64 = @ptrCast(input + off);
    return p.*;
}

// =====================================================================
// Tests: build a synthetic input buffer the parser should accept.
// =====================================================================

fn buildTestInput(
    buf: *[]u8,
    program_id: Pubkey,
    accounts: []const struct {
        is_signer: bool = false,
        is_writable: bool = false,
        executable: bool = false,
        key: Pubkey,
        owner: Pubkey,
        lamports: u64 = 0,
        data: []const u8 = &.{},
    },
    ix_data: []const u8,
) usize {
    var off: usize = 0;
    std.mem.writeInt(u64, buf.*[off..][0..8], accounts.len, .little);
    off += 8;

    for (accounts) |a| {
        // Unique account. Offsets below are from `off`, which sits at the
        // dup byte's slot; record_base = `off + 1`.
        buf.*[off] = abi.NON_DUP_MARKER;
        off += 1;
        buf.*[off + 0] = if (a.is_signer) 1 else 0;
        buf.*[off + 1] = if (a.is_writable) 1 else 0;
        buf.*[off + 2] = if (a.executable) 1 else 0;
        // 4 bytes of original_data_len/padding at offset +3.
        std.mem.writeInt(u32, buf.*[off + 3 ..][0..4], @intCast(a.data.len), .little);
        @memcpy(buf.*[off + 7 .. off + 39], &a.key.bytes);
        @memcpy(buf.*[off + 39 .. off + 71], &a.owner.bytes);
        std.mem.writeInt(u64, buf.*[off + 71 ..][0..8], a.lamports, .little);
        std.mem.writeInt(u64, buf.*[off + 79 ..][0..8], @intCast(a.data.len), .little);
        @memcpy(buf.*[off + 87 .. off + 87 + a.data.len], a.data);

        var inner: usize = off + 87 + a.data.len;
        inner = std.mem.alignForward(usize, inner, 8);
        inner += abi.MAX_PERMITTED_DATA_INCREASE;
        inner += 8; // rent_epoch (zeroed)
        off = inner;
    }

    std.mem.writeInt(u64, buf.*[off..][0..8], ix_data.len, .little);
    off += 8;
    @memcpy(buf.*[off .. off + ix_data.len], ix_data);
    off += ix_data.len;

    @memcpy(buf.*[off .. off + 32], &program_id.bytes);
    off += 32;

    return off;
}

test "parseInput reads one account + instruction data" {
    const data_bytes = [_]u8{ 0x42, 0x43, 0x44 };
    var key: Pubkey = undefined;
    for (0..32) |i| key.bytes[i] = @intCast(i);
    var owner: Pubkey = undefined;
    for (0..32) |i| owner.bytes[i] = @intCast(i + 32);
    var prog: Pubkey = undefined;
    for (0..32) |i| prog.bytes[i] = @intCast(0xC0 + (i & 0x1F));

    var raw_buf: [32 * 1024]u8 align(16) = undefined;
    var bs: []u8 = raw_buf[0..];
    _ = buildTestInput(&bs, prog, &.{.{
        .is_signer = true,
        .is_writable = true,
        .key = key,
        .owner = owner,
        .lamports = 5_000_000,
        .data = &data_bytes,
    }}, "INCR");

    var accounts_buf: [MAX_ACCOUNTS]AccountInfo = undefined;
    var ctx: ExecutionContext = undefined;
    try parseInput(&raw_buf, &accounts_buf, &ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.accounts.len);
    try std.testing.expect(ctx.accounts[0].isSigner());
    try std.testing.expect(ctx.accounts[0].isWritable());
    try std.testing.expectEqual(@as(u64, 5_000_000), ctx.accounts[0].lamports().*);
    try std.testing.expectEqualSlices(u8, &data_bytes, ctx.accounts[0].data());
    try std.testing.expectEqual(@as(u8, 5), ctx.accounts[0].key().bytes[5]);
    try std.testing.expectEqualSlices(u8, "INCR", ctx.data);
    try std.testing.expectEqual(@as(u8, 0xC0), ctx.program_id.bytes[0]);
}

test "parseInput handles duplicate accounts" {
    var key: Pubkey = .{ .bytes = .{0x11} ** 32 };
    var owner: Pubkey = .{ .bytes = .{0x22} ** 32 };
    var prog: Pubkey = .{ .bytes = .{0xCC} ** 32 };

    // Build a buffer with two account entries: one unique, one dup pointing at idx 0.
    var raw_buf: [32 * 1024]u8 align(16) = undefined;
    @memset(&raw_buf, 0);

    var off: usize = 0;
    std.mem.writeInt(u64, raw_buf[off..][0..8], 2, .little);
    off += 8;

    // Account 0: unique.
    raw_buf[off] = abi.NON_DUP_MARKER;
    off += 1;
    raw_buf[off + 0] = 1; // signer
    raw_buf[off + 1] = 1; // writable
    @memcpy(raw_buf[off + 7 .. off + 39], &key.bytes);
    @memcpy(raw_buf[off + 39 .. off + 71], &owner.bytes);
    std.mem.writeInt(u64, raw_buf[off + 71 ..][0..8], 1000, .little);
    std.mem.writeInt(u64, raw_buf[off + 79 ..][0..8], 0, .little);
    var inner: usize = off + 87;
    inner = std.mem.alignForward(usize, inner, 8);
    inner += abi.MAX_PERMITTED_DATA_INCREASE;
    inner += 8; // rent_epoch
    off = inner;

    // Account 1: dup of 0.
    raw_buf[off] = 0; // index 0
    off += 8; // 1 byte marker + 7 padding

    // ix data
    std.mem.writeInt(u64, raw_buf[off..][0..8], 0, .little);
    off += 8;
    @memcpy(raw_buf[off .. off + 32], &prog.bytes);

    var accounts_buf: [MAX_ACCOUNTS]AccountInfo = undefined;
    var ctx: ExecutionContext = undefined;
    try parseInput(&raw_buf, &accounts_buf, &ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.accounts.len);
    // Duplicate must share the same `raw` pointer.
    try std.testing.expect(ctx.accounts[0].raw == ctx.accounts[1].raw);
    try std.testing.expect(ctx.accounts[1].isSigner());
}

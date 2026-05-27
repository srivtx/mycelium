//! Comptime instruction dispatch.
//!
//! The user declares their instruction set as a tagged `union(enum(u8))`,
//! provides a handler for each variant, and `mycelium.dispatch.program()`
//! returns an `entrypoint` symbol that decodes the first byte of instruction
//! data as the discriminator, decodes the variant payload, and calls the
//! matching handler.
//!
//! Example:
//!
//!     const Instruction = union(enum(u8)) {
//!         increment,
//!         set: extern struct { value: u64 },
//!     };
//!
//!     pub const program = mycelium.dispatch.program(.{
//!         .instruction = Instruction,
//!         .handlers = .{
//!             .increment = handleIncrement,
//!             .set = handleSet,
//!         },
//!     });
//!     comptime { program.declareEntrypoint(); }
//!
//! The dispatcher's overhead is exactly the discriminator load and one branch
//! per variant; no allocation, no virtual calls, no runtime type info.

const std = @import("std");
const core = @import("core/root.zig");
const account = @import("account/root.zig");

const ProgramError = core.ProgramError;
const ProgramResult = core.ProgramResult;
const ExecutionContext = core.entrypoint.ExecutionContext;
const AccountInfo = account.AccountInfo;

/// Build the comptime "Handlers" struct type: one field per union variant,
/// each typed as the appropriate handler function pointer.
///
/// Uses Zig 0.16's `@Struct` builtin (which replaced the old `@Type`).
pub fn HandlersFor(comptime Instruction: type) type {
    const ti = @typeInfo(Instruction);
    if (ti != .@"union") @compileError("Instruction must be a tagged union");
    const u = ti.@"union";
    if (u.tag_type == null) @compileError("Instruction must have an enum tag (use `union(enum) { ... }`)");

    comptime var names: [u.fields.len][]const u8 = undefined;
    comptime var types: [u.fields.len]type = undefined;
    inline for (u.fields, 0..) |f, i| {
        names[i] = f.name;
        types[i] = HandlerFnFor(f.type);
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

/// Signature of a per-variant handler.
///
/// `Payload` is `void` for unit variants (no extra bytes after the
/// discriminator) or the payload type for variants that carry data.
///
/// IMPORTANT: handlers must reference the *same* payload type the union
/// declares. Inline `extern struct { ... }` declarations create fresh
/// anonymous types each time, so prefer named types:
///
///     const SetPayload = extern struct { value: u64 };
///     const Inst = union(enum(u8)) { set: SetPayload };
///     fn handleSet(_: *const Ctx, p: *const SetPayload) ProgramResult { ... }
pub fn HandlerFnFor(comptime Payload: type) type {
    return if (Payload == void)
        *const fn (ctx: *const ExecutionContext) ProgramResult
    else
        *const fn (ctx: *const ExecutionContext, payload: *const Payload) ProgramResult;
}

/// Build a program from an instruction set and a handler table.
pub fn program(comptime cfg: anytype) type {
    const Cfg = @TypeOf(cfg);
    const Instruction = if (@hasField(Cfg, "instruction"))
        @field(cfg, "instruction")
    else
        @compileError("program() requires .instruction = SomeUnion");
    const handlers = cfg.handlers;
    const custom_code: u32 = if (@hasField(Cfg, "custom_code")) cfg.custom_code else 0;

    const ti = @typeInfo(Instruction);
    if (ti != .@"union") @compileError("instruction must be a tagged union");
    const u = ti.@"union";
    if (u.tag_type == null) @compileError("instruction must use `union(enum)`");
    const Tag = u.tag_type.?;

    return struct {
        pub const Inst = Instruction;

        /// The dispatcher entry the trampoline calls. Pure ProgramResult.
        pub fn dispatch(ctx: *const ExecutionContext) ProgramResult {
            if (ctx.data.len < 1) return error.InvalidInstructionData;
            const tag_byte = ctx.data[0];

            // Generate one branch per variant. `inline for` unrolls at comptime.
            inline for (u.fields) |f| {
                const variant_tag = @field(Tag, f.name);
                if (tag_byte == @intFromEnum(variant_tag)) {
                    if (f.type == void) {
                        const handler: HandlerFnFor(void) = @field(handlers, f.name);
                        return handler(ctx);
                    } else {
                        if (ctx.data.len < 1 + @sizeOf(f.type)) return error.InvalidInstructionData;
                        const payload_ptr: *align(1) const f.type = @ptrCast(ctx.data.ptr + 1);
                        const handler: HandlerFnFor(f.type) = @field(handlers, f.name);
                        // Convert *align(1) to a stack-local *const via copy if
                        // alignment matters; for now we pass aligned copy.
                        var payload_copy: f.type = payload_ptr.*;
                        return handler(ctx, &payload_copy);
                    }
                }
            }
            return error.InvalidInstructionData;
        }

        /// Install the C `entrypoint` symbol. Call from a comptime block in
        /// the program's root file.
        pub fn declareEntrypoint() void {
            core.entrypoint.declareEntrypointWithCustom(dispatch, custom_code);
        }
    };
}

// ===== tests =====

const testing = std.testing;

test "dispatch: unit-only variants" {
    const Inst = union(enum(u8)) {
        ping,
        pong,
    };

    const Handlers = struct {
        fn handlePing(_: *const ExecutionContext) ProgramResult {
            return;
        }
        fn handlePong(_: *const ExecutionContext) ProgramResult {
            return error.InvalidArgument;
        }
    };

    const P = program(.{
        .instruction = Inst,
        .handlers = .{ .ping = Handlers.handlePing, .pong = Handlers.handlePong },
    });

    var ctx: ExecutionContext = .{
        .program_id = &core.Pubkey.ZERO,
        .accounts = &.{},
        .data = &[_]u8{0}, // ping
    };
    try P.dispatch(&ctx);

    ctx.data = &[_]u8{1}; // pong
    try testing.expectError(error.InvalidArgument, P.dispatch(&ctx));

    ctx.data = &[_]u8{42}; // unknown
    try testing.expectError(error.InvalidInstructionData, P.dispatch(&ctx));

    ctx.data = &[_]u8{}; // empty
    try testing.expectError(error.InvalidInstructionData, P.dispatch(&ctx));
}

test "dispatch: variant with payload" {
    // Payload types must be named (not inline anonymous structs) so the
    // handler signature and the union variant agree on type identity.
    const SetPayload = extern struct { value: u64 };
    const Inst = union(enum(u8)) {
        nop,
        set: SetPayload,
    };

    const State = struct {
        var captured: u64 = 0;

        fn handleNop(_: *const ExecutionContext) ProgramResult {
            return;
        }
        fn handleSet(_: *const ExecutionContext, payload: *const SetPayload) ProgramResult {
            captured = payload.value;
            return;
        }
    };

    const P = program(.{
        .instruction = Inst,
        .handlers = .{ .nop = State.handleNop, .set = State.handleSet },
    });

    // Build instruction data: tag=1 (set), value=0xCAFEBABE_DEADBEEF
    var buf: [9]u8 = undefined;
    buf[0] = 1;
    std.mem.writeInt(u64, buf[1..9], 0xCAFEBABE_DEADBEEF, .little);

    var ctx: ExecutionContext = .{
        .program_id = &core.Pubkey.ZERO,
        .accounts = &.{},
        .data = &buf,
    };

    State.captured = 0;
    try P.dispatch(&ctx);
    try testing.expectEqual(@as(u64, 0xCAFEBABE_DEADBEEF), State.captured);
}

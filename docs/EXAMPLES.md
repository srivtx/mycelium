# Examples — anatomy of a handler

The same `Initialize` (vault PDA + state) written three ways. They
generate **byte-identical SBPF**; the difference is only in the source.

## v1 — manual primitives, no abstractions

```zig
fn handleInitialize(ctx: *const ExecutionContext, payload: *const InitializePayload) ProgramResult {
    if (ctx.account_count < 3) return error.NotEnoughAccountKeys;
    const authority = ctx.accounts[0];
    const vault = ctx.accounts[1];
    const system_program = ctx.accounts[2];

    try validate.mustBeSigner(authority);
    try validate.mustBeWritable(authority);
    try validate.mustBeWritable(vault);
    try validate.mustBeSystemProgram(system_program);

    const seeds: [2][]const u8 = .{ SEED_PREFIX, &authority.key().bytes };
    const derived_bump = try pda.findProgramAddress(&seeds, ctx.program_id);
    if (!Pubkey.equals(&derived_bump.address, vault.key())) return error.InvalidSeeds;

    if (vault.dataLen() != 0) return error.AccountAlreadyInitialized;

    var bump_byte: [1]u8 = .{derived_bump.bump};
    const signer_seeds: [3][]const u8 = .{ SEED_PREFIX, &authority.key().bytes, &bump_byte };
    try system.createPdaAccount(authority, vault, system_program,
        payload.rent_lamports, @sizeOf(State), ctx.program_id, &signer_seeds);

    const state = try StateCodec.load(vault.data());
    state.authority = authority.key().*;
    state.bump = derived_bump.bump;
    state.initialized = 1;
}
```

## v2 — primitives + bump-in-data + declarative account unpacking

```zig
fn handleInitialize(ctx: *const ExecutionContext, payload: *const InitializePayload) ProgramResult {
    const a = try accounts.unpack(ctx, .{
        .authority      = accounts.Role.signer_writable,
        .vault          = accounts.Role.writable,
        .system_program = accounts.Role.system_program,
    });
    try pda.verifyDerivation(
        &.{ SEED_PREFIX, &a.authority.key().bytes },
        payload.bump, ctx.program_id, a.vault.key(),
    );
    if (a.vault.dataLen() != 0) return error.AccountAlreadyInitialized;
    try system.createPdaAccount(
        a.authority, a.vault, a.system_program,
        payload.rent_lamports, @sizeOf(State), ctx.program_id,
        &.{ SEED_PREFIX, &a.authority.key().bytes, &[_]u8{payload.bump} },
    );
    const state = try StateCodec.load(a.vault.data());
    state.authority = a.authority.key().*;
    state.bump = payload.bump;
    state.initialized = 1;
}
```

## v3 — recipe layer (current default)

```zig
fn handleInitialize(ctx: mycelium.Ctx, p: *const Init) !void {
    const a = try accs.unpack(ctx, .{ .authority = accs.sw, .vault = accs.w, .sys = accs.sys });
    const state = try fw.createPdaState(State, .{
        .payer = a.authority, .pda = a.vault, .system_program = a.sys,
        .program_id = ctx.program_id,
        .seeds = &.{ SEED, &a.authority.key().bytes },
        .bump = p.bump, .rent_lamports = p.rent_lamports,
    });
    state.authority = a.authority.key().*;
    state.bump = p.bump;
    state.initialized = 1;
}
```

`Withdraw` shrinks even more, because the owner + discriminator + authority
checks collapse into one call:

```zig
fn withdraw(ctx: mycelium.Ctx, p: *const Amount) !void {
    const a = try accs.unpack(ctx, .{ .authority = accs.s, .vault = accs.w, .recipient = accs.w });
    _ = try fw.gate(State, a.vault, ctx.program_id, a.authority, "authority");
    if (p.amount == 0) return error.InvalidInstructionData;
    try mycelium.lamports.move(a.vault, a.recipient, p.amount);
}
```

The complete vault — three instructions, full state, entrypoint, every
edge case checked — is **62 lines**:
[`examples/vault_v3/src/main.zig`](../examples/vault_v3/src/main.zig).

Plain Zig, no macros, no derive, no hidden runtime. Every recipe inlines
at comptime to the same SBPF the manual version would have produced.

---

## Design rules the framework follows

- **Two layers of indirection, max.** `accs.unpack` is a function;
  `fw.createPdaState` is a function. You can jump-to-definition twice
  and see everything that happens.
- **The spec is the data.** Roles are enum values (`accs.sw`, `accs.w`,
  `accs.sys`) in a plain anonymous struct. Recipe configs are plain
  anonymous structs. No annotations on derived types, no proc macros.
- **Edge cases fail loud, at the right place.** Wrong owner →
  `IllegalOwner`. Stale discriminator → `UninitializedAccount`.
  Authority mismatch → `IncorrectAuthority`. PDA derivation off →
  `InvalidSeeds`. Mis-sized state → `AccountDataTooSmall`. Mis-spelled
  `authority_field` → compile error. Mis-typed discriminator → compile error.
- **CU-equivalent to the manual form**, verified in
  [BENCHMARKS.md](./BENCHMARKS.md). If a helper would cost more CU
  than the manual version, it does not get added.

---

## What works today

- **Compilation pipeline** — Zig 0.16 → LLVM bitcode → `sbpf-linker` → deployable SBPF ELF (SBPFv0 format, accepted by every loader).
- **Core layer** — byte-accurate input-buffer parser (dup accounts, alignment, realloc padding), zero-copy `AccountInfo`, capability validation primitives, Solana program-error ↔ u64 wire codec.
- **Syscalls layer** — murmur3_32 hashes computed at comptime, exposed as `*align(1) const fn (...)` constants so calls survive `sbpf-linker`'s LTO.
- **Pack layer** — comptime zero-copy codec for `extern struct` account data.
- **Dispatch layer** — comptime instruction dispatch from a `union(enum(u8))`, lowered to a flat switch on the tag byte. No proc macros, no virtuals, no vtables.
- **PDA layer** — `findProgramAddress` / `createProgramAddress` / `deriveWithBump`.
- **CPI layer** — `Instruction` builder + `invoke` / `invokeSigned` accepting Zig-native account lists and signer-seed tuples.
- **Programs/system layer** — typed builders for `CreateAccount`, `Transfer`, `Allocate`, `Assign`.
- **Lamports layer** — safe paired-mutation `move`, `credit`, `debit`, `close` for program-owned accounts.
- **Framework (recipe) layer** — `createPdaState`, `openState` / `gate` / `owned`, `closeState`. Comptime-validates that referenced field names exist on the State struct and are the right type.
- **Sugar** — `mycelium.entrypoint(...)`, `mycelium.Pad(N)`, `mycelium.Ctx`.
- **Tooling** — `tools/mycelium` CLI (`new` / `build` / `deploy` / `test` / `bench` / `validator`) + `tools/templates/minimal.zig` scaffold.
- **Examples** — `bare`, `hello`, `counter`, `vault` (v1 / v2 / v3), `escrow` (v1 / v2 / v3), `counter_demo`.
- **Tests** — 43 host-side tests covering pubkey decode/equals, account parsing, validation primitives, zerocopy round-trips, dispatch matching, lamport arithmetic, PDA seed packing, CPI account-meta builders, system instruction encoding, murmur3 hash correctness, and the recipe layer's owner/discriminator/authority checks.

## Not yet implemented

- SPL Token CPI wrappers
- Borsh-compatible serialization codegen for variable-length payloads
- Native in-process test harness
- Codama-format IDL emission

See [ARCHITECTURE.md](./ARCHITECTURE.md) §9 for the milestone plan.

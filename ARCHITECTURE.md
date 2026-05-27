# mycelium — Refined Architecture (2026)

A systems-oriented Solana program framework in Zig.

This document supersedes parts of the prior research (`findings.md`,
`SOLANA_SYSTEMS_FRAMEWORK_RESEARCH.md`, `TECHNICAL_DEEP_DIVE.md`,
`IMPLEMENTATION_ROADMAP.md`) based on ecosystem changes between
2024 and May 2026.

---

## 1. What changed since the original research

| Original assumption | 2026 reality |
|---|---|
| No official Zig sBPF target → "biggest blocker" | `bpfel-freestanding` works in stock Zig 0.15+ via LLVM bitcode |
| Need a custom Anza LLVM fork | Not required. `sbpf-linker` (Blueshift, v0.1.9 May 2026) ingests upstream LLVM bitcode and emits SBPF v0/v2/v3 ELF |
| Syscalls via magic-number function pointer constants (SBPFv2) | **SBPFv3 static syscalls** — murmur3-32 hash of name placed in `CALL_IMM` immediate (SIMD-0178). Linker resolves it from a relocation. |
| Compete with Anchor | The real low-level baseline is now **Pinocchio** (Anza, zero-dep Rust). Anchor is now widely understood to add ~2-5K CU/instruction. |
| IDL via Anchor JSON | **Codama** is the new neutral IDL format (multi-program, multi-language clients). |
| Borsh is the default | Zero-copy (bytemuck-style) has won at the low level. Borsh remains useful for length-prefixed/variable-length data only. |
| Stack frame size | Still 4 KB, but stack-gaps **disabled** in SBPFv3 (SIMD-0377). Heap default 32 KiB, max 256 KiB. |

So the core architectural thesis of the original research — "expose
the sBPF ABI honestly, generate everything else at comptime" — is
still right. What changes is the **toolchain story** (now trivial)
and the **competitive baseline** (Pinocchio, not Anchor).

---

## 2. The pitch

`mycelium` is a Zig framework that targets the SBPFv3 ABI directly
using stock Zig + `sbpf-linker`. It is layered so that:

- **Tier 1 (`mycelium.core`)** is ~600 lines of explicit, no-magic code: ABI
  parsing, syscall stubs, capability-based `AccountInfo`, error codes.
  Roughly Pinocchio's surface area, but in Zig.

- **Tier 2 (`mycelium.std`)** is a comptime-driven ergonomic layer:
  - Instruction dispatch from a tagged `union(enum)` (no proc macros).
  - `AccountSet` validation DSL (Anchor's `#[account(...)]` equivalent,
    but as ordinary Zig values inspected at comptime).
  - Pack/unpack codegen for zero-copy structs and Borsh-compat data.
  - CPI builders for the System program and SPL Token.
  - Optional bump allocator.
  - Optional comptime Codama-compatible IDL emission.

- **Tier 3 (`mycelium.testing`)** is a pure-Zig mock execution context so
  unit tests run without `solana-test-validator`.

Everything in Tier 2 and 3 is opt-in. A program can use only Tier 1
and still ship.

---

## 3. Layer map

```
+----------------------------------------------------+
|  Application program (your code)                    |
+----------------------------------------------------+
|  Tier 2: mycelium.std (comptime ergonomics)          |
|   - dispatch  AccountSet  pack/unpack  cpi  pda      |
+----------------------------------------------------+
|  Tier 1: mycelium.core (explicit ABI)                |
|   - entrypoint   abi   AccountInfo   syscalls  error |
+----------------------------------------------------+
|  Zig 0.16 (bpfel-freestanding) → LLVM bitcode →      |
|  sbpf-linker → SBPFv3 ELF (.so)                       |
+----------------------------------------------------+
|  Solana sBPF VM (Agave / Firedancer)                  |
+----------------------------------------------------+
```

---

## 4. Tier 1 design

### 4.1 ABI types (`core/abi.zig`)

The on-chain "input buffer" the loader hands us is described by
the Solana SDK headers. We model it as `extern struct` so layout
is byte-exact and zero-copy.

Account record (after the dedup byte, when not duplicated):

```
+0   u8   is_signer
+1   u8   is_writable
+2   u8   executable
+3   [4]  alignment padding
+8   [32] key (Pubkey)
+40  [32] owner
+72  u64  lamports
+80  u64  data_len
+88  [N]  data
+88+N [10240] realloc padding (MAX_PERMITTED_DATA_INCREASE)
+...  padding to 8B alignment
+...  u64  rent_epoch
```

After all accounts:

```
u64  instruction_data_len
[N]  instruction_data
[32] program_id
```

### 4.2 Syscalls (`core/syscalls.zig`)

Under SBPFv3 a syscall is just a `call` instruction whose immediate
is `murmur3_32(name, 0)`. The toolchain handles this for us if we
declare:

```zig
pub extern "C" fn sol_log_(msg: [*]const u8, len: u64) void;
pub extern "C" fn sol_invoke_signed_c(
    instruction: *const InstructionC,
    account_infos: [*]const AccountInfoC,
    account_infos_len: u64,
    signer_seeds: [*]const SignerSeedsC,
    signer_seeds_len: u64,
) u64;
// ...
```

LLVM emits a `call -1` with a relocation pointing to the symbol
name; `sbpf-linker` rewrites the immediate to the murmur3 hash.

For *fully static* SBPFv3 (no relocations at all) we can generate
the hashes ourselves with a comptime `murmur3` and emit inline asm.
We provide both modes; the relocation route is the default because
it survives toolchain changes.

The murmur3-32 implementation in `tools/murmur3.zig` is `comptime`,
so `Syscall("sol_log_")` evaluates to a `u32` at compile time.

### 4.3 AccountInfo (`account/info.zig`)

A pointer-into-input-buffer view. No allocation, no copy:

```zig
pub const AccountInfo = struct {
    raw: *RawAccount,   // points into the input buffer
    program_id: *const Pubkey,

    pub inline fn key(self: AccountInfo) *const Pubkey { ... }
    pub inline fn owner(self: AccountInfo) *const Pubkey { ... }
    pub inline fn lamports(self: AccountInfo) *u64 { ... }
    pub inline fn data(self: AccountInfo) []u8 { ... }
    pub inline fn isSigner(self: AccountInfo) bool { ... }
    pub inline fn isWritable(self: AccountInfo) bool { ... }
    ...
};
```

`mustBeSigner`, `mustBeOwnedBy`, `mustBeWritable`, `mustBePda`,
`mustBeRentExempt` are free functions returning `!void` —
composable, audit-friendly, no macros.

### 4.4 Errors (`core/error.zig`)

A `Result` is `u64` on the wire. Builtin errors live in the upper
32 bits (per SDK constants); custom errors in the lower 32. We
expose:

```zig
pub const ProgramError = error {
    Custom,             // .code (u32) below
    InvalidArgument,
    InvalidInstructionData,
    InvalidAccountData,
    ...
};
pub fn toCode(err: anyerror, custom: u32) u64 { ... }
```

User programs return `ProgramResult = ProgramError!void`. The
generated entrypoint maps that to a `u64`.

---

## 5. Tier 2 design

### 5.1 Dispatch (`dispatch.zig`)

Instead of `match` on bytes, the user declares a tagged union:

```zig
pub const Instruction = union(enum(u8)) {
    initialize: Init,
    increment,
    decrement,
    transfer: Transfer,
};

pub const program = mycelium.dispatch.program(.{
    .id = ID,
    .instruction = Instruction,
    .handlers = .{
        .initialize = handleInit,
        .increment = handleIncrement,
        .decrement = handleDecrement,
        .transfer = handleTransfer,
    },
});

comptime { _ = program.entrypoint; }
```

The dispatcher comptime-walks the union, generates `inline switch`
on the discriminator (first byte of instruction data), deserializes
the variant payload with the chosen pack codec, and calls the
matching handler.

Discriminator strategy is configurable:

- `.tag_u8` — single byte tag, like Solana SPL programs (default).
- `.anchor_8byte` — `sighash("global:<name>")` for Anchor compat.
- `.borsh_u32` — Borsh enum discriminator.

### 5.2 AccountSet DSL (`accounts_dsl.zig`)

The Anchor `#[derive(Accounts)]` analog without macros:

```zig
pub const Increment = mycelium.AccountSet(struct {
    counter:   mycelium.Mut(mycelium.OwnedBy(program_id)),
    authority: mycelium.Signer,
});
```

Each field's type is a *kind* (`Mut`, `Signer`, `OwnedBy(_)`,
`Pda(_)`, `Program(_)`, ...) inspected at comptime to:

1. Verify the account count.
2. Run the validations in declared order.
3. Bind each field into an `AccountInfo` (or a typed view for
   `Pda(State)`).

The output is a strongly-typed struct of `AccountInfo`s plus
loaded views; every check is plain Zig the auditor can read.

### 5.3 Pack/unpack (`pack/*.zig`)

Two codecs:

- **`pack.zerocopy(T)`** — requires `T` to be a `extern struct`
  with `extern`-compatible field types. Produces `*T` views from
  raw bytes via aligned pointer cast. Zero CU at runtime.

- **`pack.borsh(T)`** — comptime walks `@typeInfo(T)`, emits
  per-field readers/writers. Length-prefixed slices, `?T` optional,
  `enum` ints, fixed arrays, nested structs.

Both surface the same API:

```zig
const Codec = pack.zerocopy(State);
const view: *State = try Codec.load(account.data());     // mut view
const ro: *const State = try Codec.loadConst(account.data());
```

### 5.4 CPI builder (`cpi.zig`)

A typed builder that wraps `sol_invoke_signed_c`. Convenience
wrappers for the System program (`createAccount`, `transfer`,
`allocate`, `assign`) live in `system_program.zig`.

### 5.5 PDA (`pda.zig`)

Two modes:

- On-chain: calls `sol_create_program_address` /
  `sol_try_find_program_address` (canonical, ~1500 CU).
- Off-chain (for tests, IDL generation): pure-Zig SHA-256 +
  ed25519 on-curve check. Same algorithm; testable without VM.

---

## 6. Tier 3: testing

`testing.zig` provides a Zig-native mock context:

```zig
test "increment increases counter" {
    var ctx = mycelium.testing.Context.init(allocator);
    defer ctx.deinit();

    const counter = try ctx.addAccount(.{
        .owner = ID, .writable = true, .data_len = 8,
    });
    const authority = try ctx.addSigner();

    try ctx.invoke(my_program.entrypoint, &.{
        counter, authority,
    }, &[_]u8{ @intFromEnum(Instruction.increment) });

    try std.testing.expectEqual(@as(u64, 1), counter.readU64(0));
}
```

The mock implements the same input-buffer layout the real loader
produces, then calls the program's `entrypoint` symbol directly
in-process. Tests run on the host (`zig build test`); no validator
required.

---

## 7. Build pipeline

```
src/main.zig
   │  zig build-lib -target bpfel-freestanding -O ReleaseSmall
   │                -femit-llvm-bc=program.bc -fno-emit-bin
   ▼
program.bc  (LLVM bitcode)
   │  sbpf-linker --override-cpu-flag v3 -o program.so program.bc
   ▼
program.so  (SBPFv3 ELF, deployable)
```

`build.zig` wraps both steps as standard build graph nodes, so the
user runs `zig build` and gets `zig-out/lib/<name>.so`.

For tests: `zig build test` compiles the same `main.zig` for the
host target and links against `mycelium.testing`.

---

## 8. Comparison vs Pinocchio / Anchor / Zignocchio

| Feature | Anchor | Pinocchio | Zignocchio | **mycelium** |
|---|---|---|---|---|
| Language | Rust | Rust | Zig | Zig |
| Macros / hidden code | Heavy | None | None | None |
| Zero-copy accounts | No (Borsh) | Yes | Yes | Yes |
| Instruction dispatch | Proc macro | Hand-written | Hand-written | Comptime from `union(enum)` |
| Account validation | Attribute macros | Hand-written | Hand-written | Comptime `AccountSet` DSL (no macros) |
| Serialization | Borsh runtime | Manual bytemuck | Manual | Comptime codegen (zerocopy + borsh) |
| IDL | Anchor JSON | External (Codama / Shank) | None | Comptime → Codama |
| Native test harness | `bankrun` (Rust) | `mollusk` (Rust) | Jest + test-validator | Pure Zig in-process mock |
| SBPF version targeted | v2 (default) | v2/v3 | v2 | **v3 (default)** |
| LLVM fork required | No | No | No | No |
| Lines of framework code | ~10000 | ~3500 | ~600 | targeting ~1500 |

The differentiator is **comptime ergonomics with no hidden runtime
cost**: validations and dispatch read like Anchor, but the auditor
can `zig build-lib -femit-asm` and see the actual generated code
side-by-side with the source.

---

## 9. Roadmap inside this repo

Concrete milestones, in order:

1. **M0 — toolchain proof**: `examples/hello` compiles to a deployable
   `.so` that logs a message. *(this commit)*
2. **M1 — core**: `core/abi.zig`, `core/syscalls.zig`,
   `account/info.zig`, `core/error.zig`, `core/entrypoint.zig`.
3. **M2 — pack**: `pack/zerocopy.zig`, `pack/borsh.zig`.
4. **M3 — dispatch + AccountSet**: comptime DSLs.
5. **M4 — examples/counter**: end-to-end program using everything.
6. **M5 — testing**: mock execution context, `zig build test`.
7. **M6 — cpi + pda + system_program**: System-program CPIs.
8. **M7 — IDL**: comptime Codama emission.

Each milestone produces something that runs.

---

## 10. Risks & open questions

- **Zig's `extern struct` ABI on `bpfel`**: layout for `bool`, padding,
  64-bit pointer assumptions. The SBF VM uses 64-bit pointers, so we
  must compile for a 64-bit target. Verified via `zig targets` for
  `bpfel-freestanding`.
- **Stack discipline**: the 4 KB stack frame is hard; Zig's
  `inline` calls reduce frame use, but recursion is dangerous.
  We document `@frameSize` checks where it matters.
- **Compiler builtins**: SBF needs `memcpy/memset/memmove/memcmp`.
  Solana provides these as syscalls; we route Zig's builtin calls
  through the `sol_mem*` syscalls via a small intrinsics shim
  (or rely on sbpf-linker's compiler-rt).
- **Float ops**: not supported on chain. The framework refuses to
  compile if a float reaches the program surface.

---

## 11. Bottom line

The prior research was right about the *what*. The 2026 ecosystem
has solved most of the *how* (sbpf-linker, SBPFv3 static syscalls,
prior Zig art). This document is the design for an actually
shippable framework that builds on that foundation.

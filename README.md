# mycelium

> The substrate Solana programs grow on.
>
> A systems-oriented Solana program framework in Zig. Visibility over
> convenience, comptime over runtime, networked primitives over monolithic
> macros.

`mycelium` is what its namesake is in a forest floor: thin, foundational,
quietly connecting everything above it without taking up space itself.
Programs are written against a ~1900-line comptime substrate that knows
the SBPFv3 ABI and stays out of the way at runtime. No proc macros, no
derive expansions, no hidden validation — every check lives where you
can see it, and the generated SBPF is byte-identical to what you would
have written by hand.

Status: **working end-to-end on a local validator** with PDA + CPI + a
vault, an escrow, and a `mycelium` CLI for scaffolding, building,
deploying, and benchmarking. 43 host-side tests pass; ten example
programs compile and execute.

- Programs on the recipe layer run in **2–5× fewer CU than Anchor 1.0**
  and are **9× smaller** on chain.
- A complete PDA-vault (state + 3 instructions + entrypoint + every edge
  case checked) is **62 lines** of Zig.
- `mycelium new my_program` scaffolds a deployable program from a
  53-line template.

See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the design rationale and how
this differs from Pinocchio / Anchor / Zignocchio.

---

## Measured numbers (Agave 3.1, May 2026)

### Trivial programs

| program     | size      | CU              |
|-------------|-----------|------------------|
| `bare`      | 1 176 B   | 105 (log only)             |
| `hello`     | 2 424 B   | 188 (parse + log)          |
| `counter`   | 13 848 B  | 598 (reset) – 696 (add)    |

### Side-by-side vs Anchor 1.0 (same semantics, same SBPFv0)

Same vault (PDA + deposit/withdraw) and lamport-for-lamports escrow
implemented four ways:
- **Anchor 1.0** — the standard high-level Rust framework.
- **mycelium v1** — manual handlers calling primitive helpers directly.
- **mycelium v2** — `v1` rewritten on the framework primitives
  (`accounts.unpack`, `pda.verifyDerivation`, `system.createPdaAccount`)
  + PDA bump passed in instruction data.
- **mycelium v3** — `v2` rewritten on the high-level recipe layer
  (`framework.createPdaState`, `framework.openState`, `framework.closeState`).
  Same wire format as v2.

| operation     | Anchor | my-v1   | my-v2 | my-v3   | Anchor / v3 |
|---------------|-------:|--------:|------:|--------:|------------:|
| **VAULT**     |        |         |       |         |             |
| initialize    |  6 497 | 4 038   | 3 947 | **3 949** | **1.65×**   |
| deposit       |  5 504 | 2 138   | 2 141 | **2 034** | **2.71×**   |
| withdraw      |  4 053 |   889   |   885 |   **764** | **5.30×**   |
| **ESCROW**    |        |         |       |         |             |
| initialize    |  8 384 | 4 265   | 4 185 | **4 231** | **1.98×**   |
| take          |  5 924 | 2 802   | 2 811 | **2 693** | **2.20×**   |
| cancel        |  3 611 | 1 148   | 1 155 | **1 037** | **3.48×**   |

| binary size on-chain | Anchor  | mycelium v3 | smaller by |
|----------------------|--------:|------------:|-----------:|
| vault.so             | 153 856 | 16 672      | **9.2×**   |
| escrow.so            | 159 808 | 19 816      | **8.1×**   |

Per-instruction handler length, by lines of code:

| program | v2 lines | v3 lines | reduction |
|---------|---------:|---------:|----------:|
| vault — `Initialize` | 27 |  14 | **−48 %** |
| vault — `Deposit`    | 11 |   7 | **−36 %** |
| vault — `Withdraw`   | 14 |  10 | **−29 %** |
| escrow — `Initialize`| 31 |  18 | **−42 %** |
| escrow — `Take`      | 15 |  11 | **−27 %** |
| escrow — `Cancel`    | 13 |   8 | **−38 %** |

Three things stand out:

1. **The primitives are free.** v1 → v2 deltas for non-init ops (deposit,
   withdraw, take, cancel) are all within ±10 CU — i.e. noise. Using
   `accounts.unpack` and the typed CPI helpers does not add measurable
   overhead vs the manual form, because `inline for` unrolls everything
   at comptime.
2. **The recipe layer is free, too.** v2 → v3 deltas are also within noise
   on the init path (±50 CU) and *negative* on non-init paths (~−120 CU
   each) because v3 dropped the diagnostic `sol_log_("vault: deposit")`
   strings. `framework.createPdaState`, `openState`, and `closeState`
   inline to byte-identical SBPF as the manual versions.
3. **Bump-in-data is a serious win for `init`.** Escrow `init`:
   5,765 → 4,185 CU (−27 %). At pathological bumps it can save 4+ K CU.
   The cost becomes deterministic instead of varying with PDA luck.

#### How to read these numbers

- **`initialize` ratio (2–2.8×)** even after the bump optimization. Both
  frameworks still pay for a CPI to System Program `create_account`
  (~2.5 K CU fixed); Anchor's overhead is what's left.
- **CPI-light ops (`deposit`, `take`) cost ~2.1–2.6× more in Anchor.**
  The Anchor prelude adds a roughly-constant 3–4 K CU per instruction
  regardless of how thin the handler is.
- **Non-CPI ops (`withdraw`, `cancel`) cost 3–4.6× more in Anchor** —
  mycelium's `withdraw` is two lamport writes (~885 CU). Anchor's
  framework overhead dominates.

#### How to read these numbers

- **`initialize` is closest** (~1.1–2×). Both spend most of their CUs
  on `find_program_address` (~1.5 K CU per bump iteration) + CPI to
  System Program `create_account` (~2.5 K CU). The Anchor overhead on top
  is its discriminator + Borsh + the `Accounts` validation runtime.
- **CPI-light ops (`deposit`, `take`) cost ~2–3× more in Anchor.** The
  Anchor prelude adds a roughly-constant 3–4 K CU per instruction
  regardless of how thin the handler is.
- **Non-CPI ops (`withdraw`, `cancel`) cost 3–5× more in Anchor** for the
  same reason — mycelium's `withdraw` is two lamport writes (889 CU);
  Anchor's framework overhead dominates.
- **Bump-search variance.** `find_program_address` iterates from bump 255
  downward, each attempt costing ~1.5 K CU. A PDA that lands off-curve at
  bump 255 is ~4.5 K CU cheaper to derive than one that takes 3 tries.
  Visible in the escrow numbers: same code, different bump → ~3 K CU
  difference. The fix is to pass the bump in instruction data and use
  `create_program_address`, which is a single hash (~750 CU).

The benchmark code lives in [`../anchor-bench/`](../anchor-bench) and is
reproducible with `scripts/bench_all.mjs`.

---

## What a handler looks like

The same `Initialize` written three ways:

#### v1 — manual primitives, no abstractions

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

#### v2 — primitives + bump-in-data + declarative account unpacking

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

#### v3 — recipe layer (current default)

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

```62:62:examples/vault_v3/src/main.zig
}
```

Plain Zig, no macros, no derive, no hidden runtime. Every recipe inlines
at comptime to the same SBPF the manual version would have produced.

Design rules the framework follows:

- **Two layers of indirection, max.** `accs.unpack` is a function;
  `fw.createPdaState` is a function. You can jump-to-definition twice
  and see everything that happens.
- **The spec is the data.** Roles are enum values
  (`accs.sw`, `accs.w`, `accs.sys`) in a plain anonymous struct.
  Recipe configs are plain anonymous structs. No annotations on derived
  types, no proc macros.
- **Edge cases fail loud, at the right place.** Wrong owner →
  `IllegalOwner`. Stale discriminator → `UninitializedAccount`. Authority
  mismatch → `IncorrectAuthority`. PDA derivation off → `InvalidSeeds`.
  Mis-sized state → `AccountDataTooSmall`. Mis-spelled `authority_field`
  → compile error. Mis-typed discriminator → compile error.
- **CU-equivalent to the manual form** (verified in the bench table
  above). If a helper would cost more, it does not get added.

---

## Tooling: the `mycelium` CLI

A small Bash wrapper at `tools/mycelium` smooths the build/deploy/bench
loop into one command. Put `tools/` on your `$PATH` (or alias it) and
you get:

```sh
mycelium new my_program          # scaffold examples/my_program/src/main.zig
mycelium build my_program        # zig build my_program -> zig-out/lib/my_program.so
mycelium deploy my_program       # build + solana program deploy
mycelium validator               # start a fresh local solana-test-validator
mycelium test                    # zig build test (43 host-side tests)
mycelium bench --anchor-vault ... # 4-way CU comparison vs Anchor 1.0
mycelium help                    # full reference
```

`mycelium new <name>` drops a fully-formed PDA counter program from
[`tools/templates/minimal.zig`](./tools/templates/minimal.zig) — already
wired up with `framework.createPdaState`, `framework.gate`, and
`mycelium.entrypoint`. You patch one line into `build.zig`
(the CLI prints the snippet), then `mycelium deploy <name>` and you have
a deployed PDA program in under 30 seconds.

The scaffolded template is **53 lines**: PDA-owned state, an `initialize`
instruction that creates the PDA, and an authority-gated `increment`
that mutates it. It deploys to a 14 KB `.so`.

---

## What works today

- **Compilation pipeline**: Zig 0.16 → LLVM bitcode → `sbpf-linker` → deployable SBPF ELF (SBPFv0 format, accepted by every loader).
- **Core layer**: byte-accurate input-buffer parser (handles dup accounts, alignment, realloc padding), zero-copy `AccountInfo`, capability validation primitives, Solana program-error → u64 mapping (canonical wire format).
- **Syscalls layer**: murmur3_32 hashes computed at comptime, exposed as `*align(1) const fn (...)` constants so calls survive `sbpf-linker`'s aggressive LTO.
- **Pack layer**: comptime zero-copy codec for `extern struct` account data.
- **Dispatch layer**: comptime instruction dispatch from a `union(enum(u8))`, lowered to a flat switch on the tag byte. No proc macros, no virtuals, no vtables.
- **PDA layer**: `findProgramAddress` / `createProgramAddress` thin wrappers around the syscalls.
- **CPI layer**: `Instruction` builder + `invoke` / `invokeSigned` accepting Zig-native account lists and signer-seed tuples.
- **Programs/system layer**: typed builders for `CreateAccount`, `Transfer`, `Allocate`, `Assign`, returning ready-to-invoke `Instruction`s.
- **Lamports layer**: safe paired-mutation `move`, `credit`, `debit`, `close` for program-owned accounts.
- **Framework (recipe) layer**: `framework.createPdaState`, `framework.openState`/`gate`/`owned`, `framework.closeState` — comptime-inlined recipes that absorb the recurring "create + verify + fund" and "open + check ownership + check discriminator + check authority" patterns. Comptime-validates that referenced field names exist on the State struct and are of the right type.
- **Sugar**: `mycelium.entrypoint(...)` (one-call program + entrypoint registration), `mycelium.Pad(N)` (typed padding fields), `mycelium.Ctx` (= `*const ExecutionContext`).
- **Tooling**: `tools/mycelium` CLI (`new` / `build` / `deploy` / `test` / `bench` / `validator`) + `tools/templates/minimal.zig` scaffold.
- **Examples**: `bare`, `hello`, `counter`, `vault` (v1/v2/v3), `escrow` (v1/v2/v3), `counter_demo` (CLI scaffold output) — all build, deploy, and execute on `solana-test-validator`.
- **Tests**: 43 host-side tests covering pubkey decode/equals, account parsing, validation primitives, zerocopy round-trips, dispatch matching, lamport arithmetic, PDA seed packing, CPI account-meta builders, system instruction encoding, murmur3 hash correctness, and the recipe layer's owner/discriminator/authority checks.
- **Scripts**: `scripts/invoke_hello.mjs`, `scripts/test_counter.mjs`, `scripts/test_vault.mjs`, `scripts/test_escrow.mjs` drive deployed programs via `@solana/web3.js` and print CU usage per call.

## Not yet implemented

- SPL Token CPI wrappers
- Borsh-compatible serialization codegen for variable-length payloads
- Native test harness (in-process mock execution)
- Codama-format IDL emission

See [`ARCHITECTURE.md`](./ARCHITECTURE.md) §9 for the milestone plan.

---

## Toolchain prerequisites

This pipeline needs four things, in order of decreasing obviousness:

### 1. Zig 0.16

```sh
brew install zig
zig version    # → 0.16.0
```

### 2. `sbpf-linker`

```sh
cargo install sbpf-linker
sbpf-linker --help   # should print usage
```

### 3. A working LLVM shared library that `sbpf-linker` can find

`sbpf-linker` ships dynamically linked against LLVM via the
`aya-rustc-llvm-proxy` crate. The proxy hunts for `libLLVM*.dylib` (macOS) or
`libLLVM*.so` (Linux) in directories derived from `$LD_LIBRARY_PATH`,
`$DYLD_FALLBACK_LIBRARY_PATH`, and `$PATH` (for each `bin/` it checks the
sibling `lib/`).

On macOS, the simplest fix is to install Homebrew LLVM 21 and symlink it into
a directory the proxy already scans (`~/.cargo/lib` works because
`~/.cargo/bin` is on `$PATH`):

```sh
brew install llvm@21
mkdir -p ~/.cargo/lib
ln -sf /opt/homebrew/opt/llvm@21/lib/libLLVM.dylib    ~/.cargo/lib/libLLVM.dylib
ln -sf /opt/homebrew/opt/llvm@21/lib/libLLVM-21.dylib ~/.cargo/lib/libLLVM-21.dylib
```

If you'd rather not depend on Homebrew, run
`cargo install-with-gallery` inside a clone of
`blueshift-gg/sbpf-linker` to build a statically-linked variant — but that
takes ~30 minutes (it compiles LLVM from source).

### 4. (Optional, for deployment) `solana-cli`

```sh
sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"
solana --version
```

---

## Building

From this directory:

```sh
zig build test       # run 35 host-side framework tests
zig build hello      # emit zig-out/lib/hello.so    (~2.4 KB)
zig build counter    # emit zig-out/lib/counter.so  (~14 KB)
zig build vault      # emit zig-out/lib/vault.so    (~17 KB)
zig build escrow     # emit zig-out/lib/escrow.so   (~20 KB)
```

The on-chain build is two passes (orchestrated by `build.zig`):

```
zig build-lib -target bpfel-freestanding -mcpu=v1 \
              -O ReleaseSmall -fno-emit-bin -fstrip \
              -femit-llvm-bc=program.bc \
              --dep mycelium -Mroot=src/main.zig -Mmycelium=…/root.zig

sbpf-linker --override-cpu-flag v1 --export entrypoint -O 2 \
            -o program.so program.bc
```

`-mcpu=v1` matters: Zig 0.16 defaults the `bpfel` CPU to `v3`, which enables
the `alu32` feature, which causes LLVM to emit `JEQ32_IMM` (opcode `0x16`)
that `sbpf-linker` 0.1.9's SBPFv0 assembler cannot decode. `v1` is the
largest CPU model without alu32 and is safe to target.

## SBPF version note

`sbpf-linker` 0.1.9 emits SBPFv0 ELF binaries (`e_flags = 0`). This is the
most-compatible format and is accepted by every Solana loader.

The syscall convention is the original "`call -1` with a dynamic relocation
to the syscall name" style. The runtime resolves the relocation to the
target syscall on program load.

### Why function pointers, not `extern fn`?

`sbpf-linker` has a code-generation issue where `extern fn` declarations
that are the target of a call lose their argument-setup instructions
during LTO. We work around it by typing each syscall as a `*align(1) const fn (...)` constant initialized via `@ptrFromInt(murmur3_32(name))`. Both
Zignocchio and Ziglana hit the same problem; the function-pointer-via-hash
pattern is the documented workaround.

---

## Trying it on a local validator

```sh
# Terminal 1: start a local validator (kept running)
solana-test-validator --reset

# Terminal 2: configure CLI for localnet
solana config set --url http://127.0.0.1:8899
solana airdrop 5
solana program deploy zig-out/lib/hello.so
```

(End-to-end deployment test is part of milestone M5 and is not yet a CI step.)

---

## Repo layout

```
mycelium/
├── ARCHITECTURE.md          design doc
├── README.md                this file
├── build.zig                two-pass build orchestration
├── build.zig.zon            package manifest
├── src/
│   ├── root.zig             public re-exports
│   ├── core/
│   │   ├── root.zig
│   │   ├── abi.zig          loader input format constants
│   │   ├── entrypoint.zig   parse loader input → ExecutionContext
│   │   ├── error.zig        ProgramError ↔ u64 wire codes
│   │   ├── pubkey.zig       Pubkey + comptime base58
│   │   └── syscalls.zig     extern SBPF syscall declarations + host shims
│   ├── account/
│   │   ├── root.zig
│   │   ├── info.zig         zero-copy AccountInfo
│   │   ├── validate.zig     mustBeSigner / mustBeOwnedBy / mustBeWritable / …
│   │   └── lamports.zig     move / credit / debit / close (program-owned accounts)
│   ├── pack/
│   │   ├── root.zig
│   │   └── zerocopy.zig     comptime ZeroCopy(T) codec
│   ├── programs/
│   │   ├── root.zig
│   │   └── system.zig       typed builders + createPdaAccount + transferLamports
│   ├── pda.zig              findProgramAddress / createProgramAddress / deriveWithBump
│   ├── cpi.zig              Instruction + invoke / invokeSigned
│   ├── accounts.zig         declarative accounts.unpack DSL (the framework layer)
│   └── dispatch.zig         comptime instruction dispatch from union(enum(u8))
└── examples/
    ├── bare/                minimum: log + return
    ├── hello/               parse input, log
    ├── counter/             state machine: init / increment / add / reset
    ├── vault/               PDA + System CPI + lamport withdrawal (manual)
    ├── vault_v2/            same vault, written on the framework primitives
    ├── escrow/              two-party trade: lock / take / cancel (manual)
    └── escrow_v2/           same escrow, written on the framework primitives
```

## License

MIT (proposed). Treat this as research-grade code; do not deploy to mainnet
without an audit.

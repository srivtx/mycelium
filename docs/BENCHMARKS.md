# Benchmarks

All numbers measured on **Agave 3.1 (May 2026)** against a local
`solana-test-validator`, SBPFv0 ELF format.

The benchmark harness lives in [`../anchor-bench/`](../../anchor-bench)
and is re-runnable with:

```sh
mycelium bench \
  --anchor-vault    <PROGRAM_ID> --anchor-escrow   <PROGRAM_ID> \
  --mycelium-vault  <PROGRAM_ID> --mycelium-escrow <PROGRAM_ID> \
  --mycelium2-vault <PROGRAM_ID> --mycelium2-escrow <PROGRAM_ID> \
  --mycelium3-vault <PROGRAM_ID> --mycelium3-escrow <PROGRAM_ID>
```

---

## Trivial programs

| program     | size      | CU                          |
|-------------|-----------|------------------------------|
| `bare`      | 1 176 B   | 105 (log only)              |
| `hello`     | 2 424 B   | 188 (parse + log)           |
| `counter`   | 13 848 B  | 598 (reset) – 696 (add)     |

---

## Side-by-side vs Anchor 1.0 (same semantics, same SBPFv0)

Identical vault (PDA + deposit/withdraw) and lamport-for-lamports escrow
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
| initialize    |  9 497 | 5 538   | 3 947 | **3 949** | **2.40×**   |
| deposit       |  5 504 | 2 138   | 2 141 | **2 034** | **2.71×**   |
| withdraw      |  4 053 |   889   |   885 |   **766** | **5.29×**   |
| **ESCROW**    |        |         |       |         |             |
| initialize    | 12 884 | 5 765   | 4 185 | **4 185** | **3.08×**   |
| take          |  5 924 | 2 802   | 2 811 | **2 691** | **2.20×**   |
| cancel        |  3 611 | 1 148   | 1 155 | **1 037** | **3.48×**   |

| binary size on-chain | Anchor  | mycelium v3 | smaller by |
|----------------------|--------:|------------:|-----------:|
| vault.so             | 153 856 | 16 688      | **9.2×**   |
| escrow.so            | 159 808 | 19 432      | **8.2×**   |

Per-instruction handler length, by lines of code:

| program | v2 lines | v3 lines | reduction |
|---------|---------:|---------:|----------:|
| vault — `Initialize` | 27 |  14 | **−48 %** |
| vault — `Deposit`    | 11 |   7 | **−36 %** |
| vault — `Withdraw`   | 14 |  10 | **−29 %** |
| escrow — `Initialize`| 31 |  18 | **−42 %** |
| escrow — `Take`      | 15 |  11 | **−27 %** |
| escrow — `Cancel`    | 13 |   8 | **−38 %** |

---

## Three things stand out

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
   5 765 → 4 185 CU (−27 %). At pathological bumps it can save 4+ K CU.
   The cost becomes deterministic instead of varying with PDA luck.

## How to read these numbers

- **`initialize`** is closest (1.65–3.08×). Both spend most of their CUs
  on `find_program_address` (~1.5 K CU per bump iteration) + CPI to
  System Program `create_account` (~2.5 K CU). The Anchor overhead on
  top is its discriminator + Borsh + the `Accounts` validation runtime.
- **CPI-light ops (`deposit`, `take`) cost ~2–3× more in Anchor.** The
  Anchor prelude adds a roughly-constant 3–4 K CU per instruction
  regardless of how thin the handler is.
- **Non-CPI ops (`withdraw`, `cancel`) cost 3–5× more in Anchor** — for
  the same reason. mycelium's `withdraw` is two lamport writes (766 CU);
  Anchor's framework overhead dominates.
- **Bump-search variance.** `find_program_address` iterates from bump 255
  downward, each attempt costing ~1.5 K CU. A PDA that lands off-curve
  at bump 255 is ~4.5 K CU cheaper to derive than one that takes 3 tries.
  The fix is to pass the bump in instruction data and use
  `create_program_address`, which is a single hash (~750 CU).

# Quickstart

## 1. Toolchain prerequisites

In order of decreasing obviousness.

### Zig 0.16

```sh
brew install zig
zig version    # → 0.16.0
```

### `sbpf-linker`

```sh
cargo install sbpf-linker
sbpf-linker --help
```

### A working LLVM that `sbpf-linker` can find

`sbpf-linker` ships dynamically linked against LLVM via the
`aya-rustc-llvm-proxy` crate, which hunts for `libLLVM*.dylib` (macOS)
or `libLLVM*.so` (Linux) in directories derived from `$LD_LIBRARY_PATH`,
`$DYLD_FALLBACK_LIBRARY_PATH`, and `$PATH` (for each `bin/` it checks
the sibling `lib/`).

On macOS, install Homebrew LLVM 21 and symlink it into a directory the
proxy already scans:

```sh
brew install llvm@21
mkdir -p ~/.cargo/lib
ln -sf /opt/homebrew/opt/llvm@21/lib/libLLVM.dylib    ~/.cargo/lib/libLLVM.dylib
ln -sf /opt/homebrew/opt/llvm@21/lib/libLLVM-21.dylib ~/.cargo/lib/libLLVM-21.dylib
```

If you'd rather not depend on Homebrew, run
`cargo install-with-gallery` inside a clone of
[`blueshift-gg/sbpf-linker`](https://github.com/blueshift-gg/sbpf-linker)
to build a statically-linked variant — but that takes ~30 minutes
(it compiles LLVM from source).

### (Optional) `solana-cli` for deployment

```sh
sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"
solana --version
```

---

## 2. Build

From the repo root:

```sh
zig build test       # 43 host-side framework tests
zig build hello      # → zig-out/lib/hello.so      (~2.4 KB)
zig build counter    # → zig-out/lib/counter.so    (~14 KB)
zig build vault_v3   # → zig-out/lib/vault_v3.so   (~17 KB)
zig build escrow_v3  # → zig-out/lib/escrow_v3.so  (~20 KB)
```

The on-chain build is two passes (orchestrated by `build.zig`):

```
zig build-lib -target bpfel-freestanding -mcpu=v1 \
              -O ReleaseSmall -fno-emit-bin -fstrip \
              -femit-llvm-bc=program.bc \
              --dep mycelium -Mroot=src/main.zig -Mmycelium=…/root.zig

sbpf-linker --override-cpu-flag v1 --export entrypoint -O 0 \
            --llvm-args=-bpf-stack-size=8192 \
            -o program.so program.bc
```

`-mcpu=v1` matters: Zig 0.16 defaults `bpfel` to `v3`, which enables
the `alu32` feature, which causes LLVM to emit `JEQ32_IMM` (opcode
`0x16`) that `sbpf-linker` 0.1.9's SBPFv0 assembler cannot decode.
`v1` is the largest CPU model without alu32 and is safe to target.

---

## 3. Deploy on a local validator

```sh
# Terminal 1
mycelium validator       # equivalent to: solana-test-validator --reset

# Terminal 2
solana config set --url http://127.0.0.1:8899
solana airdrop 5
mycelium deploy vault_v3
```

---

## 4. Scaffold a new program

```sh
mycelium init my_program
cd my_program
mycelium build
mycelium deploy
```

The scaffold is a **53-line counter program** with PDA-owned state,
an `initialize` instruction, and an authority-gated `increment`.
Deploys to a ~14 KB `.so`.

If you’re contributing to the mycelium framework itself, `mycelium new <name>`
adds an example program under `mycelium/examples/<name>/` (monorepo-only).

See [CLI.md](./CLI.md) for the full command reference.

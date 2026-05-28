# `mycelium` CLI

A small Bash wrapper at [`tools/mycelium`](../tools/mycelium) smooths
the build / deploy / bench loop into one command.

## Setup

Put `tools/` on your `$PATH`, or alias it:

```sh
alias mycelium="$PWD/tools/mycelium"
```

## Commands

```text
mycelium init <name>           Scaffold a standalone project in ./<name>/
mycelium new <name>            Scaffold a new program in examples/<name>/
mycelium build [name]          Build program (.so)
mycelium deploy [name]         Build + deploy to the active Solana cluster
mycelium test                  Run host-side unit tests (zig build test)
mycelium bench                 Run the 4-way (anchor / v1 / v2 / v3) CU benchmark
mycelium validator             Start a local solana-test-validator
mycelium doctor                Check toolchain
mycelium help                  Show usage
```

### `mycelium init <name>`

Creates a **standalone** mycelium program project in `./<name>/` (like
`anchor init`). The project includes its own `build.zig` and builds a
single on-chain `.so`.

```sh
mycelium init demo
cd demo
mycelium build
mycelium deploy
```

This is the recommended path for app developers.

### `mycelium new <name>`

Drops a fully-formed PDA counter program from
[`tools/templates/minimal.zig`](../tools/templates/minimal.zig) into
`examples/<name>/src/main.zig`. It's already wired up with
`framework.createPdaState`, `framework.gate`, and `mycelium.entrypoint`.

You patch one line into `build.zig` (the CLI prints the snippet), then
`mycelium deploy <name>` and you have a deployed PDA program in under
30 seconds.

The scaffolded template is **53 lines**: PDA-owned state, an
`initialize` instruction that creates the PDA, and an authority-gated
`increment` that mutates it. It deploys to a ~14 KB `.so`.

### `mycelium bench`

Runs `anchor-bench/scripts/bench_v3.mjs` against deployed programs
on the active validator. Expects all 8 program IDs as flags:

```sh
mycelium bench \
  --anchor-vault    <ID> --anchor-escrow   <ID> \
  --mycelium-vault  <ID> --mycelium-escrow <ID> \
  --mycelium2-vault <ID> --mycelium2-escrow <ID> \
  --mycelium3-vault <ID> --mycelium3-escrow <ID>
```

Prints a 4-column comparison table with CU usage per operation.
See [BENCHMARKS.md](./BENCHMARKS.md) for measured numbers.

# Getting started

## Requirements

| Tool | Version | For |
|---|---|---|
| Rust | 1.97.0 (`rust-toolchain.toml`) | crates, CLI |
| Foundry | 1.8.5 or later | contracts, anvil |
| Node | ≥ 23 | viem checks, end-to-end scripts |
| ethrex (optional) | a checkout with native rollups (PR #6418), built with `COMPILE_CONTRACTS=true cargo build --release --features l2,l2-sql` and **solc 0.8.31** on `PATH` | the native e2e |
| skim (optional) | a running node, e.g. `skim run --rpc 127.0.0.1:18545 --ephemeral` | the live Sepolia tests |
| Docker + Kurtosis (optional) | | the live FCR test |

## Build and test

```console
$ cargo test --workspace                 # 50 tests; anvil tests run if anvil is on PATH
$ cd contracts && forge test             # 88 tests
$ cd ts && npm ci && npm run check-encodings
$ scripts/check.sh                       # all of the above, plus fmt, clippy, fixture freshness, the anvil e2e
```

## The end-to-end demos

**Two anvil chains** (mock block acceptance, labeled as such):

```console
$ cargo build -p channel-runner
$ cd ts && npm run e2e
ok  preview at H0 (shareBps 6000): 1.2 / 0.8
ok  preview at H1 (shareBps 7000): 1.4 / 0.6, no reopen
ok  execute is tx 15 of 31 in its L2 block
ok  settled on L1: 1.4 / 0.6 credited
ok  emergency exit finalized on L1 alone: 1.4 credited (L1 re-executed the split)
E2E PASSED
```

`FILLER=n` sets the number of transactions around ours in the L2 block. Measurements are written to `docs/experiments/data/`.

**Native verification on ethrex** (no mocks):

```console
$ ETHREX=/path/to/ethrex npm run e2e-native
ok  H1 anchor posted on L2 by L1-message proof (no system key)
ok  carol submitted L2 blocks 1..16 permissionlessly; EXECUTE-verified roots match ethrex's own
ok  settled under native-reexecution-devnet: 1.4 / 0.6
NATIVE E2E PASSED
```

The script starts its own ethrex L1 and L2. `CAPTURE_FIXTURE=1` also refreshes `fixtures/native/execute-input.json`.

## Live tests

```console
$ SKIM_RPC=http://127.0.0.1:18545 cargo test -p channel-runner --test live_skim -- --nocapture
$ BEACON_URL=http://… EL_URL=http://… cargo test -p channel-runner --test live_fcr -- --nocapture
```

For the FCR devnet, use Kurtosis `ethpandaops/ethereum-package` with `cl_image: sigp/lighthouse:v8.3.0` and `cl_extra_params: ["--enable-fast-confirmation"]`.

## Regenerating fixtures

```console
$ cargo run -p channel-types --bin gen-fixtures
$ UPDATE_FIXTURES=1 cargo test -p channel-receipts -p channel-witness
```

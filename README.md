<p align="center">
  <img src="assets/banner.svg" alt="skim-channels: compute off-chain, settle on L1" width="100%">
</p>

<p align="center">
  <a href="#quick-start"><img alt="status" src="https://img.shields.io/badge/status-experimental-7C5CFF"></a>
  <a href="docs/guide/native-verification.md"><img alt="verification" src="https://img.shields.io/badge/verification-native%20(EXECUTE)-3FA8FF"></a>
  <a href="rust-toolchain.toml"><img alt="rust" src="https://img.shields.io/badge/rust-1.97-2EE6C5"></a>
  <a href="#license"><img alt="license" src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-9AA7C7"></a>
</p>

<p align="center"><b>Funds and state stay on Ethereum. Channels only borrow computation, and L1 checks it.</b></p>

<p align="center">
  <img src="assets/concept.svg" alt="skim-channels in one picture: L1 holds state and escrow; skim proves L1 reads; the channel executes on L2; L1 re-executes the L2 block and settles" width="100%">
</p>

**skim-channels** is an experimental architecture for running computation in ephemeral execution channels on a native rollup, with Ethereum L1 as the only persistent state. A second path runs **stateful apps**: Solidity contracts that keep their own state across many interactions and L1 snapshots, read L1 through skim, and settle optimistically on L1 with their account state committed there ([stateful runtime](docs/guide/stateful-runtime.md)).

A channel holds its participants' funds in an L1 escrow. It reads any L1 contract at an authenticated block through [skim](https://github.com/leekt/skim)'s verified proofs, computes on L2 without keeping application state of its own, and settles its outcome back on L1 exactly once. L1 checks the L2 execution by re-executing the block itself (the EIP-8079-style `EXECUTE` precompile). If the operator disappears, L1 re-runs the channel's computation directly.

> **Cost reality:** verifying by re-execution (EXECUTE) costs L1 at least as much as running the computation on L1, ~16M gas per L2 block. It's here for its security properties. For apps that must be cheaper than L1, the direction is [app channels](docs/guide/app-channels.md): proven checkpoints with recoverable state on L1.

```console
$ scripts/check.sh                  # fmt, clippy, Rust, fixtures, forge, viem, anvil e2e
$ ETHREX=../ethrex scripts/check.sh # + the native e2e on ethrex's EXECUTE prototype
...
ok  carol submitted L2 blocks 1..16 permissionlessly; EXECUTE-verified roots match ethrex's own
ok  settled under native-reexecution-devnet: 1.4 / 0.6
NATIVE E2E PASSED
```

---

## Why this is possible now

Three pieces arrived at once:

- **Verified L1 state without a full node.** [skim](https://github.com/leekt/skim) follows L1 over P2P, authenticates `safe` and `finalized` with a light client, and serves `eth_getProof` at exact blocks. A channel gets Merkle proofs of exactly the L1 state it reads.
- **Native rollups.** [EIP-8079](https://eips.ethereum.org/EIPS/eip-8079) lets L1 re-execute an L2 block (`EXECUTE`). There's no separate proof system to trust, and no Security Council needed for it. ethrex ships a runnable prototype, which is what this repo is tested against.
- **Ephemeral channels.** A channel's outcome is a pure function of (signed request, input, L1 state at an anchor). There's no long-lived L2 application state, so there's very little to secure and nothing to recover when the operator is gone.

## The model

| | Where it lives | Lifetime |
|---|---|---|
| Assets (escrow) | L1 `ChannelSettlement` | Until settle, exit or refund |
| Application state the channel reads | Any L1 contract, proven at an anchor | Permanent (it's L1) |
| Channel computation | L2 `ChannelExecutor` + an approved module, run via `STATICCALL` | One transaction |
| Outcome | An L2 receipt (`ChannelOutcome` log), proven into an L1-accepted block | Until settled |
| Settlement | L1 | Permanent |

**Stateful apps** (the clearing app; [model](docs/guide/stateful-runtime.md)) differ:

| | Where it lives | Lifetime |
|---|---|---|
| L1 reads | Calls into imported L1 contracts at their L1 addresses, at the head the executor follows (skim's stream); every value proven at that head (`crates/app-executor`) | Per execution: one head each; the next execution sees the newer head |
| AppState (accounts, book, nonces) | `ClearingBook` on the app executor, which L1 doesn't trust | Across L1 heads and batches, for one session |
| Escrow, the account root, queues, payouts | L1: a session (`ClearingChannel` + `ClearingDisputes` behind a minimal proxy; optimistic, one-transaction challenges per fill or account), opened by the app's `ClearingVault` | Until the session closes and users redeem or roll over |

**Lifecycle:** open and fund on L1 → preview against newer anchors as L1 changes (no reopen) → every participant signs one final request → it executes on L2 → L1 accepts the L2 block (re-execution) → the receipt is proven and the channel settles once. Without settlement by the deadline, anyone can refund. If the operator is gone, anyone can start the [emergency exit](docs/guide/stage-2.md).

## What we measured

| | Result |
|---|---|
| **Native verification, end to end** | On ethrex's EXECUTE prototype, with no mocks anywhere in the test: an unprivileged account submitted every L2 block, L1 re-executed each, the accepted roots matched ethrex's own, and the channel settled 1.4 / 0.6 exactly once ([log](docs/experiments/m3-native-ethrex.md)) |
| **Live L1 reads via skim** | Sepolia anchors promoted only by skim's light-client `finalized`/`safe` heads. Witnesses (WETH, 2 slots plus code) collected at those exact roots in **~1 s**, 13 KB each ([log](docs/experiments/m1-live-skim.md)) |
| **Fast confirmation** | Lighthouse v8.3.0 `fast_confirmation`: anchors confirmed at the chain head, **69–77 blocks ahead of finality** ([log](docs/experiments/m4-fcr.md)) |
| **Settlement cost** | L1 `settle` 320k gas (1-tx L2 block) → ~396k (127 or 255 txs); `settleFromBlock` 281k vs. 315k per channel (forge, two in one block); evidence 2.5–3.5 KB ([log](docs/experiments/m4-settlement-cost.md)) |
| **Native verification cost** | ~16M gas per L2 block (the gas limit is charged even for empty blocks): **not cheaper than L1**, see [app channels](docs/guide/app-channels.md) |
| **App channels (accounting, mock verifier)** | Operator gone before or after checkpoints: every right rebuilt from L1 events and calldata alone and claimed; the vault drains exactly; the one-day fence holds ([log](docs/experiments/app-channels-accounting.md)) |
| **Stateful clearing** | One app's Solidity state carried across L1 heads on an executor that follows skim's stream, with the oracle price in per-round segments; optimistic settlement with the account root on L1: 14.6k gas per fill (dense) vs 45.5k for the same batch fully verified at once and 67.4k as one L1 transaction per fill. Multi-batch reorg recovery, proofs fetched before rollback, handover from L1 data alone, forced orders and freeze; disposable sessions as ~0.5M-gas proxies. Live following through skim, and a devnet that settles on Sepolia ([log](docs/experiments/clearing.md)) |
| **Prediction rounds** | Optimistic rounds, about 4–15× cheaper per user than the same game on L1 at 100 users. Review fixes for challenge periods, request coverage, deadlines and witness loss ([cost](docs/experiments/prediction-round-cost.md), [fixes](docs/experiments/prediction-review-fixes.md)) |
| **Correctness** | Rust, Solidity and TypeScript suites (`scripts/check.sh`); every security check mutation-checked (removing it makes a named test fail) |

## Architecture

| Path | Role |
|---|---|
| `crates/channel-types` | Anchors, terms, policy, requests, execution profiles: EIP-712 commitments, strict decoding |
| `crates/channel-witness` | Exact-root L1 witness packages and their verifier; `AnchorBook` (confirmation, reorgs, prefetch); fork-tolerant header decoding |
| `crates/channel-receipts` | Receipt tries: roots, proofs, strict receipt decoding |
| `crates/channel-runner` | The runtime and the `skim-channels` CLI: hash-checked headers, skim and FCR confirmation sources, receipt evidence |
| `contracts/` (L1) | `ChannelSettlement`, `EmergencyExit`, `AnchorRegistry`, `AnchorSender`, `CanonicalBlockRegistry` + `RollupGovernance`, `NativeRollupRegistry`, message queues, `BatchSettler` |
| `contracts/` (L2) | `ChannelExecutor`, `L2AnchorInbox`, `L1StateReader`, modules (`SplitModule`) |
| `contracts/src/verifiers` | `WitnessVerifier`, `ReceiptVerifier`, `ExecuteVerifier` (EXECUTE), `ProofDependencyVerifier` (EIP-8288 adapter, not deployable yet) |
| `crates/channel-app` | App channels: exit/credit trees, the reference ledger (mock prover), net diffs, recovery from L1 data |
| `contracts/src/app` | `AppChannelVault`, `AppLeaves`, `IAppCheckpointVerifier`, `MockAppCheckpointVerifier` (labeled mock) |
| `contracts/src/predict`, `contracts/src/clearing` | Prediction rounds (optimistic); clearing (`ClearingBook` on the app executor; on L1, `ClearingVault` opening sessions as `Clone1167` proxies of `ClearingChannel` + `ClearingDisputes`, `ClearingCodec`, and `ChainlinkAdapter` for each segment's price; `ClearingLedger` shared; cost controls `ClearingDirectBatch`, `ClearingL1`) |
| `ts/runtime` | The stateful runtime: the clearing operator, the batch journal and recovery engine, executor checkpoints, the wallet gateway, `L1ReadView` (snapshots, price witnesses, canonical checks), the evidence store, session recovery packages |
| `ts/` | viem cross-checks of every commitment; `e2e.ts` (two anvil chains), `e2e-native.ts` (ethrex), `e2e-app.ts` (app-channel recovery), `e2e-predict.ts`, `e2e-clearing.ts`, `e2e-sessions.ts`, `e2e-executor.ts`, `e2e-subscription.ts`, `live-executor.ts` and `live-subscription.ts` (need `SKIM_RPC`), `devnet.ts` |
| `crates/app-executor` | The app network's EVM (revm): app state over imported L1 accounts, following L1's head through skim's stream and proving its working set at each head; write rules; standard JSON-RPC |

## Quick start

```console
$ cargo test --workspace                       # Rust (anvil tests run if anvil is installed)
$ cd contracts && forge test                   # Solidity
$ cd ts && npm ci && npm run check-encodings   # Rust ↔ Solidity ↔ viem commitments
$ cargo build -p channel-runner && cd ts && npm run e2e   # Read-and-Split on two anvil chains
```

Requires Rust 1.97, Foundry and Node ≥ 23. The native e2e needs an ethrex checkout built with native rollups. See [Getting started](docs/guide/getting-started.md).

## Documentation

| What you need | Guide |
|---|---|
| The project in three lines, and the questions people ask | [FAQ](docs/guide/faq.md) |
| Decide whether channels fit your app | [Use cases](docs/guide/use-cases.md) |
| Compare with optimistic and zk rollups and state channels | [Compared](docs/guide/compared.md) |
| Build, test and run the end-to-end demos | [Getting started](docs/guide/getting-started.md) |
| Understand anchors, witnesses, execution and settlement | [How it works](docs/guide/how-it-works.md) |
| See what skim provides and what it doesn't | [Using skim](docs/guide/using-skim.md) |
| Native verification, registries, data availability and blobs | [Native verification](docs/guide/native-verification.md) |
| What to deploy once, contract sizes and costs | [Deployment](docs/guide/deployment.md) |
| The `skim-channels` CLI | [CLI reference](docs/guide/cli.md) |
| What's verified and what's trusted | [Trust and correctness](docs/guide/trust-and-correctness.md) |
| Exits without the operator, governance, forced inclusion | [Stage 2](docs/guide/stage-2.md) |
| Known failure modes and their causes | [Troubleshooting](docs/guide/troubleshooting.md) |
| Apps on channels: proven checkpoints, L1-locked assets, withdraw any time | [App channels](docs/guide/app-channels.md) |
| Stateful apps: L1 read view, AppState, L1 settlement, trust boundary | [Stateful runtime](docs/guide/stateful-runtime.md) |

Full index: [docs/README.md](docs/README.md).

## Correctness rules this project lives by

- **Unknown state is never zero.** A read the witness doesn't cover is an error. Zero needs a proof of absence.
- **One execution, one authenticated L1 root.** Proofs from two roots never mix, and a cached value never passes for a proof at a newer root.
- **Every anchor is re-authenticated on L1.** Settlement accepts only anchors whose hash matches L1's own block hash.
- **Mocks are labeled and can't pass as native.** A settlement deployed for a native profile rejects a mock registry.
- **Exactly one terminal transition** per channel: settle, exit or refund.

## Trust model

See [Trust and correctness](docs/guide/trust-and-correctness.md). In short:
- Execution is verified by L1 re-execution.
- Block data is on L1.
- L1 reads are Merkle-proven against authenticated roots.
- Funds never leave L1.

What remains trusted:
- skim's light client, for `safe`/`finalized`;
- a full beacon node, for FCR;
- ethrex's EXECUTE prototype, which is not production software.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

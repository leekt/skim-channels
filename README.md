# skim-channels

Experimental: **Skim Execution Channels**, ephemeral execution channels on a Native Rollup
that read authenticated Ethereum L1 state (via [skim](../skim)) and settle on L1. Design
target: a Stage 2 Native Rollup with ephemeral execution channels ([STAGE2](docs/STAGE2.md)).

Not for production funds. Execution verification is **mocked** until a native-rollup
verifier exists (M3). See [HANDOFF](docs/HANDOFF.md).

| Path | What |
|---|---|
| `crates/channel-types` | Anchors, terms, policy, final request, execution profile: canonical ABI / EIP-712 commitments, strict decoding |
| `crates/channel-witness` | Exact-root L1 witness packages and their verifier, anchor lifecycle (`AnchorBook`), `stateReady` vs `proofReady`, the skim `eth_getProof` bridge |
| `crates/channel-receipts` | Receipt trie (`RLP(index)` keys, EIP-2718 values): roots, proofs, strict receipt/header decoding, fixtures |
| `crates/channel-runner` | RPC runtime and the `skim-channels` CLI: hash-checked headers, skim confirmations, witnesses, L2 receipt evidence |
| `contracts/` | Foundry. L1: `ChannelSettlement` (settle/refund/emergency exit), `AnchorRegistry`, `CanonicalBlockRegistry`. L2: `ChannelExecutor`, `L1StateReader`, `L2AnchorInbox`. Libraries: RLP, MPT, receipts, witnesses. Labeled mocks |
| `ts/` | viem cross-check of every commitment; `e2e.ts`, Read-and-Split on two anvil chains |
| `fixtures/` | Rust-generated: encodings, receipt trie (130 receipts), witness packages (H0/H1 plus bad cases) |
| `experiments/` | e2e gas and size measurements |
| `docs/` | [PROJECT](docs/PROJECT.md) (spec), [STAGE2](docs/STAGE2.md), [HANDOFF](docs/HANDOFF.md) |

```sh
scripts/check.sh          # everything: fmt, clippy, Rust, fixtures, forge, viem, e2e (if anvil)
cargo test --workspace    # Rust only
```

Requires Rust 1.97 (pinned in `rust-toolchain.toml`, same as skim `df686b7`), Foundry, Node ≥ 23.

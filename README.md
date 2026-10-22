# skim-channels

Experimental: **Skim Execution Channels**, ephemeral execution channels on a Native Rollup
that read authenticated Ethereum L1 state (via [skim](../skim)) and settle on L1. Design
target: a Stage 2 Native Rollup with ephemeral execution channels ([STAGE2](docs/STAGE2.md)).

Not for production funds. Block acceptance is **mocked** until M3; see [HANDOFF](docs/HANDOFF.md).

| Path | What |
|---|---|
| `crates/channel-types` | Anchors, terms, policy, final request, execution profile: canonical ABI / EIP-712 commitments, strict decoding |
| `crates/channel-witness` | Exact-root L1 witness packages and their verifier, anchor lifecycle (`AnchorBook`), `stateReady` vs `proofReady`, the skim `eth_getProof` bridge |
| `crates/channel-receipts` | Receipt trie (`RLP(index)` keys, EIP-2718 values): roots, proofs, strict receipt/header decoding, fixtures |
| `contracts/` | Foundry: `ChannelTypes` library, `IAcceptedBlockRegistry`, `MockAcceptedBlockRegistry` (labeled mock) |
| `ts/` | viem cross-check of every commitment |
| `fixtures/` | `encodings/commitments.json` (Rust → Solidity, TS), `receipts/block-130.json` (for the M2 L1 verifier) |
| `docs/` | [PROJECT](docs/PROJECT.md) (spec), [STAGE2](docs/STAGE2.md), [HANDOFF](docs/HANDOFF.md) |

```sh
scripts/check.sh          # everything: fmt, clippy, Rust tests, fixture freshness, forge, viem
cargo test --workspace    # Rust only
```

Requires Rust 1.97 (pinned in `rust-toolchain.toml`, same as skim `df686b7`), Foundry, Node ≥ 23.

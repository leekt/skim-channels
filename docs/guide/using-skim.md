# Using skim

skim is the channels' **L1 data source**. The runtime talks to an unmodified skim node over JSON-RPC. There's no crate dependency, and skim's code is unchanged (pinned to `df686b7`).

## What it provides

| Need | skim feature | Code |
|---|---|---|
| L1 state proofs for witnesses | `eth_getProof` at an exact block hash (EIP-1898 `{blockHash}`); skim assembles EIP-1186 proofs from SNAP answers and verifies them before returning | `channel_witness::source::{SkimRpc, collect_witness}` |
| Confirmed anchors | `safe` / `finalized`, which skim answers only with light-client-authenticated execution hashes | `channel_runner::RpcConfirmations::skim` |
| Headers | `eth_getBlockByHash` / `ByNumber`; the runtime rebuilds the RLP and requires it to hash to the block hash | `channel_runner::fetch_header` |
| Contract code | `eth_getCode` | `collect_witness` |

## Trust boundary

- **Re-verified, not trusted:** every proof skim returns is checked against the anchor's state root (`channel_witness::verify`). The runtime decides account presence from the proof, not from the answer's fields, so a wrong or stale answer fails closed.
- **Trusted:** skim's light client, for `safe` and `finalized`. That's the trust-minimized component this project builds on.

## Verified live

On Sepolia (see [M1 live skim](../experiments/m1-live-skim.md)):
- finalized and safe anchors were promoted only by skim's authenticated heads;
- witnesses for WETH (account, code, two slots) were collected at those exact roots, ~13 KB each, in ~1 s;
- a ~19-minute-old finalized root was still served.

## Not used (yet)

- **skim's BAL-maintained cached values.** They're modelled as *state-ready but not proof-ready*: a value kept current from BALs has no Merkle proof at the newer root, so it can't back an execution (`channel_witness::readiness`).
- **`eth_call` / `eth_simulateV1`.** Previews run on L2 (`ChannelExecutor.preview`).
- **Subscriptions and block streams.**

## Limits

- **Recent roots only.** skim serves proofs only for state roots its peers still keep. An emergency exit at an old anchor may need an archive node; the refund path covers the case where no witness can be obtained.
- **No raw headers.** skim has no `debug_getRawHeader`, so headers are rebuilt from JSON, which requires alloy to know the fork's header shape. Nodes that serve raw headers (ethrex, anvil) are used raw.
- **Not the e2e L1.** The end-to-end runs use anvil and ethrex as L1, because skim follows Glamsterdam networks like Sepolia. skim is exercised by the live tests.

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

## Used by the stateful runtime (`ts/runtime/l1view.ts`)

The clearing app ([stateful runtime](stateful-runtime.md)) also uses:

| Need | skim feature |
|---|---|
| Which watched contracts changed, block by block, and rewinds after reorgs | `skim_streamNext` with `bal: {addresses}` (state changes from block access lists); `rewind` events |
| A batch's single snapshot | `eth_getBlockByNumber("safe")` (or `finalized`, or N confirmations): one block, then every read names its hash |
| Previews (state-ready) | `eth_getStorageAt` at `{blockHash}`; on skim a tracked key is kept current from BALs. Never an execution input |
| Execution inputs (proof-ready) | `eth_getProof` at `{blockHash}`, verified again by `L1View` on the executor |

Measured live on Sepolia: [clearing runtime](../experiments/clearing-runtime.md#live-skim-on-sepolia-skim_rpc-npm-run-live-skim).

## Not used (yet)

- **`eth_call` / `eth_simulateV1`.** Computation-channel previews run on L2 (`ChannelExecutor.preview`). The clearing app runs on its own executor.
- **`skim_subscriptionStatus` / pinned subscriptions (`skim.yaml`).** The runtime asks for proofs per batch instead.

## Limits

- **Recent roots only.** skim serves proofs only for state roots its peers still keep. In the live run, a block 64 back was served, and blocks 256 or more back weren't even returned by number. An emergency exit at an old anchor may need an archive node; the refund path covers the case where no witness can be obtained. For prediction rounds, watchers pin the resolution witness while it's still served ([evidence retention](../experiments/prediction-review-fixes.md#a4-losing-the-resolution-witness)).
- **No raw headers.** skim has no `debug_getRawHeader`, so headers are rebuilt from JSON, which requires alloy to know the fork's header shape. Nodes that serve raw headers (ethrex, anvil) are used raw.
- **Not the e2e L1.** The end-to-end runs use anvil and ethrex as L1, because skim follows Glamsterdam networks like Sepolia. skim is exercised by the live tests.

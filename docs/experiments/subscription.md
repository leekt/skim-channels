# Subscription-first L1 reads

**Date:** 2026-10-23. **Design:** [following L1](../guide/stateful-runtime.md#imported-l1-accounts-the-app-executor-crates-app-executor), [oracle segments](../guide/stateful-runtime.md#oracle-segments-the-batch-price-follows-the-head-too). **Code:**
- `crates/app-executor/src/follow.rs` (stream, proving, adoption);
- `metrics.rs`;
- `ClearingBook` segments, `ClearingChannel.propose` / `ClearingDisputes.challengeFill`.

**Tests:** `ts/e2e-subscription.ts` (anvil), `ts/live-subscription.ts` (Sepolia through skim), `contracts/test/clearing/ClearingSegments.t.sol`.

## The acceptance run

**The scenario:** start one session; act against H; update the L1 dependency; act again against H+1. Nobody calls `executor_pin` or `executor_sync`, and nothing restarts. The second action must see the new L1 value, and earlier app state must remain.

| | anvil (polling) | Sepolia through skim (`skim_streamNext`) |
|---|---|---|
| Action 1 | Block 1: saw 42 | Block 11 975 637: saw 42 |
| L1 change | `set(43)` | `set(43)` in block 11 975 638 |
| Executor at the new block | By itself, 378 ms after the change | By itself, 2–204 ms after the change's receipt (two runs) |
| Action 2 | Saw 43; `count` = 2 | Saw 43; `count` = 2 |
| Proofs the second action needed | 0 (3 warm reads) | 0 (3 warm reads) |
| Network per followed block | 1 `eth_getProof` (one account in the working set), 0 code, 1 header | 1 `eth_getProof`, 0 code, 6 header requests (see below), 1 stream apply |
| Proving per block (background) | ~2 ms | 409–948 ms |
| Read latency through the app network | cold 4.3 ms, warm 0.57 ms | cold 753–828 ms (proved via skim), warm 0.56–0.87 ms |
| Stream cross-check | — | 1 state-ready change, 0 mismatches with the proofs |
| Restart with the same `--state-dir` | — | The stream continued from its stored cursor (block 11 975 638 → 11 975 640) |

**Clearing, the same scenario with the oracle** (anvil):
1. One session, one batch. Fill 1 at 2000.
2. The feed moves to 2100 on L1.
3. Fill 2, in the same batch, runs at the new head and starts segment 1 by itself.

The book holds two segments: 2000 at block 20 and 2100 at block 21, from fill 1. App state carries across them (alice ends with 1 ETH and 2050 USD). The proposal carried both price witnesses, and L1 verified each at its own anchor (1.44M gas for the proposal). A watcher can't challenge either fill, and the batch finalizes.

**Forge** (`ClearingSegments.t.sol`), on two recorded anchors (6000 at block 100, 7000 at block 101):
- each fill passes against its own segment;
- the same 7000 fill is a provable fault if the proposal claims a single 6000 segment;
- a challenger can't substitute prices (the commitment is checked);
- the segment shape is checked: starts at fill 0, strictly increasing, below the fill count, one start per witness.

**Regressions from the review of 174ecfc** (`e2e-subscription`, `ClearingSegments.t.sol`, `test-runtime`):
1. **The feed moves after a batch opens, before its first fill.** Before, the batch held an empty segment from opening, and the first fill added a second one at fill 0. L1 then refused the proposal (`[0, 0]`). Now segments start at fills: one segment, at the new price.
2. **The head moves and the round doesn't.** Before, the fill reused the old segment and its block, so expiry and freshness were judged in the past. Now the fill starts a segment at its own head, and an order that expired by then is refused. L1 accepts the reused price (one witness for two heads), checks freshness at the later head, and disputes judge expiry there.
3. **A later segment's block is reorged out.** Before, `tick()` checked only the opening block. Now it checks every segment head, and recovers from that batch.
4. **A crash mid-recovery.** Before, the originals were replaced by the partial replay, so a restart lost the actions not yet replayed. Now the originals stay until the replay is complete.

## What it shows, and what it doesn't

- **Shown:**
  - Ordinary L1 head advancement costs the app nothing on the execution path.
  - Each new head costs one proof per account in the working set, off that path.
  - Executions read only proof-ready values at one head.
  - App state and overlays survive, and the stream cursor survives restarts.
  - A newer oracle context costs one more witness in the next proposal: no new session, re-pin or L1 keep-alive.
- **State-ready isn't trusted.** skim doesn't serve full block access lists over JSON-RPC, so this process can't check the stream's changes against the header's access-list hash. Two things would let the working set roll forward from authenticated access lists instead of re-proving each block:
  - a raw-access-list RPC in skim;
  - or running the follower inside skim, which already verifies access lists.
- **Header requests.** The follower re-reads the head after each stream wait: 6 header requests per Sepolia block here. It could use the head the stream reports.
- **Proving cost grows with the working set.** It's one `eth_getProof` per account per block. Clearing's set is 4 accounts (the channel's two halves, the feed's proxy and aggregator).

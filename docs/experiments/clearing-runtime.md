# Clearing runtime: skim → stateful Solidity → L1 net settlement

**Date:** 2026-10-22. **Model:** [stateful runtime](../guide/stateful-runtime.md). **Code:**
- contracts: `contracts/src/clearing/` (`ClearingRules`, `ClearingApp`, `L1View`, `ClearingSettlement`, `ClearingChecker`);
- runtime: `ts/runtime/` (`l1view.ts`, `executor.ts`, `clearing.ts`, `evidence.ts`).

## What runs where

- **L1 (anvil, chain 900):** a price feed (one storage slot), `AnchorRegistry`, `ClearingSettlement` with `ClearingChecker`, and a test USD token.
- **Executor (a second anvil, chain 7001; local, not trusted):** `L1View` and `ClearingApp`.
- **L1 reads:** `eth_getProof` witnesses at one pinned block per batch, via the `skim-channels` CLI.
  - **Deterministic run:** anvil's RPC.
  - **Live run:** a skim node following Sepolia.

## Deterministic e2e (`npm run e2e-clearing`)

All checks pass:

| Requirement | What happened |
|---|---|
| A at snapshot H, L1 changes, B at H+1 | Batch 1 pins block 16 (price 2000). Alice sells 0.5 ETH to bob at 2000. L1's price moves to 2100. Batch 2 pins block 18. An order priced at 2000 is refused (outside the band); one at 2100 fills. `L1View` still reads 2000 at H and 2100 at H+1. Batch 1's fills and alice's −1 ETH of unsettled obligations across both batches stay in AppState |
| Same snapshot, same result | A fresh executor pins the two batches' witnesses **from the evidence store** and replays both logs: every action has the same outcome, and `stateDigest` is equal |
| Fail-closed reads | A tampered witness, a header that isn't the witness's anchor, and a slot that wasn't witnessed are all refused by `L1View` (mixed roots, wrong values, presence lies: the forge `L1ViewTest`) |
| Reorg | Batch 5 runs on `latest`; carol sells 0.1 ETH at 2100. `anvil_reorg` replaces that block with one setting the price to 2500. The runtime sees the anchor left the chain, rolls the executor back, and replays on the new head: the fill is outside the band and dropped, and nothing from the reorged block survives |
| Signature, nonce, double fill, double collateral | Same order again → `AlreadySeen`; a new order on a spent nonce → `StaleNonce`; the same pair twice → `UnknownOrder`; carol's order signed by bob → `BadSignature`; carol's 1 ETH offered twice → the second fill `Insufficient`. L1 checks the same: forge `test_nonceReuseAcrossBatchesRejected`, `test_duplicateFillInOneBatchRejected`, `test_collateralCantBeUsedTwice` |
| Partial withdrawal, trading continues | Batch 3 has alice selling 0.6 ETH. She then reserves 0.5 ETH on L1. L1 now refuses the batch (`Undercollateralized`), so the runtime rebases batch 3 on a new snapshot and the fill is dropped. Alice withdraws 0.5 ETH and keeps trading: batch 4 sells 0.4 ETH. L1 settles batch 3 (empty) and batch 4 |
| Operator gone | Batch 6 trades and is sealed but never proposed. Nothing is pending on L1. Every trader withdraws everything with no operator: the escrow ends with 0 USD and only the operator's bond in ETH. Batch 6's fill exists only in AppState: it's not an L1 obligation |
| Evidence | Witnesses for batches L1 hasn't finalized (5 and 6) are still pinned. Finalized batches' witnesses were released |

forge (`contracts/test/clearing`): 12 settlement tests, plus 3 `L1View` tests, plus a cost suite. 22 mutants of the clearing contracts, all caught. Among the tests:
- netting in execution order (a buyer may spend proceeds of an earlier fill, not of a later one);
- price band, limits, expiry;
- unrecorded, old and mixed-root anchors;
- a forged signature challenged, then an honest batch;
- finalize only with the proposed effects after the window.

## Live: skim on Sepolia (`SKIM_RPC=… npm run live-skim`)

Run against a skim node at Sepolia head 11,970,156. Data: [`data/live-skim-clearing.json`](data/live-skim-clearing.json).

| Check | Result |
|---|---|
| State-ready changes | `skim_streamNext` with `bal: {addresses: [WETH]}` reported 31 WETH storage and balance changes over 4 blocks, from block access lists |
| One snapshot, proof-ready | `safe` block 11,970,153: skim's `eth_getStorageAt` value equals the value the executor's `L1View` verified from skim's proofs at that block hash. 13,152 B (WETH slot plus an absent account), 331 ms |
| AppState across snapshots | An order submitted at snapshot A is still in the book at snapshot B (11,970,155); A still reads 5,674,171,053,967 and B reads 0 |
| Fail-closed collateral | No escrow exists on Sepolia, and the traders' account slots weren't witnessed, so `available()` is refused, not zero |
| Reorg signal | `skim_streamNext` from snapshot A: 0 rewinds; A still canonical |
| Where proofs stop | 64 blocks back: served. 256 or more blocks back: skim returned no block by number in this run, so there's no snapshot there at all |

**What the live run doesn't do:**
- No settlement on Sepolia (no escrow was deployed there).
- No orders were filled.
- The deterministic run covers settlement, and uses anvil, not skim.

## Cost (measured; L1 only — executor gas is not an L1 cost)

| Category | Step | Gas | Source |
|---|---|---|---|
| **Entry** | `deposit` ETH / USD (first) | 92,198 / 110,802 | anvil receipts |
| **Exit** | `requestWithdraw` (first) | 118,111 (anvil) / 118,503 (forge) | |
| | `claimWithdraw` | 51,350 (anvil) / 49,042 (forge) | |
| **Batch, fixed** | `AnchorRegistry.record` | ~100,600 each | anvil |
| | `proposeBatch`, empty batch, 1.8 KB price witness | 334,404 | anvil |
| **Batch, per fill** | `proposeBatch`, 1 / 8 / 32 fills, 6.2 KB fixture witness | 852,053 / 1,200,989 / 2,414,369 (≈ 50k per extra fill) | forge model |
| | `proposeBatch`, 1 / 2 fills, 1.8 KB witness | 377,388 / 425,684 | anvil |
| | `finalize`, 1 / 8 / 32 fills (2 / 16 / 64 traders, first settlement each) | 134,540 / 573,466 / 2,078,304 | forge |
| | `finalize`, later batches (1 fill) | 62,576 | anvil |
| **DA (calldata)** | fills | 800 B for 1, 5,952 B for 8, 23,616 B for 32 (≈ 740 B per fill: two orders and two signatures) | |
| | L1 price witness | 1.8 KB (anvil), 6.2 KB (fixture), 13.2 KB for two accounts on Sepolia via skim | |
| **Dispute** | `challengeSignature`, batch of 1 / 8 / 32 fills | 78,880 / 192,726 / 622,524 (the whole batch is resubmitted) | forge |

**Later finding:** [clearing v2](clearing-v2.md#cost-against-batched-and-per-transaction-controls) added a control: the same batch with every signature verified at once and no window. v1's optimistic-signature design saves at most about 10k per fill against it, and costs more for sparse batches. v1 is kept only as a baseline.

**Reading the numbers:**
- **L1 cost scales with fills.** A batch pays the witness verification once (300k–800k, depending on trie depth), plus ≈ 50k gas and ≈ 740 B of calldata per fill.
- **L1 re-checks each fill rather than trusting the executor.** That is the price of not trusting it.
- **`finalize` costs ≈ 32k per trader** the first time (new nonce-floor slots), less afterwards.
- **No comparison** with running the same clearing directly on L1 was measured for this app.

## Not done, or not checked

- **A live settlement through skim:** no escrow or price feed was deployed on a Glamsterdam network.
- **Rust tests for the runtime:** the runtime is TypeScript (viem), and its checks are the e2e and live scripts.
- **Censorship resistance for orders, partial fills, more assets, blob DA:** see [what's not built](../guide/stateful-runtime.md#whats-not-built).

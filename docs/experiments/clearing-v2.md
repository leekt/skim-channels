# Clearing v2: optimistic settlement with the app's state committed on L1

**Date:** 2026-10-23. **Code:** `contracts/src/clearing/` (L1: `ClearingChannel` + `ClearingDisputes` + `ClearingCodec` over `ClearingStorage`; shared: `ClearingLedger`, `ClearingRules`; executor: `ClearingBook`, `L1View`); `ts/runtime/clearing2.ts`; `ts/e2e-clearing-v2.ts`. **Baselines:** `ClearingSettlement` (v1), `ClearingDirectBatch`, `ClearingL1`.

## What changed from v1

| | v1 (`ClearingSettlement`) | v2 (`ClearingChannel`) |
|---|---|---|
| What L1 checks per fill | Price band, limits, expiry, nonces and collateral, all at proposal | **Nothing**: only that the fills hash matches. Disputes check one fill or one account on demand |
| What's optimistic | Signatures only | Everything per fill, through two non-interactive challenges |
| Account state on L1 | Balances in storage, written per trader at finalize | **One account root.** A proposal publishes only the changed leaves (220 B each) and a multiproof; L1 computes the new root |
| Fills on L1 | ABI-encoded, about 740 B each | Packed, **236 B each** (traders as indices) |
| Who can propose | The operator | The operator; **anyone after `takeoverDelay`** without a proposal |
| Continuing after the operator is gone | Not possible: AppState lived only on the executor | Everything needed is on L1: finalized root, published leaves and fills, queues. `ClearingBook.adopt` checks the rebuilt state against the root |
| Order censorship | No answer | **Forced orders**: posted on L1, they must be filled or published as resting within `forceDelay`, or anyone freezes |
| Withdrawals | Reserve now, claim after the earlier batches resolve | Queued, served at the start of a batch (before its fills), claimed from the finalized leaf. An unserved request past `forceDelay` lets anyone freeze, and every user exits from L1 |

**One transition function.** The rules live in `ClearingLedger`:
- **The functions:** `applyDeposits`, `applyRequest`, `applySide`, applied per account in that order (deposits, then requests, then fills).
- **Who uses them:**
  - `ClearingBook` uses them as it executes;
  - `ClearingCodec.replay` uses them when a challenge replays an account on L1.
- **What `challengeAccount` catches:** a wrong balance, a stale nonce, a sale the balance can't cover, an omitted trader, or a request skipped, applied early, or consumed without its deposits.
- **What `challengeFill` catches:** a bad signature, price band, limit, expiry, same side, or unknown trader.

## Verification

- **forge:** `ClearingChannelTest` has 28 tests.
- **Mutation:** 40 mutants of the v2 contracts, all caught except one equivalent: `finalize`'s frozen check, which a freeze already makes unreachable by clearing the pending batch.
- **anvil e2e** (`npm run e2e-clearing-v2`), two executors:

| Step | Result |
|---|---|
| Batches 1–2 (price 2000 → 2100) | AppState kept across snapshots. Alice's 0.2 ETH request is served at batch 2's start and claimed on L1 while trading continues. After every batch, a watcher simulates a challenge on every account and fill: nothing to challenge, and L1's root equals the operator's state |
| A wrong proposal | Bob's leaf is 1 unit off. The watcher finds it and wins the bond with `challengeAccount`. Then the honest batch is proposed and finalizes |
| A forced order | Carol posts it on L1. Batch 4 takes it in (hash checked against L1) and fills it. L1 checks the status (`0x0001`: fill 0, side a) |
| Handover | Operator A goes silent for 2 days. Operator B rebuilds every account from L1 calldata alone, and `adopt` accepts them because their root equals L1's finalized root (read through a proof). B's batch continues with the same nonces and balances. L1 counts 5 finalized batches across the handover |
| Forced order ignored | Freeze is refused before the deadline and works after it. Every user exits, and the channel ends with 0 ETH and 0 USD |

## Cost, against batched and per-transaction controls

`contracts/test/clearing/ClearingCompare.t.sol` measures one batch in steady state (accounts exist, deposits applied), priced as L1 transactions. Data: [`data/clearing-compare.json`](data/clearing-compare.json).

| Gas per fill | v2 | v1 | **direct batch** (same batch, every signature verified, settled at once) | one L1 tx per fill |
|---|---|---|---|---|
| Dense: 128 fills, 16 users | **14,600** | 35,649 | 45,491 | 67,406 |
| Sparse: 32 fills, 64 users (each trades once) | 60,037 | 104,833 | 90,459 | 67,404 |
| 256 fills, 32 users | **11,552** | — | — | 67,405 |

**What this says:**
- **v1's design choice doesn't pay.** Making only signatures optimistic saves about 10k per fill against verifying them at once in the dense case, and costs more in the sparse case, in exchange for a 1-hour window and a watcher. The direct batch is the better version of v1. v1 stays in the repo only as a measured baseline.
- **v2 is cheaper only when accounts trade densely.** The cost is per changed account (a 220 B leaf plus multiproof hashing), not per fill. At several fills per account per batch it's 3–5× cheaper than the direct batch and 4.6–5.8× cheaper than per-transaction L1. When every account trades once, it's at about break-even with per-transaction L1 (60k vs 67k).
- **What every design pays per batch:** about 700k for the fixture's 6.2 KB price witness (anvil's small trie: about 330k), plus about 100k to record the anchor.

**Dispute gas (worst case, 256-fill batch):**
- `challengeAccount` for an account in 16 of 256 fills: 2.71M.
- `challengeFill` on the last fill: 2.49M.
- Both are dominated by resubmitting the batch's fills (about 60 KB of calldata). That caps a batch at `MAX_FILLS` = 256, well inside the 16.7M transaction cap.

## Open (see also the runtime review below)

- **Runtime recovery is incomplete**, as reviewed on `5db7064` (v1 runtime); the v2 runtime reused the same pattern:
  - `rebase` handles only the last batch;
  - a failed proof fetch mid-rebase loses the batch;
  - rejected actions are replayed;
  - skim rewinds aren't consumed automatically;
  - `canonical()` can't say "unknown";
  - with real block progress, a pre-built batch's anchor ages out.

  These are the next work and are not fixed in this commit.
- **Resting orders that were never published** are lost on handover. Forced orders and on-L1 data are not. Users can resubmit.
- **A discarded proposal:** the executor must re-execute from L1's state. The runtime doesn't automate this yet.

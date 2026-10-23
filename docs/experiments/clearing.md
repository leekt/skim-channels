# Clearing: skim → stateful Solidity → optimistic L1 settlement

**Date:** 2026-10-23. **Model:** [stateful runtime](../guide/stateful-runtime.md). **Code:**
- L1: `contracts/src/clearing/`: `ClearingChannel` + `ClearingDisputes` + `ClearingCodec` over `ClearingStorage`.
- Shared: `ClearingLedger`, `ClearingRules`.
- Executor: `ClearingBook`, `L1View`.
- Cost controls: `ClearingDirectBatch` + `ClearingChecker`, `ClearingL1`.
- Runtime: `ts/runtime/` (`l1view`, `executor`, `batches`, `clearing`, `evidence`, `tree`).

## Design

| | |
|---|---|
| What a batch publishes | Packed fills (236 B each: both orders and signatures), changed account leaves (220 B each) with a multiproof, a price-only L1 witness, queue cursors, forced-order statuses, and a bond |
| What L1 checks at proposal | The price at a recorded, recent anchor; that the old leaves are in the finalized root (L1 computes the new root itself); queue cursors; forced-order statuses. **Nothing per fill** |
| What a watcher can prove (one transaction each) | `challengeFill`: a bad signature, band, limit, expiry, same side, or unknown trader. `challengeAccount`: L1 replays one account (deposits → requests → fills) with `ClearingLedger` and compares it to the published leaf. This catches a wrong balance, a stale nonce, an uncovered sale, an omitted trader, or a request skipped, applied early, or consumed without its deposits |
| Who proposes | The operator. After `takeoverDelay` without a proposal, anyone with a bond |
| Exits | Withdrawal requests are served at the start of a batch and claimed from finalized leaves. A request or forced order unserved past `forceDelay` lets anyone freeze, and everyone exits from the finalized leaf |
| Policy bounds | `challengeWindow` from 1 h to 30 d, with 2 × window ≤ `forceDelay`; `forceDelay` from 1 d to 60 d; `takeoverDelay` ≤ 60 d; `maxAnchorAge` ≤ 8191 blocks |

**An earlier design was measured and dropped.** It checked every fill's economics on L1 and left only signatures optimistic. Against the same batch fully verified at once (below), it saved at most about 10k gas per fill, and cost more for sparse batches. That isn't worth a challenge window and a watcher.

## Verification

- **forge** (`contracts/test/clearing`):
  - 28 channel tests: honest batches survive every challenge; a forged signature, an out-of-band fill, an overpaid account, an omitted trader, nonce reuse across batches, collateral used twice, the request rules, a partial replay, false evidence, an unknown trader index, forced orders (resting, filled, ignored then freeze), takeover, the policy floors and bounds.
  - 3 `L1View` tests: mixed roots, wrong values, presence lies, and unwitnessed reads all refused.
  - 4 cost runs.
- **Mutation:** 40 mutants of the clearing contracts, all caught except one equivalent: `finalize`'s frozen check, already unreachable because a freeze clears the pending batch.
- **Deterministic e2e** (`npm run e2e-clearing`: anvil L1 with only its last 512 states kept, so old proofs really are refused, and blocks advance with time; operators A and B on local executors):

| Area | What happened |
|---|---|
| State across snapshots | Batch 1 at price 2000, batch 2 at 2100. Alice's withdrawal request is served at batch 2's start and claimed on L1 while trading goes on. Bob's unfilled order rests across batches. After every batch, a watcher simulates a challenge on every account and fill: nothing to challenge, and L1's account root equals the operator's |
| Replay | The journal's first two batches replayed on a fresh executor from the pinned proofs give the same `stateDigest` |
| Standard wallet flow | Through the gateway's JSON-RPC: `eth_chainId` equals the orders' EIP-712 chain; `eth_getBalance` shows ETH in the channel; fees are 0; alice and bob sign orders as typed data and place them with ordinary transactions (viem, as a wallet does: nonce `pending`, fee estimation, `eth_sendRawTransaction`, receipts). Refused with standard errors, consuming no nonce: a plain transfer, a deployment, `fill` (operator-only), a stale-nonce order, someone else's order, `anvil_setBalance`, `eth_sendTransaction`. The users' raw transactions are replayed byte for byte in the journal replay |
| Fail-closed | A tampered witness, a header that isn't the anchor, and an unproven slot are refused by `L1View` |
| A wrong proposal | Bob's leaf is off by 1. The watcher finds it and wins the bond with `challengeAccount`; then the honest batch finalizes |
| Forced order | Taken in from L1 (hash checked), filled, and its status checked on L1 |
| R1: dependent batches, reorg | Speculative batch S1: alice sells 0.1 ETH to dave. S2: dave sells it on to bob. `anvil_reorg` replaces both anchor blocks with a chain where alice reserved her ETH. `tick()` recovers from **S1** (the earliest) and replays both: S1 fails (`Insufficient`), then S2 has nothing to sell. Dave ends with no ETH |
| R2: proofs unavailable | A recovery onto a block whose state the node no longer keeps stops first (`proof-unavailable`). Executor digest, batches and journal are all unchanged. A height the node can't answer is `unknown`, not a reorg |
| R3: aged, rejected not retried | The open batch's anchor ages out; `tick()` re-pins it. A fill rejected earlier (dave unfunded) is reported as `notRetried`, not replayed, even though dave is funded now. His order rests for an explicit re-match |
| R4: real block progress | While batch P waits out its window (300 blocks), batch Q is built. Q's anchor is then older than `maxAnchorAge` (256 blocks), so the runtime refuses to propose it until `tick()` re-pins it |
| R5: executor lost | Executor A dies with one batch proposed and one unproposed. A fresh executor is rebuilt: `adopt` from L1's finalized state, the pending batch re-executed from the journal, the unproposed one replayed. Then both settle |
| Handover | A goes silent for 2 days. Operator B rebuilds every account from L1 calldata alone; `adopt` accepts them (their root equals L1's) and B continues |
| Freeze | A forced order nobody serves. Freeze is refused before its deadline and works after it. Every user exits, and the channel ends with 0 ETH and 0 USD |

- **Live** (`SKIM_RPC=… npm run live-skim`, a skim node following Sepolia; read path only, nothing settled):
  - `skim_streamNext` reports WETH state changes from block access lists.
  - Proofs at a `safe` block (~13 KB, 0.3–0.6 s) verify on the executor and match skim's state-ready value.
  - `ClearingBook` carries AppState from snapshot A to snapshot B.
  - An order from someone with no escrow in the channel is refused, and an unproven slot can't be read.
  - The runtime's rewind signal (`skimRewound`) works on skim.
  - Skim served proofs 64 blocks back, and returned no block by number from 256 back.

## Cost (L1 gas, measured)

`contracts/test/clearing/ClearingCompare.t.sol` measures one batch in steady state (accounts exist, deposits applied), priced as L1 transactions. Data: [`data/clearing-compare.json`](data/clearing-compare.json).

| Gas per fill | Channel (propose + finalize) | Direct batch (same fills, all verified at once) | One L1 tx per fill |
|---|---|---|---|
| Dense: 128 fills, 16 users | **14,600** | 45,489 | 67,404 |
| Sparse: 32 fills, 64 users (each trades once) | 60,037 | 90,455 | 67,399 |
| 256 fills, 32 users | **11,552** | — | 67,403 |

| Category | Step | Gas | Source |
|---|---|---|---|
| Entry | first deposit ETH / USD | ~92k / ~111k | anvil receipts ([`data/clearing-e2e.json`](data/clearing-e2e.json)) |
| Exit | `requestWithdraw`; `claim`; `exit` after a freeze | ~121k; ~92k; ~90k per user | anvil |
| Batch, fixed | price witness + anchor record | ~330k (anvil trie) to ~700k (6.2 KB fixture witness), + ~100k record | forge, anvil |
| DA | fills 236 B each; changed accounts 220 B each plus multiproof nodes | 34 KB for 128 fills / 16 users | forge |
| Dispute | `challengeAccount` (an account in 16 of 256 fills) / `challengeFill` (last of 256) | 2.71M / 2.49M, mostly resubmitting the batch's calldata | forge |

**What this says:**
- **The channel is 3–5× cheaper than verifying the same batch at once, and 4.6–5.8× cheaper than per-transaction L1, when accounts trade several times per batch.** Its cost is per changed account (a leaf plus multiproof hashing), not per fill.
- **When every account trades once per batch,** it's close to break-even with per-transaction L1 (60k vs 67k).
- **Every design pays the price witness and the anchor once per batch.**

## Open

- **Real wallet extensions:** MetaMask and Rabby weren't driven here. The e2e uses the same RPC calls a wallet makes (via viem), and the typed-data chain-id rule they enforce is checked.

- **Matching isn't forced:** a forced order must be published, not matched.
- **Unpublished resting orders** don't survive a handover.
- **A discarded proposal:** the runtime should rebuild from L1 automatically. Today the operator calls `recover`.
- **Live settlement through skim** needs a Glamsterdam network with the channel deployed.
- **Partial fills, more assets, blob DA.**

# Clearing: skim → stateful Solidity → optimistic L1 settlement

**Date:** 2026-10-23. **Model:** [stateful runtime](../guide/stateful-runtime.md). **Code:**
- L1: `contracts/src/clearing/`: `ClearingVault` (the app's identity), which opens sessions as EIP-1167 proxies (`Clone1167`) of `ClearingChannel` + `ClearingDisputes` over `ClearingStorage`, with `ClearingCodec`.
- Shared: `ClearingLedger`, `ClearingRules`.
- Executor: `ClearingBook` on the app executor (`crates/app-executor`), which follows L1's head and imports the channel and the Chainlink feed read-only.
- Price on L1: `ChainlinkAdapter` (proofs at the block each price was read; freshness re-checked at each fill's head).
- Cost controls: `ClearingDirectBatch` + `ClearingChecker`, `ClearingL1`.
- Runtime: `ts/runtime/`: `clearing` (the operator), `batches` (journal, recovery), `executor` (starts the app executor), `gateway` (wallet JSON-RPC), `l1view` (snapshots, price witnesses, canonical checks), `evidence`, `recovery` (session packages), `tree`.

## Design

| | |
|---|---|
| What a batch publishes | Packed fills (236 B each: both orders and signatures), changed account leaves (220 B each) with a multiproof, its execution segments (each fill's L1 head, recorded on L1) with one price witness per new price, queue cursors, forced-order statuses, and a bond |
| What L1 checks at proposal | Each price at the recorded, recent block it was read (`ChainlinkAdapter`: the pinned proxy and aggregator code, the latest round there); each segment head recorded and recent, read no earlier than its price, the price fresh at the head's time; all committed with the batch; that the old leaves are in the finalized root (L1 computes the new root itself); queue cursors; forced-order statuses. **Nothing per fill** |
| What a watcher can prove (one transaction each) | `challengeFill`: a bad signature, band (against the fill's own segment), limit, expiry (at the fill's own head), same side, or unknown trader. `challengeAccount`: L1 replays one account (deposits → requests → fills) with `ClearingLedger` and compares it to the published leaf. This catches a wrong balance, a stale nonce, an uncovered sale, an omitted trader, or a request skipped, applied early, or consumed without its deposits |
| Who proposes | The operator. After `takeoverDelay` without a proposal, anyone with a bond |
| Exits | Withdrawal requests are served at the start of a batch and claimed from finalized leaves. A request or forced order unserved past `forceDelay` lets anyone freeze, which closes the session; everyone redeems from the final leaf ([sessions](sessions.md)) |
| Policy bounds | `challengeWindow` from 1 h to 30 d, with 2 × window ≤ `forceDelay`; `forceDelay` from 1 d to 60 d; `takeoverDelay` ≤ 60 d; `maxAnchorAge` ≤ 8191 blocks |

**An earlier design was measured and dropped.** It checked every fill's economics on L1 and left only signatures optimistic. Against the same batch fully verified at once (below), it saved at most about 10k gas per fill, and cost more for sparse batches. That isn't worth a challenge window and a watcher.

## Verification

- **forge** (`contracts/test/clearing`):
  - 35 channel tests: honest batches survive every challenge; a forged signature, an out-of-band fill, an overpaid account, an omitted trader, nonce reuse across batches, collateral used twice, the request rules, a partial replay, false evidence, an unknown trader index, forced orders (resting, filled, ignored then freeze), takeover, the policy floors and bounds.
  - 6 `ChainlinkAdapter` tests on a recorded Sepolia witness: the price `latestRoundData()` returns at the anchor; an aggregator the proxy doesn't point at, unpinned proxy or aggregator code, a stale answer (judged at the anchor's time), an unrecorded or old anchor, and tampered proofs are all refused.
  - 9 segment tests (`ClearingSegments.t.sol`):
    - each fill against its own segment;
    - a fill provable against a wrong single price;
    - neither prices nor heads can be substituted;
    - a reused price doesn't stop the clock: expiry is judged at the later head;
    - a reused price must be fresh at the later head;
    - the shape is checked: no empty `[0, 0]` segment, heads increasing and recorded, every witness used, each price read no later than its head, none without fills.
  - 14 session tests (`ClearingSession.t.sol`): the vault opens proxy sessions, Active → Closing → Closed, redeem and rollover with one payout record (only after close, only a final leaf), pull bonds, `depositFor` only from the vault and `fund` only into its sessions, chunked `publishFinal`.
  - Segment tests include `challengeRound`: a reused price whose head had a newer round is a provable fault, and the challenge ends with the window.
  - 6 cost runs (including opening a session: ~0.5M gas, and publication).
- **Mutation (2026-10-25):** 71 mutants over the rules, ledger, codec, disputes (including `challengeRound`), sessions, vault, segments and the adapter.
  - The first run left 11 alive. Tests now catch 10 of them: same-side and below-limit fills, a lone segment not starting at fill 0, `challengeRound` after the window, `redeem` before close or with a forged leaf, `depositFor` from a non-vault caller, `fund` into a contract the vault didn't open. The two adapter mutants (the proxy pointing elsewhere, a zero answer) are caught by `e2e-clearing` on live witnesses.
  - One is equivalent: the segment-head age check, since a head is never older than the price it uses, whose age the adapter already bounds.
  - The earlier run, 40 mutants before sessions and segments, had one equivalent too (`finalize`'s frozen check).
- **Deterministic e2e** (`npm run e2e-clearing`: anvil L1 with only its last 512 states kept, so old proofs really are refused, and blocks advance with time; operators A and B on local executors):

| Area | What happened |
|---|---|
| State across heads | Batch 1 at price 2000, batch 2 at 2100. Alice's withdrawal request is served at batch 2's start and claimed on L1 while trading goes on. Bob's unfilled order rests across batches. After every batch, a watcher simulates a challenge on every account and fill: nothing to challenge, and L1's account root equals the operator's |
| Replay | The journal's first two batches replayed on a fresh executor from the retained proofs give the same `stateDigest` |
| Standard wallet flow | Through the gateway's JSON-RPC: `eth_chainId` equals the orders' EIP-712 chain; `eth_getBalance` shows ETH in the channel; fees are 0; alice and bob sign orders as typed data and place them with ordinary transactions (viem, as a wallet does: nonce `pending`, fee estimation, `eth_sendRawTransaction`, receipts). Refused with standard errors, consuming no nonce: a plain transfer, a deployment, `fill` (operator-only), a stale-nonce order, someone else's order, `anvil_setBalance`, `eth_sendTransaction`. The users' raw transactions are replayed byte for byte in the journal replay |
| Fail-closed | Pinning the executor to a block L1 doesn't have is refused; the channel is read-only on the app network; no overlay is ever written into an imported account |
| Feed upgrade | The feed's proxy switches aggregators: L1's adapter refuses a price from the new one, and the executor can't price a batch from it (not imported) |
| A wrong proposal | Bob's leaf is off by 1. The watcher finds it and wins the bond with `challengeAccount`; then the honest batch finalizes |
| Forced order | Taken in from L1 (hash checked), filled, and its status checked on L1 |
| R1: dependent batches, reorg | Speculative batch S1: alice sells 0.1 ETH to dave. S2: dave sells it on to bob. `anvil_reorg` replaces both anchor blocks with a chain where alice reserved her ETH. `tick()` recovers from **S1** (the earliest) and replays both: S1 fails (`Insufficient`), then S2 has nothing to sell. Dave ends with no ETH |
| R2: proofs unavailable | A recovery onto a block whose state the node no longer keeps stops first (`proof-unavailable`). Executor digest, batches and journal are all unchanged. A height the node can't answer is `unknown`, not a reorg |
| R3: aged, rejected not retried | The open batch's anchor ages out; `tick()` reopens it at a recent head. A fill rejected earlier (dave unfunded) is reported as `notRetried`, not replayed, even though dave is funded now. His order rests for an explicit re-match |
| R4: real block progress | While batch P waits out its window (300 blocks), batch Q is built. Q's anchor is then older than `maxAnchorAge` (256 blocks), so the runtime refuses to propose it until `tick()` reopens it at a recent head |
| R5: executor lost | Executor A dies with one batch proposed and one unproposed. A fresh executor is rebuilt: `adopt` from L1's finalized state, the pending batch re-executed from the journal, the unproposed one replayed. Then both settle |
| Handover | A goes silent for 2 days. Operator B rebuilds every account from L1 calldata alone; `adopt` accepts them (their root equals L1's) and B continues |
| Freeze | A forced order nobody serves. Freeze is refused before its deadline and works after it, closing the session. Every user redeems; after bond withdrawals the channel ends with 0 ETH and 0 USD |

- **Live** (`SKIM_RPC=… npm run live-executor`, a skim node following Sepolia; read path only, nothing settled):
  - An app contract calls Chainlink's ETH/USD proxy at its Sepolia address on the app executor. It gets what Sepolia returns at the executor's head (proxy and aggregator code and 5 slots verified, 46 KB of evidence).
  - The slots `ChainlinkAdapter` verifies at that block decode to the same answer and time (a 15 KB price witness).
  - App state carries across heads. With only the proxy imported, the read reverts.
- **Live, following** (`live-subscription`): the executor moves to each Sepolia block through `skim_streamNext` by itself ([subscription](subscription.md)).

- **Devnet** (`npm run devnet`, [guide](../guide/stateful-runtime.md#try-it-in-a-browser-the-devnet-tsdevnetts)): locally (anvil and a Chainlink-layout feed), the smoke test takes a fresh wallet through faucet, deposit, a fill, a withdrawal and a claim. On Sepolia (`SEPOLIA_OPERATOR_KEY`), the session's contracts live on Sepolia and every L1 read and write goes through skim; the smoke test's deposit, fill and withdrawal request ran there, and batches are proposed to Sepolia.

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
| Batch, fixed | price witness + record, per new price; header record per further fill head | Chainlink adapter: ~2.18M execution + 15.2 KB witness (Sepolia, `ChainlinkAdapter.t.sol`); + ~100k record. A `getRoundData` check would be tens of thousands ([evaluation](chainlink-rounds.md)) | forge |
| DA | fills 236 B each; changed accounts 220 B each plus multiproof nodes | 34 KB for 128 fills / 16 users | forge |
| Dispute | `challengeAccount` (an account in 16 of 256 fills) / `challengeFill` (last of 256) | 2.71M / 2.49M, mostly resubmitting the batch's calldata | forge |

**What this says:**
- **The channel is 3–5× cheaper than verifying the same batch at once, and 4.6–5.8× cheaper than per-transaction L1, when accounts trade several times per batch.** Its cost is per changed account (a leaf plus multiproof hashing), not per fill.
- **When every account trades once per batch,** it's close to break-even with per-transaction L1 (60k vs 67k).
- **Every design pays a price witness and its anchor once per price used** (one per batch unless the feed's round changes mid-batch), plus a header record (~100k) per further L1 head fills ran at.

## Open

- **Real wallet extensions:** MetaMask and Rabby weren't driven here. The e2e uses the same RPC calls a wallet makes (via viem), and the typed-data chain-id rule they enforce is checked.

- **Matching isn't forced:** a forced order must be published, not matched.
- **Unpublished resting orders** don't survive a handover.
- **A discarded proposal:** the runtime should rebuild from L1 automatically. Today the operator calls `recover`.
- **Finalization and claims on Sepolia** wait out real challenge windows; see the devnet.
- **Partial fills, more assets, blob DA.**

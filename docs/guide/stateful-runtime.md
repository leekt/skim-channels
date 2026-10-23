# Stateful apps: state model and trust boundary

The computation channels in [how it works](how-it-works.md) keep no application state on L2: an outcome is a pure function of a signed request, an input and L1 state at one anchor. This page covers the second path, for apps that **keep their own state across many interactions**. It is built and tested for one app, **clearing**:
- contracts: `contracts/src/clearing`;
- runtime: `ts/runtime`;
- executor: `crates/app-executor`;
- tests: `ts/e2e-clearing.ts`, `ts/e2e-sessions.ts`, `ts/e2e-executor.ts`, `ts/live-executor.ts`.

Results and costs: [clearing](../experiments/clearing.md).

The two paths are separate:
- `ChannelExecutor` keeps its STATICCALL-only modules.
- The stateful app runs its own contracts on its own executor.

## Three kinds of state

| | What | Where | Who can change it |
|---|---|---|---|
| **Imported L1 state** | The L1 contracts the app declares (for clearing: its channel and the Chainlink feed's proxy and aggregator), at the L1 head the executor follows | L1, called at their L1 addresses on the app executor; every value fetched through skim with a proof | Nobody: imported read-only, so nothing on the app network can write to them |
| **AppState** | Every account exactly as L1 commits it (balances, deposit and withdrawal counters, nonce floor), the order book, the open batch | `ClearingBook` (Solidity) on the **executor** | Only through `ClearingLedger`, driven by signed orders, the operator's fills, and L1's queues |
| **L1 settlement** | Real money; the **account root**; the withdrawal and forced-order queues; payout records | `ClearingChannel` on L1 | Deposits, finalized batches (optimistic, challengeable), claims and exits |

**L1 head changes don't reset AppState.**
- The executor follows L1's head; each transaction runs against one head (below).
- Accounts, resting orders and nonces carry over from head to head and from batch to batch.
- The app reads, with ordinary calls at the current head:
  - the price, with `latestRoundData()` on Chainlink's proxy (the risk band), recorded per [oracle segment](#oracle-segments-the-batch-price-follows-the-head-too);
  - the channel's user list, deposits, and withdrawal and forced-order queues, when a batch opens.

**Collateral:**
- A fill may spend only the trader's balance in the account L1 commits: L1 deposits, minus withdrawals released, plus fills, checked fill by fill in execution order.
- An L1 balance read from elsewhere (a wallet, a pool) is **not** collateral.

## The executor is not a trust root

`ClearingBook` runs on the **app executor** (`crates/app-executor`, below), a local EVM.
- **It runs the app's real Solidity code.** The app logic was not rewritten in TypeScript or Rust.
- **Nothing on L1 trusts it.**
  - L1 receives every fill (both signed orders, packed) and the changed accounts, and computes the new account root itself.
  - Any watcher can prove a bad batch with one transaction, and the proposer's bond goes to the challenger:
    - `challengeFill`: a bad signature, price band, limit or expiry;
    - `challengeAccount`: L1 replays one account through the batch with the same `ClearingLedger` the executor ran.
- **No mock verifier is involved,** and no L2 receipt is evidence of anything.
- **What it's trusted for:** liveness only.
  - If the operator stops, anyone may propose after `takeoverDelay`.
  - `ClearingBook.adopt` rebuilds AppState from L1 data alone and checks it against L1's root.
  - Users can always leave through the withdrawal queue, or freeze (which closes the session) and redeem.

## Imported L1 accounts: the app executor (`crates/app-executor`)

The app's Solidity can call L1 contracts **at their L1 addresses**, e.g. `AggregatorV3Interface(feed).latestRoundData()`, and run their real code against L1 state at the head the executor has applied. The executor is revm over two layers, served over standard JSON-RPC:

- **Imported accounts** (the addresses the app declares) are L1's at the current head. Balance, nonce, code and storage are fetched on first use with `eth_getProof` (through skim) and verified against that head's state root. Absence and zero are proven too. Code is fetched separately and must hash to the proven code hash. A value that can't be fetched and verified fails the transaction; it never reads as zero.
- **Every other address is app-local** and starts empty, whatever it holds on L1. A contract the app didn't import is empty here, so a call into it reverts. L1 ETH balances are never spendable on the app.

**Write rules, enforced when the write is attempted:**

| Attempt | Result |
|---|---|
| `SSTORE` into an imported account's storage (the frame's storage context, so through a proxy it's the proxy's storage) where L1's value at the head is proven **non-zero** | The frame reverts: `L1SlotProtected(account, slot)` |
| The same where L1's value is proven **zero** | Written to the app's overlay. Later writes are checked against L1's value, not the overlay's |
| The same where L1's value can't be fetched and verified | The whole transaction fails |
| Any write under `STATICCALL` | Refused by the EVM, as anywhere |
| ETH sent from or to an imported account; `CREATE` by one; `SELFDESTRUCT` of or to one | Reverts: `L1AccountProtected(account)` |
| A transaction signed by an imported account | Refused (its nonce is L1's) |

The final state diff is re-checked before commit as well.

**Zero isn't "unused".** A zero flag or mapping entry can matter to an L1 contract. An overlay write there makes the app's copy differ from L1 on purpose.

**Following L1: a subscription, not a held block** (`crates/app-executor/src/follow.rs`):

| | |
|---|---|
| Stream | `skim_streamNext`, subscribed to the imported accounts. It wakes the follower when skim applies a block and reports `rewind` and `gap`. Its cursor is kept on disk (`--state-dir`), so a restart continues the stream. Without skim (another node), the follower polls the head |
| State-ready vs proof-ready | The stream's state changes are skim's word. This process can't authenticate them, because skim doesn't serve the full block access list to check against the header. So they are only cross-checked against proofs and counted (`state_ready_mismatches`), never executed on. Execution reads only **proof-ready** values |
| Warm working set | Every account and slot the app has touched. At each new head the follower proves the whole set in the background, against that head's state root: one `eth_getProof` per account, all its slots. Code is fetched once per code hash |
| Adoption | The proven head replaces the previous one between executions, atomically: an execution always runs against one head, never mixed roots. A dependency touched for the first time is proven at that execution's head on the spot and joins the working set. Overlay slots are always proven at the new head; an unproven slot is never taken as zero |
| App state | Kept across heads; nothing is replayed or erased by ordinary head advancement. If L1 now holds a value at an overlay slot, following stops with the previous head and all state kept, and the conflict is reported (a later explicit rebase or termination policy can resolve it) |
| Which head ran | Each transaction's receipt has `l1BlockNumber` / `l1BlockHash`. Contracts can read the head with a call to the L1 head account `0x…4C31`, which returns `(number, hash, timestamp)` |
| Explicit control | `executor_pin(tag | number | hash)` (replay tooling, debugging, evidence; run with `--follow none`), `executor_sync` (catch up now), `evm_snapshot` / `evm_revert`, `executor_evidence`, `executor_metrics` |

**Execution environment.** Imported code runs against L1 storage, but `block.*`, `msg.sender`, gas and anything in the overlay are the app's. A call returns what L1 would only for equivalent inputs and context.

**Evidence.** `executor_evidence` returns everything verified at the current head as one canonical witness package: accounts (with code where it ran), slots read, and the zero proofs behind overlay writes.

**Settlement still needs its own check.** L1 can't re-run arbitrary L1 code as of a past head by itself. Options include an app-specific adapter that verifies the semantics the app used, witness-backed execution, an interactive fault proof, or EXECUTE. The executor supplies evidence; it doesn't make any of them unnecessary.

**Read-only imports** (`--import-readonly`) take no overlay writes at all (`L1ReadOnly`), so what the app reads there is always L1's value. Clearing imports its channel and the feed this way: the price the book uses is exactly what the L1 adapter verifies.

**Address space.** L1 and the app network share one address space. A key that has deployed on L1 would CREATE onto an imported account's address on the app network (revm refuses: `CreateCollision`). So the runtime deploys each session's book from a key derived from the session: one address on every executor, so users' transactions replay byte for byte.

**Fees** are 0 whatever the wallet signed: gas settles nowhere, so no app-local balance is needed to send.

Tests:
- `npm run e2e-executor`: an anvil L1; 26 checks covering every rule above, a proxy, following L1 by itself with the overlay kept, a conflict that stops following without dropping state, evidence, snapshots, and failing closed.
- `SKIM_RPC=… npm run live-executor`: an app contract reads Chainlink's ETH/USD through its Sepolia proxy, with the proxy and its aggregator imported. It matches Sepolia at the executor's head, and so do the slots the L1 adapter verifies at that block. With only the proxy imported, the read reverts.
- `npm run e2e-subscription` and `SKIM_RPC=… SEPOLIA_OPERATOR_KEY=… npm run live-subscription`: act at H, change the L1 dependency, act again. The executor is at the new block by itself, with no pin, sync or restart. The second action sees the new value, app state is kept, and in clearing, the batch gains a second oracle segment that L1 verifies. Results: [subscription](../experiments/subscription.md).

## Oracle segments: the batch price follows the head too

A batch doesn't hold one price. `ClearingBook` keeps **segments**, each recording:
- the L1 head the feed was read at, and its time;
- the feed's round and price there;
- the first fill priced with it.

The batch opens with segment 0. When a fill executes at a newer head and the feed's round has changed, a new segment starts at that head (`SegmentStarted`). If the round is the same, the price is the same, so the segment and its anchor stay.

- **Operator:** fetches each segment's price witness at its block right away, while the block is recent.
- **L1 at proposal:** verifies every segment's price at its own anchor and commits to the list (`firstFills, prices, anchorBlocks`).
- **Disputes:** `challengeFill` judges each fill against its own segment.
- **Cost of a new oracle context:** nothing beyond one more witness in the next proposal. No new session, re-pin or L1 keep-alive.

## The price on L1: `ChainlinkAdapter`

The executor's `latestRoundData()` call runs Chainlink's code at a head; L1 can't re-run that as of a past block. So each session's price is checked on L1 by an **app-specific adapter**, scoped to the feed it was configured for (`contracts/src/clearing/ChainlinkAdapter.sol`). At proposal it verifies, for each segment, from proofs at the segment's anchor (the head the book read the feed at):

| Check | Rule |
|---|---|
| Anchor | The segment's L1 block: recorded in `AnchorRegistry` (canonical by L1's own `BLOCKHASH`), of this chain, at most `maxAnchorAge` blocks old |
| Proxy | Its code hash is the pinned one (so its layout is known); its current phase (slot 2) points at the one supported aggregator. A switched aggregator is refused, not followed |
| Aggregator | Its code hash is the pinned one (AccessControlledOffchainAggregator layout) |
| Round selection | The aggregator's latest round at the anchor (slot `0x2b`): what `latestRoundData()` returns there |
| Freshness | Answered no later than the anchor's header time, and at most `maxStaleness` before it: decided at the anchor, not when the proposal lands |
| Value | The answer, positive, scaled from the feed's decimals to 6 |

The verified prices are committed with the pending batch, and `challengeFill` judges each fill against its segment's price. Fills aren't checked on L1 at proposal.

**Scope.** This adapter is Chainlink-specific. Other ways to check an L1 read on L1 include witness-backed execution, an interactive fault proof, or EXECUTE. [`getRoundData` as an alternative](../experiments/chainlink-rounds.md) is evaluated separately.

## Snapshots, readiness, reorgs and recovery

- **The executor follows L1; the runtime watches.** A batch opens at the head the executor has applied. Its anchor and segments are what the book recorded, and the receipts say which head each transaction ran against.
  - `snapshot(policy)` still picks the block the operator scans events up to, and the policy used for aging and canonical checks.
  - L1 records an anchor only once a later block exists, so `propose` waits for the next L1 block.
- **stateReady vs proofReady.**
  - `value()` is a node's answer: on skim, a tracked key kept current from block access lists. Previews only.
  - `witness()` returns proofs at the exact block hash (the price witness for L1's adapter). The executor proves everything else it reads at its head itself.
- **Batch lifecycle (`ts/runtime/batches.ts`):**
  - States: `open → sealed → proposed → finalized | discarded`.
  - Each batch records the L1 proposal tx and block, its opening state, its prepared proofs, and every action with its outcome.
  - All of it lives in a journal written atomically to disk.
- **`tick()`** checks every unproposed batch, as an operator loop would:
  - **Orphaned anchor:** skim's `skim_streamNext` reports a rewind, or the node has another block at that height. → recover.
  - **Aged anchor:** the anchor would be too old to propose (`maxAnchorAge` is in blocks). → recover.
  - **Unknown:** the node has no block at that height. This is *not* treated as a reorg; proposing pauses.
- **`recover(from)`:**
  1. Start at the **earliest** affected batch, so later batches that spent its results are included.
  2. Take a new snapshot and **fetch its proofs first**. If that fails (`proof-unavailable`), nothing changes.
  3. Record the intent in the journal.
  4. Roll the executor back to the batch's checkpoint (`evm_revert`), or rebuild a lost executor. A rebuild never re-executes at an old block: it adopts L1's finalized leaves, plus the pending proposal's leaves (from the journal, or from its calldata on L1), checked against L1's pending root.
  5. Replay **only accepted actions** into one batch on the new snapshot.
  - Actions that no longer hold are reported as `dropped`.
  - Actions rejected before are reported as `notRetried` and never retried. Re-matching resting orders is a separate, explicit step.
- **Determinism:** the journal replayed on a fresh executor with the same proofs gives the same `stateDigest`.

## Evidence retention (`ts/runtime/evidence.ts`)

- **What's retained:** each batch's proofs, raw header included, kept apart from any cache until L1 finalizes the batch.
- **Not needed for safety:** clearing's L1 price is verified when the batch is proposed, and every fill and leaf is in calldata. The retained proofs are what replay and recovery use.
- **Prediction rounds** use the same store for resolution witnesses ([details](../experiments/prediction-review-fixes.md#a4-losing-the-resolution-witness)).

## Withdrawals, forced orders, handover

- **`requestWithdraw(token, amount)`** joins a queue and is served at the start of a batch, before its fills. It releases up to `amount` of what is free and covers every deposit made before it. The release is claimable (`claim`) once the batch is final.
- **`forceOrder(order)`** posts an order from the trader's own L1 transaction. A finalized batch must fill it or publish it as resting within `forceDelay`.
- **Freeze:** a request or forced order unserved past `forceDelay` (≥ 1 day) lets anyone freeze. Freezing closes the session at once (below).
- **Handover:** after `takeoverDelay` without a proposal, anyone with a bond proposes.
- **Bonds are pulled:** a finalized proposal's bond, and a challenge reward, are credited (`bondCredit`, `withdrawBond`). A proposer that can't receive ETH blocks nothing.

## Sessions: open, close, start again

The app is stable; its execution sessions are disposable. One **`ClearingVault`** is the app's identity and holds users' free balances.

**Opening a session is registering configuration.**
- The session code (`ClearingChannel` + `ClearingDisputes`, 23.6 KB) is deployed once per app.
- `vault.openSession(implementation, config)` creates a 45-byte EIP-1167 proxy of it and initializes it in the same transaction, setting the vault, its token and the next id. That costs ~0.5M gas.
- Before proxies, each session redeployed its code: ~35.7M gas on Sepolia under Amsterdam's code pricing.
- Configuration lives in the session's storage, which costs about +1.7% per batch in reads.
- Pointing `openSession` at a new implementation is how a new session opts into new code.

The session id is the `salt` of the standard EIP-712 domain, so an order signed for one session never verifies in another.

```
vault ── session 1: run → close ── session 2: run → close ── …
```

**Lifecycle: Active → Closing → Closed.**

| Phase | What can happen | Who must be watching |
|---|---|---|
| Active | Deposits, requests, forced orders, batches. Idle costs no L1 transactions | Someone: after `takeoverDelay` anyone may propose, so an idle session can still receive a claim |
| Closing (`beginClose`: the operator, or anyone once the session is idle for `takeoverDelay`) | The admission cutoff is fixed: no deposits, requests or forced orders. Only the operator may still propose, to settle what it executed, and only until `takeoverDelay` after Closing began. So Closed is reachable by anyone within `takeoverDelay` + one challenge window | Watch until nothing is pending |
| Closed (`close`: nothing pending; the operator, or anyone `takeoverDelay` after Closing began; or a freeze) | Terminal. No proposal, takeover, finalize or reopening. The final root never changes | Nothing, once the close transaction is final on L1 |

**After close, each user redeems alone** (`redeem(idx, leaf, path, toVault)`). They get the final leaf's balances, plus deposits no batch applied, plus released withdrawals, minus everything already paid:
- Queued withdrawal requests and unapplied deposits are covered.
- Forced orders not filled by then are void, since nothing was traded.
- No executor, watcher, oracle read or new execution proof is involved.

**Rollover.** `redeem(…, toVault = true)` pays the same entitlement into the vault as the user's free balance:
- **Who may do it:** only the user.
- **Shared accounting:** the wallet path and the vault path share one payout record, so earlier claims are deducted and nothing is paid twice.
- **Isolation:** a closed session keeps its outstanding liabilities. The vault never takes funds from a session, and a credit must arrive with its ETH and USD.
- **Funding a new session:** the user moves free balance in with `vault.fund(session, token, amount)`. The operator can't move anyone's funds.
- **What carries over:** only settled funds. Session 2 starts with an empty order book and empty AppState.

**Recovery material** (`ts/runtime/recovery.ts`):
- **What it holds:** the **session package** has every final leaf and the user list, as a passive file. A **claim file** has one user's leaf and path.
- **How it's checked:** anyone verifies a package against the session's final root with current-state reads only (no logs, no old transactions). A package that doesn't rebuild the root is refused.
- **Optional publication on L1:** `publishFinal(start, leaves, path)` takes aligned chunks of 2^k leaves, each accepted only if it is part of the final root.
  - Cost is linear: about 5k execution gas plus 108 calldata bytes per user, and each chunk is bounded.
  - Publication doesn't promise that nodes keep serving that calldata: history retention isn't guaranteed by the protocol. Keep the file.

Measured end to end: [sessions](../experiments/sessions.md).

## Wallets: a standard JSON-RPC (`ts/runtime/gateway.ts`)

The app network serves the same JSON-RPC as other L2s, so MetaMask, Rabby, viem or cast connect to it like any EVM network. What a user can do there is limited to the app.

| | |
|---|---|
| Add the network | `wallet_addEthereumChain`: `chainId` = the app network's id (the executor's, e.g. 7001), `rpcUrls` = the gateway, `nativeCurrency` ETH/18 |
| Reads | `eth_chainId`, `eth_blockNumber`, `eth_getBlockBy*`, `eth_call`, `eth_estimateGas`, `eth_getTransactionCount`, `eth_getTransactionBy*`/`Receipt`, `eth_getLogs`, `eth_getCode`, `eth_getStorageAt`, `eth_feeHistory`, `net_*`, `web3_clientVersion` |
| Balance | `eth_getBalance` is the account's ETH **in the channel**: what the user can trade or withdraw |
| Fees | 0 (`eth_gasPrice`, `eth_maxPriorityFeePerGas`, base fee). Gas on the app network settles nowhere; L1 costs are the operator's |
| Writes | `eth_sendRawTransaction` only: an ordinary signed transaction, to `ClearingBook`, calling `submitOrder` (the sender's own order) or `cancel`, with no value, on this chain, and only if it succeeds in simulation |
| Refused | Other contracts and functions (e.g. `fill`, operator-only), value transfers, deployments, `eth_sendTransaction` / `eth_sign*` (the node holds no keys), and the executor's control and debug methods (`executor_*`, `evm_*`, `debug_*`, …), each with a standard JSON-RPC error |
| App methods | `clearing_account(address)` (pending and finalized), `clearing_order(hash)`, `clearing_batches()` |

**Placing an order takes two wallet actions:**
1. Sign the order as EIP-712 typed data (`eth_signTypedData_v4`). The domain is `SkimClearing`, chain = the app network's chain id, and `verifyingContract` = the L1 channel. Wallets only sign typed data for the active chain, so the domain uses the app network's id, which L1 also checks (`appChainId`).
2. Send `submitOrder(order, signature)` as a normal transaction.

The typed signature is what L1 checks in a dispute.

**What goes to L1:** deposits, withdrawal requests and forced orders are L1 transactions, sent from the same wallet on L1. A forced order is authorized by the trader's own L1 transaction (`msg.sender`), so it needs no typed signature for another chain.

**Replays:** every accepted transaction enters the batch journal as its raw bytes and is replayed byte for byte on recovery. Transactions that would revert are refused before inclusion, so they never consume a nonce.

## What's not built

- **Matching guarantees:** a forced order must be published, but nothing forces it to be matched.
- **Resting orders that were never published** are lost when the operator changes.
- **Partial fills, more than two assets, blob DA.**
- **Authenticated state-ready updates.** The follower re-proves its working set at every head (one `eth_getProof` per account), because skim doesn't serve full block access lists to check the stream's changes against ([subscription](../experiments/subscription.md)).
- **A general L1 check of imported calls.** Only Chainlink's `latestRoundData` has an L1 adapter.

## Run it

```console
$ cd contracts && forge build && forge test --match-path 'test/clearing/*'
$ cargo build -p channel-runner -p app-executor
$ cd ts && npm run e2e-clearing                          # deterministic: anvil L1 + local executors
$ cd ts && npm run e2e-sessions                          # close a session, delete everything, start the next
$ cd ts && npm run e2e-executor                          # the executor's write rules and following
$ cd ts && npm run e2e-subscription                      # act at H, change L1, act at H+1 with no pin
$ SKIM_RPC=http://127.0.0.1:18545 npm run live-executor  # live: the real Sepolia feed through skim
```

A wallet connects to the gateway's URL (`new Gateway(operator, port)`; the e2e serves one on `127.0.0.1:18695` while it runs). The executor behind it must not be reachable directly: it has control methods (`executor_pin`, `evm_revert`, …).

## Try it in a browser: the devnet (`ts/devnet.ts`)

```console
$ cd ts && npm run devnet                                                     # local
$ SEPOLIA_OPERATOR_KEY=0x… SKIM_RPC=http://127.0.0.1:18545 npm run devnet     # on Sepolia
$ tailscale serve --bg 8787                                                   # optional: HTTPS on your tailnet
```

One server on `:8787` runs:
- the app network (the app executor, chain 7001, behind the gateway);
- an operator loop;
- a market-making bot;
- a faucet;
- a test app styled with the Schematic design system (vendored in `ts/devnet/schematic`).

| | local | sepolia |
|---|---|---|
| L1 | anvil (chain 900) | Sepolia, every read and write through skim |
| Price | A feed with Chainlink's layout (an aggregator behind a proxy), priced from the page; it re-transmits hourly like a heartbeat | Chainlink's real ETH/USD feed on Sepolia |
| Settlement | On the local chain; “+1 hour” skips challenge windows | On Sepolia, in real time |
| Sessions | One per run (chains reset) | The vault, the session code and the infrastructure are deployed once (`~/.skim-devnet/sepolia.json`). A restart resumes the active session from its journal on a fresh executor. `NEW_SESSION=1` opens a new proxy session (~0.5M gas) and closes the previous one; its users redeem or roll over |

The page says which one it is. It shows the path from the feed to each fill:
- the L1 head the executor is at;
- the accounts it imported, with their code;
- each batch's oracle segments and the witnesses L1's adapter checks;
- every fill's distance from that price.

`npm run devnet-smoke [URL]` runs a fresh wallet through faucet, deposit, a fill, a withdrawal and a claim.

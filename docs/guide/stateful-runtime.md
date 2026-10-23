# Stateful apps: state model and trust boundary

The computation channels in [how it works](how-it-works.md) keep no application state on L2: an outcome is a pure function of a signed request, an input and L1 state at one anchor. This page covers the second path, for apps that **keep their own state across many interactions**. It is built and tested for one app, **clearing**:
- contracts: `contracts/src/clearing`;
- runtime: `ts/runtime`;
- tests: `ts/e2e-clearing.ts`, `ts/live-skim-clearing.ts`.

Results and costs: [clearing](../experiments/clearing.md).

The two paths are separate:
- `ChannelExecutor` keeps its STATICCALL-only modules.
- The stateful app runs its own contracts on its own executor.

## Three kinds of state

| | What | Where | Who can change it |
|---|---|---|---|
| **L1ReadView** | The L1 values an app may read: chosen contracts and slots, at one pinned block per batch | L1, read via skim (`ts/runtime/l1view.ts`), verified into `L1View` on the executor | Nobody. Read-only: the app can't call or write L1 |
| **AppState** | Every account exactly as L1 commits it (balances, deposit and withdrawal counters, nonce floor), the order book, the open batch | `ClearingBook` (Solidity) on the **executor** | Only through `ClearingLedger`, driven by signed orders, the operator's fills, and L1's queues |
| **L1 settlement** | Real money; the **account root**; the withdrawal and forced-order queues; payout records | `ClearingChannel` on L1 | Deposits, finalized batches (optimistic, challengeable), claims and exits |

**L1 head changes don't reset AppState.**
- A batch pins one anchor; the next batch pins a later one.
- Accounts, resting orders and nonces carry over.
- At each anchor the app reads only:
  - the L1 price (the risk band);
  - the channel's user list;
  - the deposits of the users concerned;
  - the withdrawal and forced-order queues.

**Collateral:**
- A fill may spend only the trader's balance in the account L1 commits: L1 deposits, minus withdrawals released, plus fills, checked fill by fill in execution order.
- An L1 balance read from elsewhere (a wallet, a pool) is **not** collateral.

## The executor is not a trust root

`ClearingBook` and `L1View` run on a **local EVM**, an anvil instance in tests.
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
  - Users can always leave through the withdrawal queue, or freeze and exit.

## Imported L1 accounts: the app executor (`crates/app-executor`)

The app's Solidity can call L1 contracts **at their L1 addresses**, e.g. `AggregatorV3Interface(feed).latestRoundData()`, and run their real code against L1 state at the executor's pin. The executor is revm over two layers, served over standard JSON-RPC:

- **Imported accounts** (the addresses the app declares) are L1's at the pin. Balance, nonce, code and storage are fetched on first use with `eth_getProof` (through skim) and verified against the pin's state root. Absence and zero are proven too. Code is fetched separately and must hash to the proven code hash. A value that can't be fetched and verified fails the transaction; it never reads as zero.
- **Every other address is app-local** and starts empty, whatever it holds on L1. A contract the app didn't import is empty here, so a call into it reverts. L1 ETH balances are never spendable on the app.

**Write rules, enforced when the write is attempted:**

| Attempt | Result |
|---|---|
| `SSTORE` into an imported account's storage (the frame's storage context, so through a proxy it's the proxy's storage) where L1's value at the pin is proven **non-zero** | The frame reverts: `L1SlotProtected(account, slot)` |
| The same where L1's value is proven **zero** | Written to the app's overlay. Later writes are checked against L1's value, not the overlay's |
| The same where L1's value can't be fetched and verified | The whole transaction fails |
| Any write under `STATICCALL` | Refused by the EVM, as anywhere |
| ETH sent from or to an imported account; `CREATE` by one; `SELFDESTRUCT` of or to one | Reverts: `L1AccountProtected(account)` |
| A transaction signed by an imported account | Refused (its nonce is L1's) |

The final state diff is re-checked before commit as well.

**Zero isn't "unused".** A zero flag or mapping entry can matter to an L1 contract. An overlay write there makes the app's copy differ from L1 on purpose.

**Moving the pin** (`executor_pin(tag | number | hash)`):
- All app state is kept.
- An overlay slot whose L1 value is still zero at the new pin is kept.
- If L1 now holds a value at an overlay slot, the move is **refused** and the conflict is reported. The previous pin and all state stay as they were. Nothing is dropped implicitly. A later explicit rebase or termination policy can resolve conflicts.

**Execution environment.** Imported code runs against L1 storage, but `block.*`, `msg.sender`, gas and anything in the overlay are the app's. A call returns what L1 would only for equivalent inputs and context.

**Evidence.** `executor_evidence` returns everything verified at the pin as one canonical witness package: accounts (with code where it ran), slots read, and the zero proofs behind overlay writes.

**Settlement still needs its own check.** L1 can't re-run arbitrary L1 code as of the pin by itself. Options include an app-specific adapter that verifies the semantics the app used, witness-backed execution, an interactive fault proof, or EXECUTE. The executor supplies evidence; it doesn't make any of them unnecessary.

Tests:
- `npm run e2e-executor`: an anvil L1; 24 checks covering every rule above, a proxy, pin moves, a refused move on conflict, evidence, snapshots, and failing closed.
- `SKIM_RPC=… npm run live-executor`: an app contract reads Chainlink's ETH/USD through its Sepolia proxy, with the proxy and its aggregator imported. It matches Sepolia at the pin. With only the proxy imported, the read reverts.

## Snapshots, readiness, reorgs and recovery

- **One snapshot per batch.**
  - `snapshot(policy)` returns one block under a confirmation policy: `latest` (speculative), `confirmations n`, `safe` or `finalized` (skim's light client).
  - Every read for the batch names that block hash.
- **stateReady vs proofReady.**
  - `value()` is a node's answer: on skim, a tracked key kept current from block access lists. Previews only.
  - `witness()` returns proofs at the exact block hash. `L1View.pin` verifies them, so a missing slot, mixed roots, a wrong value, or a header that isn't the anchor all revert.
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
  4. Roll the executor back to the batch's checkpoint, or rebuild a lost executor from L1's finalized state plus the journal.
  5. Replay **only accepted actions** into one batch on the new snapshot.
  - Actions that no longer hold are reported as `dropped`.
  - Actions rejected before are reported as `notRetried` and never retried. Re-matching resting orders is a separate, explicit step.
- **Determinism:** the journal replayed on a fresh executor with the same proofs gives the same `stateDigest`.

## Evidence retention (`ts/runtime/evidence.ts`)

- **What's pinned:** each batch's proofs, raw header included, kept apart from any cache until L1 finalizes the batch.
- **Not needed for safety:** clearing's L1 price is verified when the batch is proposed, and every fill and leaf is in calldata. The pinned proofs are what replay and recovery use.
- **Prediction rounds** use the same store for resolution witnesses ([details](../experiments/prediction-review-fixes.md#a4-losing-the-resolution-witness)).

## Withdrawals, forced orders, handover

- **`requestWithdraw(token, amount)`** joins a queue and is served at the start of a batch, before its fills. It releases up to `amount` of what is free and covers every deposit made before it. The release is claimable (`claim`) once the batch is final.
- **`forceOrder(order)`** posts an order from the trader's own L1 transaction. A finalized batch must fill it or publish it as resting within `forceDelay`.
- **Freeze:** a request or forced order unserved past `forceDelay` (≥ 1 day) lets anyone freeze. Freezing closes the session at once (below).
- **Handover:** after `takeoverDelay` without a proposal, anyone with a bond proposes.
- **Bonds are pulled:** a finalized proposal's bond, and a challenge reward, are credited (`bondCredit`, `withdrawBond`). A proposer that can't receive ETH blocks nothing.

## Sessions: open, close, start again

The app is stable; its execution sessions are disposable. One **`ClearingVault`** is the app's identity and holds users' free balances. Each **session** is a `ClearingChannel` registered in the vault with the next id. The session id is the `salt` of the standard EIP-712 domain, so an order signed for one session never verifies in another.

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
| Refused | Other contracts and functions (e.g. `fill`, operator-only), value transfers, deployments, `eth_sendTransaction` / `eth_sign*` (the node holds no keys), and the executor's debug and cheat methods (`anvil_*`, `evm_*`, `debug_*`, …), each with a standard JSON-RPC error |
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
- **A production executor.** The executor is an anvil process; any EVM would do, since L1 doesn't trust it.

## Run it

```console
$ cd contracts && forge build && forge test --match-path 'test/clearing/*'
$ cargo build -p channel-runner
$ cd ts && npm run e2e-clearing                          # deterministic: anvil L1 + local executors
$ cd ts && npm run e2e-sessions                          # close a session, delete everything, start the next
$ SKIM_RPC=http://127.0.0.1:8545 npm run live-skim      # live: a skim node following Sepolia
```

A wallet connects to the gateway's URL (`new Gateway(operator, port)`; the e2e serves one on `127.0.0.1:18695` while it runs). The executor behind it must not be reachable directly: it has cheat methods.

## Try it in a browser: the devnet (`ts/devnet.ts`)

```console
$ cd ts && SKIM_RPC=http://127.0.0.1:18545 npm run devnet   # a skim node following Sepolia
$ tailscale serve --bg 8787                                   # optional: HTTPS on your tailnet
```

One server on `:8787` runs an L1 devnet (anvil, chain 900), the app network (chain 7001, behind the gateway), an operator loop, a market-making bot, a faucet, and a test app styled with the Schematic design system (vendored in `ts/devnet/schematic`).

**The price is Sepolia's live state.** It is Chainlink's ETH/USD on Sepolia, carried in four steps:

| Step | What | Verified by |
|---|---|---|
| 1 | The aggregator's hot-variables slot (latest round) and `transmissions[round]` at skim's `safe` block | storage proofs from skim (`eth_getProof`), ~10.6 KB |
| 2 | `FeedMirror.update(rawHeader, package)` on the L1 devnet (`contracts/src/clearing/FeedMirror.sol`, ~1M gas) | on-chain: header ↔ anchor, both proofs, the round read from the proven slot, blocks only forward. **Trusted:** that the header is canonical on Sepolia (no Sepolia BLOCKHASH here), so only the relay may submit |
| 3 | Each batch pins an L1 devnet block and proves FeedMirror's slot 0 | `L1View` on the executor; L1 again at proposal |
| 4 | Each fill must be within 1% of that price | the executor; `challengeFill` on L1 |

The app shows each step with its values (Sepolia block, round, proof sizes, the L1 block a batch pinned, every fill's distance from the price), plus Sepolia's head value from skim, labeled as unproven. `npm run devnet-smoke [URL]` runs a fresh wallet through faucet, deposit, a fill, a withdrawal and a claim.

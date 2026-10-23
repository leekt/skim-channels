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

- **`requestWithdraw(token, amount)`:**
  - It joins a queue and is served at the start of a batch, before that batch's fills.
  - It releases up to `amount` of what is free, covers every deposit made before it, and is claimable from the finalized leaf.
- **`forceOrder(order, sig)`** posts a signed order on L1. A finalized batch must fill it, or publish it as resting.
- **Freeze:** a request or forced order unserved past `forceDelay` (≥ 1 day) lets anyone freeze. Every user then `exit`s from L1 with their finalized balances, unapplied deposits and released withdrawals.
- **Handover:** after `takeoverDelay` without a proposal, anyone with a bond proposes.

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

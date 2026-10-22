# Stateful apps: state model and trust boundary

The computation channels in [how it works](how-it-works.md) keep no application state on L2: an outcome is a pure function of a signed request, an input and L1 state at one anchor. This page covers the second path, for apps that **keep their own state across many interactions**. It is built and tested for one app: **clearing** (`contracts/src/clearing`, `ts/runtime`, `ts/e2e-clearing.ts`).

> **Update (2026-10-23): [clearing v2](../experiments/clearing-v2.md) supersedes the settlement described below.**
> - L1 commits an account root, and nothing per fill is checked unless challenged.
> - Another operator can take over from L1 data alone.
> - Forced orders and freeze are in.
>
> The measured control showed that v1's "economics on L1, signatures optimistic" doesn't pay against verifying everything at once. The model below (three kinds of state, untrusted executor, snapshots) still holds, and so do the runtime limits [found in review](../experiments/clearing-v2.md#open-see-also-the-runtime-review-below).

The two paths are separate:
- `ChannelExecutor` keeps its STATICCALL-only modules.
- The stateful app runs its own contracts on its own executor.

## Three kinds of state

| | What | Where | Who can change it |
|---|---|---|---|
| **L1ReadView** | The L1 values an app may read: chosen contracts and slots, at one pinned block per batch | L1, read via skim (`ts/runtime/l1view.ts`), verified into `L1View` on the executor | Nobody here. Read-only: the app can't call or write L1 |
| **AppState** | The app's own state: order book, consumed orders and nonces, per-batch obligations (net per trader and token), the batch counter | `ClearingApp` (Solidity) on the **executor** | The app's contract code, driven by signed orders and the operator's fills |
| **L1Settlement** | Real money, finalized balances, reserved withdrawals, nonce floors, payout records | `ClearingSettlement` on L1 | Deposits, finalized batches, withdrawals |

**L1 head changes don't reset AppState.**
- A batch pins one anchor. The next batch pins a later one.
- Resting orders, consumed nonces and unsettled obligations carry over.
- At each new anchor the app re-reads only three things:
  1. the L1 price (the risk band);
  2. each trader's free escrow;
  3. how many batches L1 has finalized, so obligations already in the escrow aren't counted twice.

**Collateral (v1):**
- A fill may spend only what the trader holds in **L1 escrow**, minus amounts reserved for withdrawal.
- Plus the net of every fill L1 hasn't finalized yet.
- The check runs after each fill, in execution order. An L1 balance read from elsewhere (a wallet, a pool) is **not** collateral.

## The executor is not a trust root

`ClearingApp` and `L1View` run on a **local EVM**: a second anvil in tests, labeled as such.
- **It holds AppState and runs the app's real Solidity code.** The app logic was not rewritten in TypeScript or Rust.
- **Nothing on L1 trusts it.**
  - L1 settlement receives every fill (both signed orders) and the batch's L1 price witness.
  - It **re-checks each fill** with the same `ClearingRules` library the app ran: price band against the witnessed L1 price, at a recorded anchor no older than `maxAnchorAge`; limit prices; expiry; per-trader nonces past the finalized floor; and collateral after each fill.
  - **Only signatures are optimistic.** `challengeSignature` takes one order and one `ecrecover`, discards the batch, and pays the bond to the challenger.
- **No mock verifier is involved,** and no L2 receipt is evidence of anything.
- **What it trusts locally:**
  - That a pinned L1 header is canonical. The runtime checks this with skim or the confirmation policy; L1 re-checks it with `AnchorRegistry`.
  - Liveness. If the operator's executor stops, trading stops, but every finalized balance stays withdrawable on L1.

## Snapshots, readiness and reorgs (`ts/runtime/l1view.ts`, `ts/runtime/clearing.ts`)

- **One snapshot per batch.**
  - `snapshot(policy)` returns one block (number, hash, state root) under a confirmation policy: `latest` (speculative), `confirmations n`, `safe` or `finalized` (skim's light client).
  - Every read for the batch names that block hash.
  - Two `latest` calls are never treated as one snapshot.
- **stateReady vs proofReady.**
  - `value()` is a node's answer: on skim, a tracked key kept current from block access lists. It's for previews only.
  - `witness()` returns EIP-1186 proofs at the exact block hash. `L1View.pin` verifies them, so a missing slot, mixed roots, a wrong value, or a header that isn't the anchor all revert.
  - The app can read only what was pinned.
- **Reorgs and drift.**
  - Each batch starts from an executor checkpoint and logs every action and its outcome.
  - Before a batch is proposed, the runtime checks that its anchor is still canonical and that L1 accepts the batch as of now; a withdrawal reservation may have landed in between.
  - If either check fails, `rebase()` rolls the executor back to the batch's checkpoint, takes a new snapshot, and replays the log. Actions that no longer hold are dropped and reported, never forced.
  - On skim, `skim_streamNext` reports rewinds explicitly.
- **Determinism.** The same log replayed on a fresh executor with the same pinned witnesses gives the same `stateDigest`.

## Evidence retention (`ts/runtime/evidence.ts`)

- **What's pinned:** the witness a batch used, raw header included.
- **How long:** until L1 finalizes the batch. It's kept apart from any head cache, so nothing evicts it by age or size.
- **For prediction rounds,** the same store holds resolution witnesses: see [prediction review fixes](../experiments/prediction-review-fixes.md#a4-losing-the-resolution-witness).
- **Clearing doesn't depend on keeping it for safety.** L1 verifies the price witness when the batch is proposed, and the fills and witness are in calldata. The store is for replay and audit.

## Withdrawals and the operator-free path

- **`requestWithdraw(token, amount)`** reserves part of a balance at once. Later batches can't spend it, while trading continues on the rest.
- **`claimWithdraw`** pays once every batch proposed **before** the request is resolved. So a counterparty in a batch already in flight is never short.
- **Without an operator:**
  - A pending batch is finalized by anyone after `challengeWindow` (≥ 1 hour), or discarded by a signature challenge.
  - Finalized balances are always withdrawable.
  - Fills that never reached L1 exist only in AppState. They aren't L1 obligations, and their signed orders can be re-matched only by a future operator.

## What's not built

- **Censorship:** an operator can refuse to match an order. The user's recourse is to withdraw, not to force a trade.
- **Multiple operators** and handover of AppState.
- **Partial fills.** v1 fills both orders whole.
- **More than two assets.**
- **Batches beyond the bounds:** `MAX_FILLS` 128 and `MAX_USERS` 64 per batch, a choice for bounded dispute gas.
- **Blob DA.** Fills are calldata.
- **A production executor.** The executor is an anvil process; any EVM would do, since L1 doesn't trust it.

## Run it

```console
$ cd contracts && forge build && forge test --match-path 'test/clearing/*'
$ cargo build -p channel-runner
$ cd ts && npm run e2e-clearing                          # deterministic: anvil L1 + local executor
$ SKIM_RPC=http://127.0.0.1:8545 npm run live-skim      # live: a skim node following Sepolia
```

Results and costs: [clearing runtime](../experiments/clearing-runtime.md).

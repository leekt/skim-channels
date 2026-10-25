# Clearing: open design choices

**Date:** 2026-10-25. These gaps need a product decision, not just code. Each section lists the options and their costs, and ends with a recommendation. Context: [stateful runtime](../guide/stateful-runtime.md), [clearing](clearing.md).

## 1. Forced orders: published, but never forced to match

**Today:** a forced order (posted by its trader on L1) must be filled or published as resting by a finalized batch within `forceDelay`. Otherwise anyone may freeze the session. Nothing makes the operator *match* it, even when a crossing order rests in the book.

| Option | What L1 enforces | Cost | Catch |
|---|---|---|---|
| A. Keep as is | Inclusion only | None | An operator can leave a forced order resting forever while trading around it |
| B. Must cross the best published price | A batch that publishes the forced order as resting must also publish the book's best opposite price; if they cross, it's a fault | One price per side per batch in calldata, plus a challenge | Needs the resting book on L1 (see 2); the operator can still avoid crossing by never publishing better orders |
| C. Forced orders fill against the operator | The operator must fill a forced order within the band of the oracle price at its head, as counterparty | A per-session operator inventory | Changes the operator into a market maker of last resort; needs collateral rules |
| D. Exit, not trade | A forced order guarantees the user can leave (withdrawal, freeze, redeem), not that they trade | None beyond today | Honest about what's enforceable without a counterparty |

**Recommendation: D now, B once 2 is decided.** Without an L1-visible book, no rule can show that a match was available. Forced inclusion plus the freeze already guarantee exit, which is the property users need from L1.

## 2. Resting orders that were never published are lost on handover

**Today:** a batch publishes fills and the forced orders' statuses, not the book. A new operator rebuilds accounts from L1 (`adopt`). Resting orders are signed messages only the old operator holds.

| Option | Cost | Effect |
|---|---|---|
| A. Keep as is; wallets resubmit | None | Users re-sign or resend after a handover. Orders are cheap to recreate |
| B. Publish a commitment to the book per batch (root of resting orders) | ~32 bytes per batch | Proves what rested, but a new operator still needs the orders themselves |
| C. Publish new resting orders in calldata (~118 B each: packed order and signature) | DA per order, once | A new operator rebuilds the book from L1 alone, like accounts |
| D. Order-relay service outside L1 (any party can mirror the gateway's accepted orders) | Off-chain infra | Works without L1 cost, but trusts a relay for availability |

**Recommendation: A, with C as an option.** For clearing, an order is intent, not funds, and losing it costs a resubmission. C is the honest upgrade if users must not resubmit. Blob DA (3) makes its cost small.

## 3. Partial fills, more assets, blob DA

| Feature | What changes | Effort |
|---|---|---|
| Partial fills | Order state goes from "consumed" (a nonce) to "filled amount" per order hash. `ClearingLedger.applySide` takes a fill amount, and disputes replay per-order fill state | Medium: the leaf, codec and dispute replay all change; new mutation tests |
| More than two assets | Leaves carry a balance vector (or a per-asset subtree), and fills name both tokens | Large: the leaf format, multiproofs and DA cost per changed account all grow |
| Blob DA | Fills and changed leaves go in a blob; `propose` binds the versioned hash; disputes use point-evaluation proofs over the blob | Medium on L1 (KZG precompile); fills are 236 B and leaves 220 B, so DA dominates at scale |

**Recommendation:** blob DA first, since it's the cost driver at volume. Then partial fills, a common need for a clearing venue. More assets only with a concrete market.

## Not decisions, but limits

- **Backdated heads:** an operator may name an earlier recorded head for a fill, down to the block its price was read at, to pass an expiry. L1 can't see when a fill really ran. The bound is that block, and `maxAnchorAge`. A tighter bound needs a time source the fill itself commits to, for example a user-signed "not after" head inside the order (an expiry already does this) or the operator's signed receipt per fill.
- **Wallet extensions:** MetaMask and Rabby weren't driven in automation. The e2e makes the same RPC calls through viem.

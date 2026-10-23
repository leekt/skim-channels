# Evaluation: checking the batch price with `getRoundData(roundId)`

**Date:** 2026-10-23. **Status:** evaluated, not built. Settlement keeps pinned-proof validation (`ChainlinkAdapter`, [guide](../guide/stateful-runtime.md#the-price-on-l1-chainlinkadapter)) as the reference behavior.

## The question

The app executor reads the price with `latestRoundData()` at its pinned block H. Today L1 re-checks that price from storage proofs at H. Could L1 instead check the specific round the executor used, by calling Chainlink's proxy at proposal time: `getRoundData(roundId)`?

## What the current check costs

Measured on the recorded Sepolia witness (`ChainlinkAdapter.t.sol`): **2.18M gas** of execution plus a **15.2 KB** witness in calldata, per batch. That's the largest fixed cost of a batch (see [sessions](sessions.md) for the others).

A `getRoundData` check is two or three external calls into the proxy: tens of thousands of gas, and no witness.

## What `getRoundData` proves, and what it doesn't

- **It proves** round R's answer and timestamps. Chainlink keeps every round: the OCR aggregator's transmissions mapping is append-only. The proxy routes a phase-encoded round id (`phase << 64 | aggregatorRound`) to that phase's aggregator, including after the proxy moves to a new aggregator.
- **It doesn't prove** that R was the round `latestRoundData()` returned at H. On its own, that would let the operator pick any recent round that is still fresh. That's a price-selection option, and within a 1% band it is enough to favor fills.

So the rule needs an explicit round-selection check. Round timestamps make one possible:

> R was the latest round at H ⇔ `updatedAt(R) ≤ time(H) < updatedAt(next(R))`, or next(R) doesn't exist yet.

Here next(R) is R+1 in the same phase, or, if R was the last round of its phase, the first round of the next phase.

Equal timestamps are not ambiguous. Each block has a unique timestamp, so a round with `updatedAt = time(H)` was transmitted in block H itself, and H's post-state already includes it.

## The rule, if built

Executor (ClearingBook): record the round id R it priced the batch with (already returned by `latestRoundData()`).

L1, at proposal, with time(H) from `AnchorRegistry` (H recorded and recent, as today):

1. `getRoundData(R)` returns a positive answer, and `updatedAt(R) ≤ time(H) ≤ updatedAt(R) + maxStaleness` (freshness at H, as today).
2. Selection: `getRoundData(R + 1)` either reverts (no such round yet) or has `updatedAt > time(H)`.
3. Phase boundary: if the proxy's current `phaseId()` is beyond phase(R), the first round of phase(R)+1 must have `updatedAt > time(H)`. Otherwise a newer aggregator was already answering at H.
4. The proxy address is pinned per session; its code hash is no longer needed. The aggregators it routes to are whatever its owner confirmed, which is Chainlink's own trust model for the feed.
5. As today, the verified price is stored with the pending batch, and `challengeFill` uses it. Fills aren't checked on L1 at proposal.

## Trade-offs

| | Pinned proofs (today) | `getRoundData` with the selection rule |
|---|---|---|
| L1 cost per batch | ~2.18M gas + 15 KB calldata | ~30–60k gas, no witness |
| What L1 trusts | Only the pinned proxy and aggregator code (a switched aggregator is refused) | The proxy's routing to the aggregators its owner registered, as every Chainlink consumer does |
| Aggregator upgrade during a session | Refused until the session's adapter is replaced (a new session) | Followed, using the phase rule |
| Depends on live L1 state at proposal | No (everything is at H) | Yes: round history, which Chainlink keeps |
| Feed-specific code | Storage layout (slot 2, 0x2b, 0x2c) and code hashes | Only the interface and the round-id encoding |
| Access control | None (proofs read storage) | `getRoundData` must be callable by the channel. Sepolia's proxy has no access controller; check per feed |

## Recommendation

The `getRoundData` rule is sound if all three selection checks (1–3) are enforced. It would cut the dominant fixed cost of a batch by about 2M gas.

It changes what L1 trusts: from pinned code to Chainlink's proxy routing. So it should be a per-session choice, a second `IPriceAdapter`, not a replacement. Before building it:
- add tests for each selection edge: a round that is fresh but not the latest, a round in the same block as H, a phase switch just before H, and a missing next round;
- measure the cost on Sepolia.

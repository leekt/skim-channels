# How app results are enforced on L1: four apps

**Status:** design for owner review, 2026-10-22. No code yet. Follows the [correction in app channels](app-channels.md#correction-owner-review-2026-10-22): decide each app's enforcement rules first, and choose the proof or dispute mechanism after.

Apps stay **Solidity contracts**, and they read L1 state through skim witnesses but never write to it.

For each app, the questions are:
1. Is it one **shared ledger**, or can its interactions and their collateral be **separated**?
2. What do users **sign**?
3. Who detects a wrong result, and with what **evidence**?
4. What does **L1 check**: conditions on the result, or part of the execution?
5. If data is withheld or the operator disappears, **which state do withdrawals use**?

## Building blocks already in the repo

| Block | What it lets L1 do |
|---|---|
| L1 escrow (`AppChannelVault`, `ChannelSettlement`) | Hold funds; pay against roots or co-signed outcomes |
| Authenticated L1 snapshots (`AnchorRegistry` + `WitnessLib`) | Verify **on L1** what an L1 contract's storage held at a recorded block, e.g. a pool price |
| One-step re-run on L1 (`EmergencyExit` pattern) | Execute **one** approved Solidity function on proven inputs, which is what a dispute needs |
| Bounded Merkle trees (`AppLeaves`) | Prove one user's leaf in a root |
| Signatures, EIP-712 domains, nonces (`ChannelTypes`) | Check exactly what each user authorized |

The common pattern below: **the normal path posts results; L1 checks conditions on them, or re-runs one small step, only in a dispute.** None of the four apps needs a general proof of EVM execution to be enforceable.

## 1. L1 price prediction rounds

**The app:** in round *r*, users stake on an outcome (above or below a strike, or a bucket) until a cutoff. The round resolves on a price read from an L1 contract (a pool's `slot0`, an oracle's storage) **at an anchor block fixed by the round's terms**. Winners share the pot pro rata, minus a stated fee.

**Shared or separable?** Separable by round. Each round's pot is shared only among that round's stakers, and the payout is a closed formula: f(own stake, side totals, outcome).

| Question | Rule |
|---|---|
| Users sign | `Stake(round, side, amount, nonce, expiry)` against their channel balance. The operator countersigns a receipt `(round, index, user, side, amount)`: an inclusion promise |
| Operator posts per round | The stakes list (L1 calldata); a **Merkle-sum root** over the stakes (each node carries per-side sums); the claimed outcome; and the new balance root |
| Wrong result → evidence | **Wrong outcome:** anyone proves the price at the round's anchor (an L1 witness against `AnchorRegistry`) → L1 recomputes the outcome. **Missing stake:** a receipt vs. the leaf at that index. **Inconsistent sums:** one Merkle-sum node whose sum ≠ its children's. **Wrong balance:** one user's leaf ≠ old leaf − stakes + payout, proven from the round's root |
| L1 checks | Conditions on the result: the price read, the payout formula, Merkle-sum consistency, one user's balance transition. All O(1) or O(log n) Solidity; no app execution |
| Operator gone / data withheld | Withdraw from the **last finalized** balance root. An unresolved round is **cancelled**: stakes return (its termination rule). Stakes never included were never debited |

**Mechanism:** optimistic per-round results with small, app-specific fraud proofs. A validity proof would also work but isn't needed. The anchor must be recorded on L1 before the round finalizes ([anchors last ~27 h unrecorded](app-channels.md#4-da-and-l1-reads)).

## 2. One-on-one game or bet

**The app:** two players lock a wager and play a turn-based game whose rules are a Solidity contract `rules.validTransition(state, move) → state'`. The result splits the wager.

**Shared or separable?** Fully separable: one channel per match. No shared state, and the operator isn't a party.

| Question | Rule |
|---|---|
| Users sign | Each state `(match, turn, stateHash, allocation)`; the player who moves signs the next state |
| Wrong result → evidence | **A stale state posted:** the opponent posts a later state with a higher `turn`, signed by both. **An opponent stalling:** **force-move**. Post the latest state on L1; the opponent must respond with a valid next move before a timeout or forfeit by the rules |
| L1 checks | Signatures; `turn` ordering; **one** `validTransition` call on the posted state. A one-step re-run of the game's Solidity |
| Operator gone / data withheld | Not relevant: the players hold their own signed states. If the opponent vanishes, the timeout rule decides. **No L1 DA**, so this is a state channel, not a rollup |

**Funding:**
- **Direct:** both players lock the wager in the L1 vault per match. Simple, but two L1 transactions per match.
- **Virtual (Nitro-style):** each player keeps a ledger channel with the app's hub, and matches are funded off-chain from it. The hub needs collateral, and this needs the virtual-channel protocol.

**Mechanism:** a state channel with force-move. Here, "many users" is just many independent two-party channels.

## 3. OTC / order matching

**The app:** users sign orders, the operator matches them, and each fill moves assets between the two counterparties' channel balances.

**Shared or separable?** Separable per fill, since each fill involves two parties. But each order's cumulative filled amount is state that persists across fills, and **fair ordering** is a separate, unprovable concern.

| Question | Rule |
|---|---|
| Users sign | EIP-712 orders `(sell, buy, maxSell, minBuyPerSell, expiry, nonce)`. For an RFQ variant, the taker also signs the exact fill quote |
| Operator posts per batch | The fills list in calldata: `(makerOrder, takerOrder, amounts)` with both signatures or their hashes. Also the new **filled-amount root** (per order hash) and **balance root** |
| Wrong result → evidence | **An invalid fill:** a missing or invalid signature, a limit price violated, expired, or an overfill (old filled leaf + amount > max). **A wrong balance:** one user's leaf ≠ old leaf ± that user's fills in the batch. Either way, a challenger points at the fill or leaf and supplies the Merkle proofs |
| L1 checks | Conditions on one fill (signatures, price, expiry, cumulative fill) and one user's balance transition. O(1) or O(log n) per dispute |
| Operator gone / data withheld | Withdraw from the last **finalized** balance root. Unfinalized batches are discarded. Open orders expire or are cancelled by nonce |
| Not enforceable | Fair ordering and best execution. Users bound their risk with limit prices and expiry, which *are* enforced |

**Mechanism:** optimistic batches with per-fill fraud proofs. With RFQ-style double signatures, every fill is valid by construction, and only balance accounting can be disputed.

## 4. Shared pool (AMM)

**The app:** pool reserves, LP shares and user balances form **one shared ledger**. Each swap's output depends on every earlier swap.

**Shared or separable?** Not separable. This is the case that needs verifying execution, not just conditions on results.

| Question | Rule |
|---|---|
| Users sign | Swap intents `(in, minOut, deadline, nonce)`; LP add/remove intents with their own bounds |
| Operator posts per batch | All intents in order (calldata; the **inputs**, needed to replay), plus intermediate state commitments every k actions and the final root (reserves, LP shares, balances) |
| Wrong result → evidence | **Bisection over actions:** the asserter and challenger narrow the dispute to one action where they disagree. L1 then re-runs **that one action** through the pool's Solidity step `step(preState, action) → postState`, on Merkle-proven pre-state (reserves leaf, the user's balance leaves) |
| L1 checks | One action of the app's own Solidity, the `EmergencyExit` one-step pattern generalized. Not EVM-opcode bisection, because the app exposes an action-level step function |
| Operator gone / data withheld | Last **finalized** root. Termination rule: LPs get a pro-rata share of the reserves, and swappers keep their balances. Unfinalized batches are discarded. Without the inputs in DA a batch can't be challenged, so it must not finalize; inputs go in L1 calldata |

**Mechanism:**
- **Now:** optimistic, with action-level bisection. It needs bonds, response deadlines, a challenge window and at least one honest watcher; LPs are natural ones.
- **Later (future considerations):** a validity proof of the batch replaces the dispute game.

## Comparison

| | Prediction rounds | 1:1 game | OTC matching | Shared AMM |
|---|---|---|---|---|
| Shared ledger? | Per round only | No | Per order (filled amount) | **Yes** |
| L1 checks in a dispute | Conditions on the result + one balance transition | One rule step | Conditions on one fill + one balance transition | One app action (bisection) |
| General execution proof needed? | No | No | No | No (optimistic); optional (validity) |
| L1 DA | Stakes list + roots | **None** (channel) | Fills list + roots | **All inputs** + commitments |
| Watcher needed | Any participant (cheap checks) | The two players | Counterparties | Someone honest (bisection) |
| Withdraw when the operator is gone | Last finalized root; open round cancelled | Latest co-signed state, by timeout | Last finalized root | Last finalized root; LP pro-rata |

## What this means for the code

1. **The vault needs an optimistic settlement mode**, a different protocol, not just a different verifier:
   - **Pending results:** a checkpoint or round result is **pending** and becomes **finalized** only after its challenge window with no successful challenge.
   - **Bonds:** asserters and challengers post bonds, slashed on loss.
   - **Claims and freeze:** claims use **finalized** roots only, and a freeze takes the last finalized root.
   - **DA:** it carries what disputes need, i.e. stakes, fills or inputs, not just net diffs.
2. **A per-app `IAppDisputeRules` contract** in Solidity checks one disputed item: a price at an anchor, a Merkle-sum node, one fill, one balance transition, or one action step. Only the app knows its rules, and L1 calls them only in a dispute.
3. **State channels for the 1:1 game:** the force-move dispute uses the existing signature and domain code plus a timeout. Virtual-channel funding is a separate, larger piece.
4. **Nothing here needs SP1, RISC Zero or a zkEVM.** Validity proofs remain an optional future replacement for the AMM's dispute game.

## Experiments that don't need a prover

| # | For these apps |
|---|---|
| 5: termination rules | Cancelled rounds (1); timeout forfeits (2); expired or cancelled orders (3); LP pro-rata exit (4) |
| 6: anchors | Round anchors recorded before finalization, and still usable after 8,191 blocks (1) |
| 7: accounting and DA cost | Per-stake, per-fill and per-action calldata; dispute gas for each check |
| 8: upgrades during exit | All apps: a rules contract pinned per channel |

## Decisions for the owner

1. **Settlement profile per app.** Proposed above: optimistic for 1, 3 and 4; a state channel for 2.
2. **Challenge windows and bonds**, per app.
3. **Funding for 1:1 games:** direct per match, or virtual channels via a hub.
4. **Build order.** Suggested: the optimistic vault mode plus prediction rounds first. It's the simplest dispute rules that also use L1 reads.

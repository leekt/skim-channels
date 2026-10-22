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

## 1. L1 price prediction rounds (revised after review; this is the path being built)

**The app:** in round *r*, users stake UP or DOWN against a strike. The round resolves on a value read from an L1 contract's storage at a **resolution block fixed in the round's terms**. Winners share the pot pro rata (v1 has no fee). If nobody won, every stake is returned.

**Shared or separable?** Separable by round, plus a per-user balance carried across rounds.

**The review's gaps, and how the rules close them:**

| Gap | Rule |
|---|---|
| **Participation must be fixed before the outcome.** Signatures carry no trustworthy time, so a list posted with the result could be backfilled with winning bets. | The operator **commits the participation list on L1** before `commitDeadline`. Its own challenge window ends before the resolution block exists. So by the time anyone can know the outcome, the list is final |
| **Cancellation must not be a free option on the outcome.** | A committed round is **never cancelled because an operator vanished**. Resolution is permissionless: anyone proves the value at the fixed block. The only void conditions are independent of the outcome: a successful challenge to the commit (decided before resolution), or a resolution block that nobody recorded on L1 within the BLOCKHASH/EIP-2935 horizon |
| **One user's transition isn't automatically small.** | Each user has **one aggregate leaf per round**, `(user, up, down, stakesHash)`, with at most `MAX_STAKES` signed stakes. Rounds are sequential (one per settlement), so one user's balance transition reads one round leaf |
| **Nobody can prove anything against a fake root.** | **L1 computes every root itself.** The participation root is built on L1 from the published leaves at commit. Settlement proposals publish the updated balance leaves with their old Merkle paths, and **L1 computes the new root**. Only leaf *values* are optimistic, and the data to challenge any of them is on L1 |

**What users sign:** EIP-712 `Stake(channel, round, side, amount, nonce)`.

**Lifecycle on L1 (`PredictionChannel`):**
1. **Round terms:** strike, oracle (account, slot, bit range), resolution block number, commit deadline, commit challenge window. Fixed when the operator opens the round.
2. **Commit** (operator, by `commitDeadline`): the per-user aggregate leaves, plus each user's signed stakes, in calldata. L1 builds the participation tree (a sparse tree indexed by user) and the side totals.
   - *Challenge until `commitDeadline + window`, before the resolution block:* a stake with a bad signature, a leaf whose stakes don't sum to it, or a stake beyond the user's available balance. A successful challenge **voids** the round (stakes simply stay with users) and slashes the operator's bond to the challenger.
3. **Resolve** (anyone): an L1 witness of the oracle slot at the recorded resolution block. The outcome is computed on L1.
4. **Propose settlement** (operator): updated balance leaves `(user, balance, depositsApplied, withdrawalsApplied)` with their old paths. L1 checks the deposit and withdrawal counters against its own records and computes the new root.
   - *Challenge until `proposedAt + window`:* one user's new leaf ≠ f(old leaf, round leaf, counters), recomputed on L1 in O(1). Omissions are covered too: a participant whose leaf didn't change is challenged the same way. A successful challenge discards the proposal and slashes the bond.
5. **Finalize** (anyone): after the window. Withdrawals become claimable against the finalized root.

**Withdrawal and the operator-free exit:**
- **Normal withdrawal:** an L1 request to withdraw everything. The next finalized proposal must apply it, and then the payout is claimable.
- **Deadline:** if a request is still unapplied one day after it was made, the channel **freezes**.
- **Exit computed on L1, per user:**
  - the user's leaf in the **last finalized** balance root;
  - plus deposits not yet applied;
  - plus, for a committed round not yet settled, the round's effect: payout − stake if resolved, nothing if void;
  - minus anything already paid.

**L1 checks:** signatures and sums for one user (bounded by `MAX_STAKES`); a storage witness for the oracle; one user's balance arithmetic. No app execution.

**Mechanism:** optimistic for balance settlement; participation and outcome are fixed on L1. The challenges are **non-interactive**: one transaction proves the violation, so there is a challenge-submission deadline but no response deadline. Bonds penalize invalid proposals. They don't replace the need for **someone watching**: users watch their own leaves, and any third party can.

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
| **Review: cumulative state** | Checking each fill in isolation isn't enough. With an order max of 100, two fills of 60 each pass if both are checked against filled = 0. Fills must be **chained**: each carries the order's filled amount before and after, linked through intermediate commitments, or fills are aggregated per order with the aggregate challengeable. This is more than a signature check |

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

**Review: what `step()` must guarantee.** It must check more than the swap math:
- only the **allowed leaves** change (reserves, the actor's balances), and the new root is exactly the old root with those leaves updated. A step that also moves an unrelated user's balance must fail;
- one action's state access and gas are **bounded**.

So this supports **Solidity apps written against the dispute interface**, not arbitrary existing contracts dropped in unchanged.

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

## Decisions (owner, 2026-10-22)

1. **Profiles, as the experimental direction:** optimistic for 1, 3 and 4; a state channel for 2.
2. **Windows and bonds:** set from the measured worst-case dispute path and its gas. The challenge-submission deadline and the dispute-response deadline are separate; non-interactive challenges have only the first. Bonds don't replace the watcher assumption.
3. **Games:** direct L1 funding first. Virtual channels later, as separate work.
4. **Order:** complete the prediction round's close → settlement proposal → challenge → operator-free withdrawal path first, with only the optimistic layer it needs. Measure its safety and cost, **including the same app run directly on L1**, before building a general optimistic vault.

**Cost caveat:** apps 1, 3 and 4 publish inputs on L1, so their DA cost grows with the number of interactions. Whether they're cheaper than L1 is an experiment, not an assumption.

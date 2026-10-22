# App channels: accounting and recovery (experiments 1, 2, 4)

**Date:** 2026-10-22. **Design:** [app channels](../guide/app-channels.md). **Verifier:** `MockAppCheckpointVerifier`, a **labeled mock**: proofs bind the public inputs but check no execution. These experiments test L1 accounting, deadlines and recovery. Execution validity (experiment 3) waits on a real proof system.

## Experiment 1: the operator disappears

**forge** (`contracts/test/app/AppChannelVault.t.sol`):
- `test_exp1a_…`: no proof ever. Forced exit, then the one-day deadline, freeze, and every deposit refunded once.
- `test_exp1b_…`: two checkpoints, a credit claimed early, an unconsumed deposit, a forced exit, freeze. Exits after the payout delay. The ledger is **rebuilt by replaying the published diffs**, and the vault drains exactly.

**Real chain** (`ts/e2e-app.ts`, anvil Prague):

| Scenario | Result |
|---|---|
| A: operator gone before any proof | `app-recover` finds 0 checkpoints and 2 deposits; both refunded |
| B: two checkpoints; operator state **deleted** | A late checkpoint is refused by the fence; freeze; `app-recover` rebuilds both checkpoints from `CheckpointAccepted` events and calldata alone; every exit and refund claimed by a third-party keeper |
| B payouts | alice +2 ETH; bob +1 ETH + 4 ETH refund, +300 USD; carol +1 ETH, +150 USD (50 USD already claimed as a credit) |
| End state | The vault holds 0 ETH and 0 USD |

## Experiment 2: adversarial accounting

| Attack | Result | Test |
|---|---|---|
| Claim a credit twice / a stale credit leaf | Only the increase is paid; old leaves don't prove | `test_exp2_creditsPayOnlyTheIncrease` |
| Claim an exit twice; refund a consumed deposit; refund twice | Rejected | `test_exp2_exitAndRefundAreOnceOnly` |
| Inflated amount, another user's leaf, an exit leaf as a credit, too-deep proof | Rejected | `test_exp2_forgedLeavesAndWrongTreesRejected` |
| Other cursor, data, channel; replay; cursor beyond the queue or moving back | Rejected | `test_exp2_publicInputsAreBound` |
| A valid proof extending a competing history at the right nonce | Rejected | `test_exp2_forkedHistoryCannotContinue` |
| Over-allocation (possible only with the mock) | Bounded by the per-token backing cap | `test_exp2_backingCapsAnOverAllocation` |
| Random sessions (deposits, transfers, withdrawals, checkpoints, credit claims, forced exits), then close or freeze | Every unit that came in goes out; `totalIn == totalOut` per token; 512 fuzz runs | `testFuzz_exp2_randomSessionDrainsExactly` |
| Replay of published diffs vs. accepted state, any operation sequence | Identical; sum(B) + sum(E) = D per token | Rust `replay_matches_and_conserves` (proptest) |

## Experiment 4: the one-day fence

- One second before the deadline, the operator can still serve a forced request.
- **At** the deadline, even a checkpoint that serves it is refused.
- After freeze, nothing moves the snapshot: no checkpoint, no second freeze, no deposit.
- Exits wait for the payout delay.

Tests: `test_exp4_lateCheckpointCannotRaceFreeze`, `test_exp4_servedInTimeKeepsChannelLive`, plus the anvil run.

## Mutation checks

Disabling any of these makes a named test fail:
- **`AppChannelVault` (12):** deadline fence, freeze trigger, payout delay, exit once, refund once, no refund of consumed deposits, credit delta, per-token backing, cursor monotonicity, predecessor binding, exact ERC-20 receipt, no live checkpoint after the deadline.
- **Rust recovery (4):** data-hash binding, final root, channel id, consecutive nonces.

## Gas (anvil Prague, mock verifier: **no proof cost included**)

| Operation | Gas |
|---|---|
| `openChannel` | 214,351 |
| `deposit` ETH / ERC-20 (last measured) | 117,203 / 195,775 |
| `submitCheckpoint` #1 / #2, **without proof verification** | 114,428 / 102,495 (data 416 / 608 bytes) |
| `forceExit` / `freeze` | 126,434 / 40,858 |
| `claimCredit` / `claimExit` / `refundDeposit` | 93,005 / 75,239 / 94,478 |

A real verifier adds its own cost per checkpoint; SP1 documents ~270k (Groth16) to ~300k (PLONK) gas. Data: `data/app-channels-anvil.json`.

## Not covered yet

- Experiment 3 (real proofs) and 5–8 (positions, old anchors and reorgs, cost at scale, upgrades).
- Apps beyond the reference ledger.
- L1 reads (snapshot anchors) inside app execution: the vault binds `anchorId` but the mock doesn't prove reads.

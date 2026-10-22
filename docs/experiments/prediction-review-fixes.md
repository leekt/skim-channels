# Prediction rounds: review fixes (A1–A4)

**Date:** 2026-10-22. **Reviewed commit:** `f4aab6287b9d0814a8832ec09209a6ea59388493` (it was also `main`'s HEAD when this work started). **Contracts:** `contracts/src/predict/`. **Tests:** `contracts/test/predict/ReviewRepro.t.sol` (19), `PredictionChannel.t.sol` (32), the tree tests (2), and `ts/e2e-predict.ts`.

Each finding was first turned into a test that asserts the safe behaviour, then run against `f4aab62`. All seven failed there. The reproduction file and its output are kept as [`data/review-repro-f4aab62.sol.txt`](data/review-repro-f4aab62.sol.txt) and [`data/review-repro-f4aab62.out.txt`](data/review-repro-f4aab62.out.txt).

| Finding | Test on f4aab62 | Result |
|---|---|---|
| A1: `window_ = 0` accepted | `test_A1_zeroWindowRejected` | `next call did not revert` |
| A1: open and commit in block N with (N, N+1, N+2); watcher in N+1 | `test_A1_forgedCommitChallengeableNextBlock` | `WrongState()`: the challenge period was already over |
| A2: deposit 10, request, proposal `Leaf(0,0,0,1)` | `test_A2_requestConsumedWithoutPayment` | `NotWrong()`: the challenge said the leaf was right |
| A2: the same, finalized, then a day later | `test_A2_consumedRequestBlocksFreeze` | `NotOverdue()`: paid 0, freeze refused |
| A3: another user's leaf finalized while freeze evidence was in flight | `test_A3_freezeEvidenceInvalidatedByOtherLeaf` | `BadProof()` |
| A3: new round opened with an overdue request | `test_A3_newRoundWithOverdueRequest` | allowed |
| A4: anchor recorded, never resolved, operator gone: a non-participant exits | `test_A4_nonParticipantExitBlockedByUnresolvedRound` | `WrongState()`: nobody could exit |

## A1: challenge periods

**Fix:** a per-channel policy, fixed at deployment (`PredictionStorage.Config`), with floors that tests can't lower. Tests move blocks and time instead.

| Policy | Floor | Why |
|---|---|---|
| `challengeWindow` (settlement proposals) | 1 hour | The lower clamp the owner chose for per-channel exit windows |
| `commitChallengeBlocks` | 64 blocks (two epochs) | The commit is final before challenges close |
| `forceDelay` | 1 day | The owner's forced-request decision (2026-10-22) |
| `maxRoundBlocks × 12 s + 2 × challengeWindow ≤ forceDelay` | | A request made as a round opens can still be served by a proposal that is challenged once and proposed again |

- `openRound` requires `commitDeadline + commitChallengeBlocks ≤ commitChallengeEnd`.
- `commit` additionally requires `block.number + commitChallengeBlocks ≤ commitChallengeEnd`. So the data is public for the whole period whenever the operator commits.
- The old global 6-hour cap on the window is gone. A longer window is allowed when `forceDelay` is longer (`test_A1_policyFloorsEnforced`).

**Tests:** `test_A1_policyFloorsEnforced`; `test_A1_forgedCommitChallengeableAfterPublication`, where the review's schedule is refused, and a commit in the last allowed block is still voided by a watcher 63 blocks later.

## A2: a request can't be consumed without paying what it covers

**Fix:**
- `requestWithdraw` records the user's cumulative deposits at that moment (`Request.deposits`).
- `PredictionTypes.next` refuses to apply a request unless every deposit up to that amount is applied, so all of it is paid out (`cumWithdrawn`).
- Deposits made after the request aren't covered by it. They stay for a later request or exit.
- `challengeUpdate` takes `k` (the leaf's `requestsApplied`). The rules check `k` against the evidence, so a challenger can't misstate it to convict an honest proposal.

**Tests:**
- `test_A2_requestConsumedWithoutPaymentIsAFault`, `test_A2_correctWithdrawalPaysEverythingRequested`;
- `test_A2_depositAfterRequestIsNotCoveredButEarlierOnesAre`, `test_A2_requestsDuringARound` (a participant's and a non-participant's requests; a deposit after the commit but before the request);
- `test_A2_repeatedRequests`, `test_A2_challengerCannotMisstateK`, `test_A2_cursorCoversRequestButLeafUntouched`, `test_A2_cursorBounds`, `test_A2_unservedRequestStillFreezes`;
- the anvil e2e: a proposal consuming A's request without paying is challenged on chain.

## A3: forced deadlines

**Fix:** one channel-wide request queue, served in order.

| Moment | Rule |
|---|---|
| A request is made | Its deadline is fixed: `time + forceDelay`. Nothing restarts it |
| A proposal is made | It carries a `cursor`: every request before it must be applied in its user's leaf. Leaving one unapplied (an untouched leaf included) loses `challengeUpdate` |
| The proposal finalizes | `finalizedCursor = cursor` |
| The oldest request at `finalizedCursor` passes its deadline | Anyone calls `freeze()`. It needs **no leaf evidence**, so no other user's update can invalidate it. It is O(1), with no loop over users |
| An overdue request exists | `openRound` is refused (`Overdue`) |

- **Both orders in one block** (`test_A3_finalizeFreezeOrderInOneBlock`). If finalize runs first and serves the request, freeze is refused and the user claims. If freeze runs first, finalize is refused and the user exits. Either way the user is paid.
- **Re-proposal after a challenge** doesn't move the deadline (`test_A3_reproposalDoesNotRestartDeadline`).
- **A round already running** doesn't extend it either (`test_A3_roundDoesNotExtendDeadline`): the channel freezes mid-round, and exits handle the round.
- **Payment timing:** a served request is claimable as soon as its root finalizes. After a freeze, `exit` pays instead; `claim` stops (`test_A3_noClaimsAfterFreeze`).

**Relation to the earlier decisions:**
- The **1-day forced delay** is this channel's `forceDelay` floor.
- The **per-channel exit window** clamp [1 h, 30 d] (EmergencyExit, `ChannelPolicy`) belongs to computation channels. Here the analogous per-channel value is `challengeWindow`. Its upper bound comes from `forceDelay`, not a global cap.
- **30-day governance** doesn't apply: `PredictionChannel` has no upgrade path (both halves are immutable).

## A4: losing the resolution witness

**Fix:**
- **A round is never cancelled because a witness went missing.** `voidRound` still voids only if the resolution block was never recorded on L1. A recorded root alone doesn't count as the witness being available.
- **`exit` now works while the latest round is committed but unresolved.**
  - Non-participants are paid in full.
  - Participants are paid everything except their stake, which every outcome leaves them.
  - Once anyone resolves (or the round is voided), `exit` pays the rest. `paid` makes it cumulative, never double.

**Who keeps what, and when:**

| Who | Keeps | When |
|---|---|---|
| Every watcher, and each participant's wallet | The witness package and raw header of the resolution block (`ts/runtime/evidence.ts`, `EvidenceStore`) | As soon as the block meets their confirmation policy, while skim (or the RPC) still serves its proof. skim serves recent roots only, and a non-archive RPC about 128 blocks |
| Anyone (the first watcher) | Records the anchor (`AnchorRegistry.record`) | Within 256 blocks (BLOCKHASH) or 8,191 (EIP-2935) |
| Anyone | Calls `resolve` | As soon as possible: the value is then on L1 for good |
| Holders | Release pinned evidence (`EvidenceStore.release`) | Only after L1 shows the outcome |

**If nobody kept it:**
- An archive node can still produce the proof, because the state root is on L1.
- Until someone does, only the participants' stakes stay locked. Everything else is paid.

**Tests:**
- `test_A4_exitsWithoutResolutionThenWithRetainedWitness`: past the horizon the round isn't voidable, and the retained witness resolves it.
- `test_operator_gone_before_resolution_resolve_then_exit`.
- **The anvil e2e:** anvil runs with `--prune-history 32`, and round 2's operator disappears after the commit. The watcher pins the witness at the resolution block. 200 blocks later the RPC refuses that proof (checked). The channel is frozen, participants get all but their stakes, and the watcher's pinned copy resolves the round. The winner gets the rest, and the channel ends holding only the bond.

## Structure change

`PredictionChannel` is split in two halves that share one storage layout (`PredictionStorage`), to stay under Amsterdam code pricing:
- the core channel (8.5 KB): deposits, requests, `openRound`, `propose`, `finalize`, `claim`;
- `PredictionDisputes` (8.5 KB): `commit`, `resolve`, `voidRound`, challenges, `freeze`, `exit`. The channel's fallback reaches it by delegatecall. Called directly, it refuses.

## Verification

- **forge:** all prediction suites pass (19 + 32 + 2, plus the cost suite).
- **Mutation:** 46 mutants of the five contracts, all caught. Tests were added for nine first-round survivors: a challenger's `k`, the cursor rule, the policy floors, the cursor bounds, claims after freeze, and direct calls to the disputes half.
- **A test-harness pitfall found on the way:** in this forge, `expectRevert` followed by a contract creation ends the test right there, so later checks in the same test silently don't run. The policy test uses try/catch instead.
- **anvil e2e:** `npm run e2e-predict`, passing.

## Remaining assumptions

- **Watchers:** someone checks each proposal within `challengeWindow` and each commit within `commitChallengeBlocks`. An unchallenged bad root finalizes. It can consume a request without paying it, though payouts stay capped by the channel's funds.
- **Witness retention:** someone keeps the resolution witness, or an archive node is reachable. Otherwise participants' stakes stay locked until one is.
- **Block time:** `maxRoundBlocks × 12 s` assumes 12-second slots.
- **Cost:** see [prediction round cost](prediction-round-cost.md) (re-measured after these fixes). `requestWithdraw` now writes a queue entry: 120k gas.

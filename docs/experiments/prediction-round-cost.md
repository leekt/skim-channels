# Prediction rounds: safety and cost vs. running on L1

**Date:** 2026-10-22. **Rules:** [app enforcement §1](../guide/app-enforcement.md#1-l1-price-prediction-rounds-revised-after-review-this-is-the-path-being-built). **Contracts:** `contracts/src/predict/` (`PredictionChannel` 9.5 KB, `PredictionRules`, `PredictionTypes`, `SparseTree16`; baseline `PredictionL1`).

This is the first app path settled **optimistically** and with **no mock anywhere**:
- participation and the outcome are fixed on L1;
- balances are proposed, then challenged or finalized;
- users exit from L1 alone.

The question this experiment answers: **is it cheaper than the same game run directly on L1, and what do disputes cost?**

## What was built

| Step | Who | What L1 does |
|---|---|---|
| `openRound` | operator | Fixes strike, oracle (account, slot, bits) and `commitDeadline < commitChallengeEnd < resolutionBlock` (≤ 1,800 blocks out) |
| `commit` | operator | Takes each participant's **latest signed ticket** (cumulative `up`, `down`, `nonce`), packed at 109 bytes per user. **L1 builds the participation root and totals** |
| `challengeCommit` | anyone, before `commitChallengeEnd` | One ticket: a bad signature, or a stake above finalized balance + deposits at commit. The round is voided and the bond goes to the challenger |
| `resolve` | anyone | Uses the oracle slot from an L1 storage witness at the **recorded** resolution block |
| `voidRound` | anyone | Only if never committed, or the resolution block was never recorded within 8,191 blocks. Neither depends on the outcome |
| `propose` | operator | Changed leaves (108 bytes each) plus a **multiproof** of the rest. **L1 computes the old root (must be the finalized one) and the new root** |
| `challengeUpdate` | anyone, within `window` (≤ 6 h) | One user's new leaf ≠ `PredictionTypes.next(old leaf, round leaf, counters)`, or it claims more deposits or requests than L1 recorded. Untouched leaves are challengeable too. Non-interactive; the bond goes to the challenger |
| `finalize`, `claim` | anyone, user | Withdrawals pay against finalized leaves only |
| `requestWithdraw` → `freeze` → `exit` | user, anyone, user | A request not applied by a finalized root within **1 day** freezes the channel. Each user's exit is computed on L1 from the last finalized leaf, unapplied deposits and the unsettled round |

Two choices made for cost during this work:
1. **One ticket per user per round.** With every stake, the user signs their running totals, so only the last ticket reaches L1. Commit cost scales with **users**, not stakes. It replaced per-stake signatures with `MAX_STAKES`.
2. **Counters are checked in the challenge, not the proposal.** That saves two cold reads per user on the normal path. A leaf that overclaims deposits or requests loses `challengeUpdate`.

## Safety: what the tests pin

`contracts/test/predict/PredictionChannel.t.sol`: 32 tests plus 2 tree tests, including fuzzing.

| Property | Tests |
|---|---|
| A round settles, A withdraws 12 ETH; an honest proposal survives a challenge on every leaf | `test_round_settles_and_withdraws` |
| Bad signature or overdraft at commit → void + slash; a valid ticket, a late challenge, or a forged ticket or balance leaf is rejected | `test_commit_challenge_*` |
| An overpaid winner, an omitted participant, unapplied deposits, overclaimed counters, counters moving backwards → challenged | `test_overpaying_*`, `test_omitting_*`, `test_wrong_counters_*`, `test_overclaimed_*`, `test_counters_cannot_go_backwards` |
| False evidence (a fake old or new leaf, or a fake round leaf) can't convict an honest proposal | `test_false_evidence_*`, `test_challenge_window_and_proofs` |
| Unsorted or unregistered updates, a tampered or short multiproof, a non-finalized old leaf → rejected | `test_propose_rules`, `test_propose_rejects_*` |
| The operator vanishes after resolution, or before it (anyone resolves): everyone exits with the right amount and the channel holds only the bond | `test_operator_gone_*`, `test_exit_after_settled_rounds_*` |
| Void is outcome-independent: a recorded resolution block can never be voided | `test_void_rules_*`, `test_recorded_resolution_block_is_never_voided` |
| An overdraft no one challenged in time: the user forfeits what they had and wins nothing | `test_unchallenged_overdraft_forfeits` |
| If a bad root is never challenged, payouts are still capped by the channel's funds | `test_unchallenged_bad_root_cannot_pay_beyond_deposits` |
| Random stakes and outcomes: exits conserve funds (512 runs); the multiproof transition matches an independent tree (fuzz) | `testFuzz_*` |

**Mutation check:** 36 mutants of the four contracts. All are caught except one equivalent mutant: clearing `pendingAt` on freeze, which `finalize` and `propose` already guard.

**Real chain:** `ts/e2e-predict.ts` (anvil Prague).
- Tickets are signed with viem, and the operator's tree is built in TypeScript.
- The oracle is read through a real `eth_getProof` witness from `skim-channels witness` at the resolution block.
- A 1-wei-wrong proposal loses the challenge, and the honest one finalizes.
- A claims 12 ETH. The operator then stops; B and C exit with 7 and 11 ETH, and the channel holds only the bond.

## Cost

Method (`contracts/test/predict/PredictionCost.t.sol`): every step is priced as an L1 transaction.
- 21,000 base gas, plus calldata (EIP-2028, or the EIP-7623 floor when higher).
- Plus execution, with the contracts and sender **cooled** first, so storage is priced as in a fresh transaction.
- Minus the refund, capped at 1/5.
- Users alternate sides and stake 0.1 ETH k times. The same round also runs on `PredictionL1`: deposit once, one transaction per stake, resolve, then one `collect` per user.
- The forge model agrees with anvil receipts: `finalize` 39,531 vs 39,467; `requestWithdraw` 70,542 vs 70,478.

Data: [`data/prediction-round-cost.json`](data/prediction-round-cost.json) (model) and [`data/prediction-e2e.json`](data/prediction-e2e.json) (receipts).

### One round, per user

| Users × stakes each | Channel (gas/user) | Direct on L1 (gas/user) | L1 ÷ channel |
|---|---|---|---|
| 10 × 1 | 129,196 | 180,241 | 1.4× |
| 10 × 8 | 129,193 | 462,040 | 3.6× |
| 100 × 1 | 25,368 | 101,409 | **4.0×** |
| 100 × 8 | 25,365 | 383,208 | **15.1×** |
| 1,000 × 1 | 17,289 | 93,525 | **5.4×** |

Both columns include recording the resolution anchor (131k) and the witness resolve (713k with this fixture's proof; 261k on anvil's small trie). **Both sides pay these once per round**, so they dominate at 10 users.

Channel per user: commit ≈ 7.4–7.9k + propose ≈ 8.6–9.0k at 100 users and up. On L1: ≈ 42–58k per stake, plus 35k per collect.

### Per user, over a lifetime (anvil receipts)

| | Channel | Direct on L1 |
|---|---|---|
| First deposit | 118,933 | 43,618 |
| Withdraw everything | `requestWithdraw` 70.5k + its leaf in a proposal (≈ 9k batched, 120k alone) + `claim` 86.4k | `withdraw` 28.6k |

The channel costs about **200k more per user** to get in and out. At 100 users × 1 stake, it saves ≈ 76k per round, so it **breaks even after about 3 rounds**. At 8 stakes per round, it breaks even within the first round. At 10 users × 1 stake it takes ≈ 4 rounds.

### Disputes and the operator-free exit (worst case, independent of user count)

| Transaction | Gas | Note |
|---|---|---|
| `challengeCommit` | 116,653 | One ticket: signature, two 16-level proofs, balance arithmetic |
| `challengeUpdate` | 142,601 | Three 16-level proofs and `next()`; O(1) in users |
| `freeze` | 78,972 | |
| `exit` (resolved, unsettled round) | 143,849 | Per user |
| `propose` / `commit`, 1,000 users | 9.06M / 7.39M | Fits EIP-7825's 16.7M cap; about 1,800 users per transaction |

**Windows and bonds, from these numbers:**
- **Challenges are single transactions under 150k gas**, so the challenge window only needs to cover inclusion under congestion. It is capped at 6 hours (`MAX_WINDOW`); a round lasts at most 1,800 blocks (~6 hours). A withdrawal request is therefore always appliable within the 1-day fence, even after a bad proposal is challenged and re-proposed.
- **The bond must exceed a challenger's gas at a stressed gas price.** 150k gas at 1,000 gwei is 0.15 ETH, so `minBond` should be well above that; the tests use 1 ETH.
- **A bond doesn't replace watching.** An unchallenged bad root finalizes. The damage is capped by the channel's own funds (`Insolvent`), not prevented.

## What this says, and what it doesn't

- **Cheaper than L1, by measurement:**
  - For rounds with tens of users or more, or several stakes each, the per-round saving is 4–15×.
  - The channel's fixed entry and exit costs are recovered after a few rounds.
  - At small sizes the oracle witness dominates both sides.
  - This holds with calldata DA: every ticket and leaf is on L1.
- **Not measured:**
  - Blob DA, which would cut commit and propose further. Disputes need the data within the window, and blobs live for about 18 days.
  - A real mainnet witness. Its size depends on trie depth; it's paid once per round on either side.
  - The variant where both sides read the oracle's **current** value instead of a witness at a fixed block. That's cheaper, but the resolution time becomes a choice of whoever calls.
- **Assumptions:**
  - Someone watches each proposal within the window.
  - The operator posts a bond.
  - Up to 65,536 users per channel (a depth-16 tree), and about 1,800 per commit or proposal transaction.
- **Possible optimizations, not done:**
  - Deposits cost 119k for the first one: user registration, the deposit counter, the snapshot check.
  - The leaf encoding can shrink further.

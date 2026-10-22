// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {SparseTree16} from "./SparseTree16.sol";
import {PredictionTypes as T} from "./PredictionTypes.sol";
import {PredictionStorage} from "./PredictionStorage.sol";
import {PredictionDisputes} from "./PredictionDisputes.sol";

/// @notice Prediction rounds on an L1 value, settled optimistically
///         (docs/guide/app-enforcement.md §1). ETH only in v1. One round at a time.
///
/// 1. `openRound`: strike, oracle (account, slot, bit range) and block numbers
///    commitDeadline < commitChallengeEnd < resolutionBlock, with at least
///    `commitChallengeBlocks` between the deadline and the challenge end.
/// 2. `commit` (operator, by commitDeadline, and at least `commitChallengeBlocks` before
///    commitChallengeEnd): each participant's latest signed ticket, in calldata. L1 builds
///    the participation root and totals. `challengeCommit` (bad signature, overdraft) until
///    commitChallengeEnd, before the resolution block exists.
/// 3. `resolve` (anyone): an L1 witness of the oracle slot at the recorded resolution block.
///    `voidRound` only if never committed, or the resolution block was never recorded on L1
///    within the history horizon. Neither depends on the outcome.
/// 4. `propose` (operator): changed leaves with a multiproof, and a request-queue cursor;
///    L1 recomputes the roots. `challengeUpdate` within `challengeWindow`.
/// 5. `finalize` (anyone). `claim` pays withdrawals from finalized leaves.
/// Withdraw-all requests join one queue with a deadline fixed at request time
/// (`forceDelay`). If the oldest unserved request passes it, anyone can `freeze`, and each
/// user `exit`s with what L1 computes.
///
/// `challengeCommit`, `challengeUpdate`, `freeze` and `exit` live in PredictionDisputes and
/// run here by delegatecall (the fallback below).
contract PredictionChannel is PredictionStorage {
    PredictionDisputes public immutable disputes;

    constructor(PredictionDisputes disputes_) PredictionStorage(disputes_.config()) {
        disputes = disputes_;
        finalizedRoot = SparseTree16.emptyRoot();
    }

    /// Everything else is a dispute or exit function.
    fallback() external {
        address d = address(disputes);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), d, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // ---- money in ---------------------------------------------------------------------------

    function postBond() external payable {
        bond += msg.value;
    }

    function deposit() external payable {
        if (frozen || msg.value == 0) revert WrongState();
        uint32 idx = indexPlusOne[msg.sender];
        if (idx == 0) {
            if (users.length >= 1 << SparseTree16.DEPTH) revert WrongState();
            users.push(msg.sender);
            idx = uint32(users.length);
            indexPlusOne[msg.sender] = idx;
        }
        idx -= 1;
        uint256 r = roundCount;
        Status s = rounds[r].status;
        if ((s == Status.Committed || s == Status.Resolved) && snapRound[idx] != r) {
            snapRound[idx] = r;
            snapValue[idx] = cumDeposit[idx];
        }
        cumDeposit[idx] += msg.value;
        userFunds += msg.value;
        emit Deposited(idx, msg.sender, msg.value);
    }

    /// @notice Withdraw everything deposited so far (plus winnings). Joins the channel-wide
    ///         queue with a deadline fixed now: a finalized root must apply it within
    ///         forceDelay, or anyone can freeze the channel. Deposits made after this request
    ///         aren't covered by it.
    function requestWithdraw() external {
        uint32 idx = indexPlusOne[msg.sender];
        if (idx == 0) revert WrongState();
        idx -= 1;
        uint256 pos = queue.length;
        queue.push(Request(idx, uint64(block.timestamp), cumDeposit[idx]));
        userRequests[idx].push(pos);
        emit WithdrawRequested(idx, pos, cumDeposit[idx]);
    }

    // ---- rounds -----------------------------------------------------------------------------

    function openRound(
        uint256 strike,
        address oracle,
        bytes32 slot,
        uint8 shift,
        uint16 bits,
        uint64 commitDeadline,
        uint64 commitChallengeEnd,
        uint64 resolutionBlock
    ) external returns (uint256 r) {
        _onlyOperator();
        Status s = rounds[roundCount].status;
        if (frozen || pendingAt != 0 || (s != Status.None && s != Status.Settled)) revert WrongState();
        if (overdue()) revert Overdue(); // serve overdue requests before starting new work
        if (
            block.number > commitDeadline || commitDeadline + commitChallengeBlocks > commitChallengeEnd
                || commitChallengeEnd >= resolutionBlock || resolutionBlock > block.number + maxRoundBlocks || bits == 0
                || uint256(shift) + bits > 256
        ) revert BadSchedule();
        r = ++roundCount;
        rounds[r] = Round(
            Status.Open,
            0,
            shift,
            bits,
            commitDeadline,
            commitChallengeEnd,
            resolutionBlock,
            oracle,
            slot,
            strike,
            0,
            0,
            0
        );
        emit RoundOpened(r);
    }

    // ---- settlement -------------------------------------------------------------------------

    /// @notice Updated balance leaves (packed, PredictionTypes.UPDATE_BYTES each) and a
    ///         multiproof of the unchanged subtrees; L1 recomputes both roots. `r` must be the
    ///         latest round when it is Resolved or Void, else 0 (deposits and withdrawals only).
    ///         Counters are not checked here: a leaf claiming more deposits or requests than
    ///         L1 recorded loses `challengeUpdate`.
    /// @param cursor every queued request before this position must be applied in its user's
    ///        leaf (checked by challengeUpdate)
    function propose(uint256 r, bytes calldata updates, bytes32[] calldata proof, uint256 cursor) external {
        _onlyOperator();
        if (cursor < finalizedCursor || cursor > queue.length) revert BadUpdate();
        if (frozen || pendingAt != 0 || bond < minBond) revert WrongState();
        uint256 last = roundCount;
        Status s = rounds[last].status;
        bool roundDue = s == Status.Resolved || s == Status.Void;
        if (roundDue ? r != last : (r != 0 || s == Status.Open || s == Status.Committed)) revert WrongState();
        bytes32 root = finalizedRoot;
        if (updates.length != 0) {
            (bytes32 oldRoot, bytes32 newRoot, uint256 lastIdx) = rules.transition(updates, proof);
            if (oldRoot != root) revert BadProof();
            if (lastIdx >= users.length) revert BadUpdate();
            root = newRoot;
        }
        pendingRoot = root;
        pendingRound = r;
        pendingCursor = cursor;
        pendingAt = block.timestamp;
        emit Proposed(r, root, cursor);
    }

    function finalize() external {
        if (frozen || pendingAt == 0 || block.timestamp < pendingAt + challengeWindow) revert WrongState();
        finalizedRoot = pendingRoot;
        finalizedCursor = pendingCursor;
        if (pendingRound != 0) rounds[pendingRound].status = Status.Settled;
        pendingAt = 0;
        emit Finalized(finalizedRoot, finalizedCursor);
    }

    // ---- withdrawals and the operator-free exit ---------------------------------------------

    function claim(uint32 idx, T.Leaf calldata leaf, bytes32[16] calldata siblings) external {
        if (frozen || idx >= users.length) revert WrongState(); // after a freeze, exit pays it
        _prove(leaf, idx, siblings, finalizedRoot);
        uint256 owed = leaf.cumWithdrawn - paid[idx];
        if (owed == 0) revert WrongState();
        paid[idx] = leaf.cumWithdrawn;
        _pay(idx, owed);
    }
}

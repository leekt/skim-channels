// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {PredictionStorage} from "./PredictionStorage.sol";
import {PredictionTypes as T} from "./PredictionTypes.sol";

/// @notice The round (commit, resolve, void), challenge and operator-free exit half of
///         PredictionChannel. Runs only by delegatecall from the channel (same storage layout,
///         PredictionStorage); called directly, every function reverts.
contract PredictionDisputes is PredictionStorage {
    address private immutable self;

    constructor(Config memory c) PredictionStorage(c) {
        self = address(this);
    }

    modifier viaChannel() {
        if (address(this) == self) revert WrongState();
        _;
    }

    /// @notice The participation list: each participant's latest signed ticket, packed
    ///         (PredictionTypes.TICKET_BYTES each). Fixed before the outcome exists.
    function commit(uint256 r, bytes calldata entries) external viaChannel {
        _onlyOperator();
        Round storage rd = rounds[r];
        if (frozen || rd.status != Status.Open || block.number > rd.commitDeadline || bond < minBond) {
            revert WrongState();
        }
        // The data is public from this block: challenges must get commitChallengeBlocks.
        if (block.number + commitChallengeBlocks > rd.commitChallengeEnd) revert BadSchedule();
        (bytes32 root, uint256 up, uint256 down, uint256 maxIdx) = rules.participation(entries);
        if (up + down != 0 && maxIdx >= users.length) revert BadUpdate();
        rd.participationRoot = root;
        rd.totalUp = up;
        rd.totalDown = down;
        rd.status = Status.Committed;
        emit Committed(r, root, up, down);
    }

    /// @notice Anyone: the oracle value at the round's recorded resolution block.
    function resolve(uint256 r, bytes calldata witness) external viaChannel {
        Round storage rd = rounds[r];
        if (rd.status != Status.Committed) revert WrongState();
        uint256 v = rules.oracleValue(
            witness, anchors, witnessVerifier, rd.resolutionBlock, rd.oracle, rd.slot, rd.shift, rd.bits
        );
        uint8 side = v >= rd.strike ? T.UP : T.DOWN;
        if ((side == T.UP ? rd.totalUp : rd.totalDown) == 0) side = 0; // no winning stake: refunds
        rd.outcome = side;
        rd.status = Status.Resolved;
        emit Resolved(r, side, v);
    }

    /// @notice Outcome-independent void: never committed by the deadline, or no anchor for the
    ///         resolution block was recorded and it no longer can be (EIP-2935 horizon passed).
    function voidRound(uint256 r) external viaChannel {
        Round storage rd = rounds[r];
        bool expired = rd.status == Status.Open && block.number > rd.commitDeadline;
        bool unresolvable = rd.status == Status.Committed && block.number > rd.resolutionBlock + HISTORY_HORIZON
            && anchors.anchorIdAt(rd.resolutionBlock) == 0;
        if (!expired && !unresolvable) revert WrongState();
        rd.status = Status.Void;
        emit RoundVoided(r);
    }

    /// @notice Before commitChallengeEnd: user `idx`'s committed ticket (abi.encode(Ticket))
    ///         carries a bad signature, or stakes more than the user had at the commit
    ///         (finalized balance plus unapplied deposits). Voids the round; the bond goes to
    ///         the caller.
    function challengeCommit(
        uint256 r,
        uint32 idx,
        bytes calldata ticket,
        bytes32[16] calldata partSiblings,
        T.Leaf calldata balanceLeaf,
        bytes32[16] calldata balanceSiblings
    ) external viaChannel {
        Round storage rd = rounds[r];
        if (rd.status != Status.Committed || block.number >= rd.commitChallengeEnd) revert WrongState();
        bool fault = rules.commitFault(
            domainSeparator(),
            r,
            users[idx],
            idx,
            ticket,
            partSiblings,
            rd.participationRoot,
            balanceLeaf,
            balanceSiblings,
            finalizedRoot,
            depositsAtCommit(idx, r)
        );
        if (!fault) revert NotWrong();
        rd.status = Status.Void;
        emit RoundVoided(r);
        _slash();
    }

    /// @notice User `idx`'s leaf in the pending root is wrong (PredictionRules.updateFault),
    ///         an untouched leaf included. Discards the proposal; the bond goes to the caller.
    /// @param k the new leaf's requestsApplied (rules check it against the evidence)
    /// @param evidence abi.encode(oldLeaf, oldSiblings, newLeaf, newSiblings, roundLeaf,
    ///        roundSiblings)
    function challengeUpdate(uint32 idx, uint256 k, bytes calldata evidence) external viaChannel {
        if (pendingAt == 0 || block.timestamp >= pendingAt + challengeWindow || idx >= users.length) {
            revert WrongState();
        }
        (T.Effect memory e, bytes32 partRoot) = _effect(pendingRound, idx, false);
        uint256[] storage reqs = userRequests[idx];
        T.UserRecord memory rec = T.UserRecord({
            deposits: cumDeposit[idx],
            requests: reqs.length,
            claimedRequests: k,
            requestDeposits: k == 0 || k > reqs.length ? 0 : queue[reqs[k - 1]].deposits,
            nextRequestPos: k < reqs.length ? reqs[k] : type(uint256).max,
            cursor: pendingCursor
        });
        if (!rules.updateFault(idx, evidence, finalizedRoot, pendingRoot, partRoot, e, rec)) revert NotWrong();
        pendingAt = 0;
        pendingRoot = 0;
        _slash();
    }

    /// @notice Anyone: the oldest request not applied in the finalized root is past its
    ///         deadline (request time + forceDelay, fixed when it was made). Stops settlement.
    ///         Needs no leaf evidence, so no other leaf's update can invalidate it.
    function freeze() external viaChannel {
        if (frozen) revert WrongState();
        if (!overdue()) revert NotOverdue();
        frozen = true;
        pendingAt = 0;
        emit Frozen(finalizedRoot, finalizedCursor);
    }

    /// @notice After a freeze: the finalized leaf with every deposit applied and the latest
    ///         round's effect, as PredictionTypes.next computes it, minus what was already
    ///         paid. While that round is committed but unresolved, only the user's stake is
    ///         held back. Callable again once it resolves (or is voided) for the rest.
    function exit(
        uint32 idx,
        T.Leaf calldata leaf,
        bytes32[16] calldata siblings,
        T.PartLeaf calldata p,
        bytes32[16] calldata partSiblings
    ) external viaChannel {
        if (!frozen || idx >= users.length) revert WrongState();
        _prove(leaf, idx, siblings, finalizedRoot);
        (T.Effect memory e, bytes32 partRoot) = _effect(roundCount, idx, true);
        (T.Leaf memory n, bool ok) =
            rules.next(idx, leaf, p, partSiblings, partRoot, e, cumDeposit[idx], leaf.requestsApplied);
        if (!ok) revert BadUpdate();
        uint256 total = n.balance + n.cumWithdrawn;
        uint256 owed = total > paid[idx] ? total - paid[idx] : 0;
        if (owed == 0) revert WrongState();
        paid[idx] = total;
        _pay(idx, owed);
    }
}

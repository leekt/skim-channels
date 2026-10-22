// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {SparseTree16} from "./SparseTree16.sol";
import {PredictionTypes as T} from "./PredictionTypes.sol";
import {PredictionRules} from "./PredictionRules.sol";
import {AnchorRegistry} from "../AnchorRegistry.sol";
import {WitnessVerifier} from "../verifiers/WitnessVerifier.sol";

/// @notice Prediction rounds on an L1 value, settled optimistically
///         (docs/guide/app-enforcement.md §1). ETH only in v1. One round at a time.
///
/// 1. `openRound`: strike, oracle (account, slot, bit range) and block numbers
///    commitDeadline < commitChallengeEnd < resolutionBlock.
/// 2. `commit` (operator, by commitDeadline): each participant's latest signed ticket (their
///    running totals), in calldata. L1 builds the participation root and totals itself.
///    `challengeCommit` (bad signature, overdraft) only before commitChallengeEnd, so before
///    the resolution block exists. Success voids the round and pays the bond to the challenger.
/// 3. `resolve` (anyone): an L1 witness of the oracle slot at the recorded resolution block.
///    `voidRound` only if the operator never committed, or no anchor for the resolution block
///    was recorded before the EIP-2935 horizon passed. Neither depends on the outcome.
/// 4. `propose` (operator): updated balance leaves with a multiproof; L1 recomputes the root.
///    `challengeUpdate` (anyone, within `window`): one user's new leaf isn't what
///    `PredictionTypes.next` computes. Non-interactive; success discards the proposal and
///    pays the bond to the challenger.
/// 5. `finalize` (anyone, after the window). `claim` pays withdrawals from finalized leaves.
/// Exit: a `requestWithdraw` not applied by a finalized root within FORCE_DELAY lets anyone
/// `freeze`; then each user `exit`s with an amount L1 computes from the last finalized leaf,
/// unapplied deposits and the unsettled round.
contract PredictionChannel {
    uint256 public constant FORCE_DELAY = 1 days;
    uint256 public constant MAX_WINDOW = 6 hours;
    uint256 public constant MAX_ROUND_BLOCKS = 1800; // ~6 hours: a round + window fit in FORCE_DELAY
    uint256 public constant HISTORY_HORIZON = 8191;

    enum Status {
        None,
        Open,
        Committed,
        Resolved,
        Void,
        Settled
    }

    struct Round {
        Status status;
        uint8 outcome;
        uint8 shift;
        uint16 bits;
        uint64 commitDeadline;
        uint64 commitChallengeEnd;
        uint64 resolutionBlock;
        address oracle;
        bytes32 slot;
        uint256 strike;
        bytes32 participationRoot;
        uint256 totalUp;
        uint256 totalDown;
    }

    address public immutable operator;
    AnchorRegistry public immutable anchors;
    WitnessVerifier public immutable witnessVerifier;
    PredictionRules public immutable rules;
    uint256 public immutable minBond;
    uint256 public immutable window;
    bytes32 public immutable domainSeparator;

    address[] public users;
    mapping(address => uint32) public indexPlusOne;
    mapping(uint32 => uint256) public cumDeposit;
    mapping(uint32 => uint256) internal snapRound; // deposits after a commit: value at commit
    mapping(uint32 => uint256) internal snapValue;
    mapping(uint32 => uint64[]) internal requestTimes;
    mapping(uint32 => uint256) public paid;
    mapping(uint32 => bool) public exited;

    uint256 public bond;
    uint256 public userFunds;
    bytes32 public finalizedRoot;
    uint256 public roundCount;
    mapping(uint256 => Round) public rounds;
    bytes32 public pendingRoot;
    uint256 public pendingRound;
    uint256 public pendingAt;
    bool public frozen;

    event Deposited(uint32 indexed idx, address user, uint256 amount);
    event WithdrawRequested(uint32 indexed idx, uint256 count);
    event RoundOpened(uint256 indexed round);
    event Committed(uint256 indexed round, bytes32 root, uint256 up, uint256 down);
    event Resolved(uint256 indexed round, uint8 outcome, uint256 value);
    event RoundVoided(uint256 indexed round);
    event Proposed(uint256 indexed round, bytes32 root);
    event Finalized(bytes32 root);
    event Challenged(address challenger, uint256 bond);
    event Frozen(bytes32 root);
    event Paid(uint32 indexed idx, uint256 amount);

    error NotOperator();
    error WrongState();
    error BadSchedule();
    error BadProof();
    error BadUpdate();
    error NotWrong();
    error NotOverdue();
    error Insolvent();
    error TransferFailed();

    constructor(
        address operator_,
        AnchorRegistry anchors_,
        WitnessVerifier wv_,
        PredictionRules rules_,
        uint256 minBond_,
        uint256 window_
    ) {
        if (window_ > MAX_WINDOW) revert BadSchedule();
        operator = operator_;
        anchors = anchors_;
        witnessVerifier = wv_;
        rules = rules_;
        minBond = minBond_;
        window = window_;
        finalizedRoot = SparseTree16.emptyRoot();
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SkimPrediction"),
                keccak256("0"),
                block.chainid,
                address(this)
            )
        );
    }

    // ---- views ------------------------------------------------------------------------------

    /// @notice User `idx`'s cumulative deposits when round `r` committed (valid while r is unsettled).
    function depositsAtCommit(uint32 idx, uint256 r) public view returns (uint256) {
        return snapRound[idx] == r ? snapValue[idx] : cumDeposit[idx];
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

    /// @notice Withdraw everything. Must be applied by a finalized root within FORCE_DELAY.
    function requestWithdraw() external {
        uint32 idx = indexPlusOne[msg.sender];
        if (idx == 0) revert WrongState();
        requestTimes[idx - 1].push(uint64(block.timestamp));
        emit WithdrawRequested(idx - 1, requestTimes[idx - 1].length);
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
        if (
            block.number > commitDeadline || commitDeadline >= commitChallengeEnd
                || commitChallengeEnd >= resolutionBlock || resolutionBlock > block.number + MAX_ROUND_BLOCKS
                || bits == 0 || uint256(shift) + bits > 256
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

    /// @notice The participation list: each participant's latest signed ticket, packed
    ///         (PredictionTypes.TICKET_BYTES each). Fixed before the outcome exists.
    function commit(uint256 r, bytes calldata entries) external {
        _onlyOperator();
        Round storage rd = rounds[r];
        if (frozen || rd.status != Status.Open || block.number > rd.commitDeadline || bond < minBond) {
            revert WrongState();
        }
        (bytes32 root, uint256 up, uint256 down, uint256 maxIdx) = rules.participation(entries);
        if (up + down != 0 && maxIdx >= users.length) revert BadUpdate();
        rd.participationRoot = root;
        rd.totalUp = up;
        rd.totalDown = down;
        rd.status = Status.Committed;
        emit Committed(r, root, up, down);
    }

    /// @notice Before commitChallengeEnd: user `idx`'s committed ticket (abi.encode(Ticket))
    ///         carries a bad signature, or exceed what the user had at the commit (finalized
    ///         balance plus unapplied deposits). Voids the round; the bond goes to the caller.
    function challengeCommit(
        uint256 r,
        uint32 idx,
        bytes calldata ticket,
        bytes32[16] calldata partSiblings,
        T.Leaf calldata balanceLeaf,
        bytes32[16] calldata balanceSiblings
    ) external {
        Round storage rd = rounds[r];
        if (rd.status != Status.Committed || block.number >= rd.commitChallengeEnd) revert WrongState();
        bool fault = rules.commitFault(
            domainSeparator,
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

    /// @notice Anyone: the oracle value at the round's recorded resolution block.
    function resolve(uint256 r, bytes calldata witness) external {
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
    function voidRound(uint256 r) external {
        Round storage rd = rounds[r];
        bool expired = rd.status == Status.Open && block.number > rd.commitDeadline;
        bool unresolvable = rd.status == Status.Committed && block.number > rd.resolutionBlock + HISTORY_HORIZON
            && anchors.anchorIdAt(rd.resolutionBlock) == 0;
        if (!expired && !unresolvable) revert WrongState();
        rd.status = Status.Void;
        emit RoundVoided(r);
    }

    // ---- settlement -------------------------------------------------------------------------

    /// @notice Updated balance leaves (packed, PredictionTypes.UPDATE_BYTES each) and a
    ///         multiproof of the unchanged subtrees; L1 recomputes both roots. `r` must be the
    ///         latest round when it is Resolved or Void, else 0 (deposits and withdrawals only).
    ///         Counters are not checked here: a leaf claiming more deposits or requests than
    ///         L1 recorded loses `challengeUpdate`.
    function propose(uint256 r, bytes calldata updates, bytes32[] calldata proof) external {
        _onlyOperator();
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
        pendingAt = block.timestamp;
        emit Proposed(r, root);
    }

    /// @notice User `idx`'s leaf in the pending root isn't what `PredictionTypes.next` computes
    ///         from the finalized leaf, the user's round leaf and the counters it carries
    ///         (an untouched leaf counts too). Discards the proposal; the bond goes to the caller.
    /// @param evidence abi.encode(oldLeaf, oldSiblings, newLeaf, newSiblings, roundLeaf,
    ///        roundSiblings), as PredictionRules.updateFault reads it
    function challengeUpdate(uint32 idx, bytes calldata evidence) external {
        if (pendingAt == 0 || block.timestamp >= pendingAt + window || idx >= users.length) revert WrongState();
        (T.Effect memory e, bytes32 partRoot) = _effect(pendingRound, idx);
        bool fault = rules.updateFault(
            idx, evidence, finalizedRoot, pendingRoot, partRoot, e, cumDeposit[idx], requestTimes[idx].length
        );
        if (!fault) revert NotWrong();
        pendingAt = 0;
        pendingRoot = 0;
        _slash();
    }

    function finalize() external {
        if (frozen || pendingAt == 0 || block.timestamp < pendingAt + window) revert WrongState();
        finalizedRoot = pendingRoot;
        if (pendingRound != 0) rounds[pendingRound].status = Status.Settled;
        pendingAt = 0;
        emit Finalized(finalizedRoot);
    }

    // ---- withdrawals and the operator-free exit ---------------------------------------------

    function claim(uint32 idx, T.Leaf calldata leaf, bytes32[16] calldata siblings) external {
        if (idx >= users.length || exited[idx]) revert WrongState();
        _prove(leaf, idx, siblings, finalizedRoot);
        uint256 owed = leaf.cumWithdrawn - paid[idx];
        if (owed == 0) revert WrongState();
        paid[idx] = leaf.cumWithdrawn;
        _pay(idx, owed);
    }

    /// @notice Anyone: user `idx`'s next withdrawal request is older than FORCE_DELAY and the
    ///         finalized leaf hasn't applied it. Stops settlement at the finalized root.
    function freeze(uint32 idx, T.Leaf calldata leaf, bytes32[16] calldata siblings) external {
        if (frozen) revert WrongState();
        _prove(leaf, idx, siblings, finalizedRoot);
        uint256 applied = leaf.requestsApplied;
        if (applied >= requestTimes[idx].length || block.timestamp < requestTimes[idx][applied] + FORCE_DELAY) {
            revert NotOverdue();
        }
        frozen = true;
        pendingAt = 0;
        emit Frozen(finalizedRoot);
    }

    /// @notice After a freeze, once per user: the finalized leaf with every deposit applied and
    ///         the unsettled round's effect, as `PredictionTypes.next` computes it.
    function exit(
        uint32 idx,
        T.Leaf calldata leaf,
        bytes32[16] calldata siblings,
        T.PartLeaf calldata p,
        bytes32[16] calldata partSiblings
    ) external {
        if (!frozen || exited[idx] || idx >= users.length) revert WrongState();
        _prove(leaf, idx, siblings, finalizedRoot);
        uint256 r = roundCount;
        if (rounds[r].status == Status.Committed) revert WrongState(); // resolve or void it first
        (T.Effect memory e, bytes32 partRoot) = _effect(r, idx);
        (T.Leaf memory n, bool ok) =
            rules.next(idx, leaf, p, partSiblings, partRoot, e, cumDeposit[idx], leaf.requestsApplied);
        if (!ok) revert BadUpdate();
        uint256 owed = n.balance + n.cumWithdrawn - paid[idx];
        exited[idx] = true;
        if (owed > 0) _pay(idx, owed);
    }

    // ---- internals --------------------------------------------------------------------------

    /// The round effect for user `idx`: active only for a Resolved round.
    function _effect(uint256 r, uint32 idx) internal view returns (T.Effect memory e, bytes32 partRoot) {
        Round storage rd = rounds[r];
        if (r != 0 && rd.status == Status.Resolved) {
            e = T.Effect(true, rd.outcome, rd.totalUp, rd.totalDown, depositsAtCommit(idx, r));
            partRoot = rd.participationRoot;
        }
    }

    function _prove(T.Leaf calldata leaf, uint32 idx, bytes32[16] calldata siblings, bytes32 root) internal pure {
        if (SparseTree16.rootFrom(T.leafHash(leaf), idx, siblings) != root) revert BadProof();
    }

    function _slash() internal {
        uint256 b = bond;
        bond = 0;
        emit Challenged(msg.sender, b);
        (bool ok,) = msg.sender.call{value: b}("");
        if (!ok) revert TransferFailed();
    }

    function _pay(uint32 idx, uint256 amount) internal {
        if (amount > userFunds) revert Insolvent();
        userFunds -= amount;
        emit Paid(idx, amount);
        (bool ok,) = users[idx].call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _onlyOperator() internal view {
        if (msg.sender != operator) revert NotOperator();
    }
}

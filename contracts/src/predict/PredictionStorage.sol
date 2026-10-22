// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {SparseTree16} from "./SparseTree16.sol";
import {PredictionTypes as T} from "./PredictionTypes.sol";
import {PredictionRules} from "./PredictionRules.sol";
import {AnchorRegistry} from "../AnchorRegistry.sol";
import {WitnessVerifier} from "../verifiers/WitnessVerifier.sol";

/// @notice State, configuration and helpers shared by PredictionChannel and
///         PredictionDisputes. The channel delegatecalls the disputes contract, so both must
///         have exactly this layout. They are split only to stay deployable under Amsterdam
///         code pricing.
abstract contract PredictionStorage {
    // ---- policy floors (not test settings: tests move time and blocks instead) ----
    /// Settlement proposals stay challengeable for at least this long after publication.
    uint256 public constant MIN_CHALLENGE_WINDOW = 1 hours;
    /// Commit challenges stay open for at least two epochs after the commit transaction, so
    /// the participation data is final before challenges close.
    uint256 public constant MIN_COMMIT_CHALLENGE_BLOCKS = 64;
    /// The owner-decided forced-request delay (2026-10-22): one day, never less.
    uint256 public constant MIN_FORCE_DELAY = 1 days;
    /// Only used to check that a round plus two challenge windows fit in forceDelay.
    uint256 public constant ASSUMED_SLOT_SECONDS = 12;
    uint256 public constant HISTORY_HORIZON = 8191;

    /// Per-channel policy, fixed at deployment.
    struct Config {
        address operator;
        AnchorRegistry anchors;
        WitnessVerifier witnessVerifier;
        PredictionRules rules;
        uint256 minBond;
        uint256 challengeWindow; // seconds; settlement proposals
        uint256 forceDelay; // seconds; a withdraw-all request must be finalized within this
        uint256 commitChallengeBlocks; // blocks after the commit transaction
        uint256 maxRoundBlocks; // resolutionBlock − block of openRound
    }

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

    /// A withdraw-all request, in one channel-wide queue served in order.
    struct Request {
        uint32 idx;
        uint64 time;
        uint256 deposits; // the user's cumulative deposits when they asked: all must be paid
    }

    address public immutable operator;
    AnchorRegistry public immutable anchors;
    WitnessVerifier public immutable witnessVerifier;
    PredictionRules public immutable rules;
    uint256 public immutable minBond;
    uint256 public immutable challengeWindow;
    uint256 public immutable forceDelay;
    uint256 public immutable commitChallengeBlocks;
    uint256 public immutable maxRoundBlocks;

    address[] public users;
    mapping(address => uint32) public indexPlusOne;
    mapping(uint32 => uint256) public cumDeposit;
    mapping(uint32 => uint256) internal snapRound; // deposits after a commit: value at commit
    mapping(uint32 => uint256) internal snapValue;
    Request[] public queue;
    mapping(uint32 => uint256[]) internal userRequests; // queue positions, in order
    mapping(uint32 => uint256) public paid;

    uint256 public bond;
    uint256 public userFunds;
    bytes32 public finalizedRoot;
    uint256 public finalizedCursor; // requests before it are applied in finalizedRoot
    uint256 public roundCount;
    mapping(uint256 => Round) public rounds;
    bytes32 public pendingRoot;
    uint256 public pendingRound;
    uint256 public pendingCursor;
    uint256 public pendingAt;
    bool public frozen;

    event Deposited(uint32 indexed idx, address user, uint256 amount);
    event WithdrawRequested(uint32 indexed idx, uint256 position, uint256 deposits);
    event RoundOpened(uint256 indexed round);
    event Committed(uint256 indexed round, bytes32 root, uint256 up, uint256 down);
    event Resolved(uint256 indexed round, uint8 outcome, uint256 value);
    event RoundVoided(uint256 indexed round);
    event Proposed(uint256 indexed round, bytes32 root, uint256 cursor);
    event Finalized(bytes32 root, uint256 cursor);
    event Challenged(address challenger, uint256 bond);
    event Frozen(bytes32 root, uint256 overdueRequest);
    event Paid(uint32 indexed idx, uint256 amount);

    error NotOperator();
    error WrongState();
    error BadSchedule();
    error BadPolicy();
    error BadProof();
    error BadUpdate();
    error NotWrong();
    error NotOverdue();
    error Overdue();
    error Insolvent();
    error TransferFailed();

    constructor(Config memory c) {
        if (
            c.challengeWindow < MIN_CHALLENGE_WINDOW || c.forceDelay < MIN_FORCE_DELAY
                || c.commitChallengeBlocks < MIN_COMMIT_CHALLENGE_BLOCKS || c.commitChallengeBlocks >= c.maxRoundBlocks
                // A request made as a round opens can still be served: the round, then a
                // proposal that may be challenged once and proposed again.
                || c.maxRoundBlocks * ASSUMED_SLOT_SECONDS + 2 * c.challengeWindow > c.forceDelay
        ) {
            revert BadPolicy();
        }
        operator = c.operator;
        anchors = c.anchors;
        witnessVerifier = c.witnessVerifier;
        rules = c.rules;
        minBond = c.minBond;
        challengeWindow = c.challengeWindow;
        forceDelay = c.forceDelay;
        commitChallengeBlocks = c.commitChallengeBlocks;
        maxRoundBlocks = c.maxRoundBlocks;
    }

    function config() external view returns (Config memory) {
        return Config(
            operator,
            anchors,
            witnessVerifier,
            rules,
            minBond,
            challengeWindow,
            forceDelay,
            commitChallengeBlocks,
            maxRoundBlocks
        );
    }

    /// The EIP-712 domain binds tickets to the channel (address(this) is the channel in both
    /// contracts, since disputes run by delegatecall).
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SkimPrediction"),
                keccak256("0"),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice User `idx`'s cumulative deposits when round `r` committed (valid while r is unsettled).
    function depositsAtCommit(uint32 idx, uint256 r) public view returns (uint256) {
        return snapRound[idx] == r ? snapValue[idx] : cumDeposit[idx];
    }

    function queueLength() external view returns (uint256) {
        return queue.length;
    }

    function requestCount(uint32 idx) external view returns (uint256) {
        return userRequests[idx].length;
    }

    /// @notice Whether the oldest request not applied in the finalized root is past its deadline.
    function overdue() public view returns (bool) {
        uint256 c = finalizedCursor;
        return c < queue.length && block.timestamp >= queue[c].time + forceDelay;
    }

    /// The round effect for user `idx`: active for a Resolved round, and for a Committed one
    /// when `allowUnresolved` (exits hold back only the stake).
    function _effect(uint256 r, uint32 idx, bool allowUnresolved)
        internal
        view
        returns (T.Effect memory e, bytes32 partRoot)
    {
        Round storage rd = rounds[r];
        bool unresolved = rd.status == Status.Committed;
        if (r != 0 && (rd.status == Status.Resolved || (allowUnresolved && unresolved))) {
            e = T.Effect(true, unresolved, rd.outcome, rd.totalUp, rd.totalDown, depositsAtCommit(idx, r));
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

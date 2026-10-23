// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingLedger as L} from "./ClearingLedger.sol";
import {ClearingCodec} from "./ClearingCodec.sol";
import {SparseTree16} from "../predict/SparseTree16.sol";
import {AnchorRegistry} from "../AnchorRegistry.sol";
import {WitnessVerifier} from "../verifiers/WitnessVerifier.sol";

interface IERC20Lite {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice State shared by ClearingChannel and ClearingDisputes (the channel delegatecalls
///         the disputes half; both must have exactly this layout). The first seven slots are
///         read by the app on its executor through L1 witnesses: don't reorder them.
abstract contract ClearingStorage {
    uint256 public constant MIN_CHALLENGE_WINDOW = 1 hours;
    uint256 public constant MIN_FORCE_DELAY = 1 days;
    /// Upper bounds: keep `at + window` and deadlines far from overflow, anchors in reach.
    uint256 public constant MAX_CHALLENGE_WINDOW = 30 days;
    uint256 public constant MAX_FORCE_DELAY = 60 days;
    uint256 public constant MAX_TAKEOVER_DELAY = 60 days;
    uint256 public constant MAX_ANCHOR_AGE = 8191;
    uint256 public constant MAX_FILLS = 256;
    uint256 public constant MAX_REQUESTS_PER_BATCH = 16; // per account

    struct Config {
        address operator;
        IERC20Lite usd;
        AnchorRegistry anchors;
        WitnessVerifier witnessVerifier;
        ClearingCodec codec;
        address priceFeed;
        bytes32 priceSlot;
        uint256 bandBps;
        uint256 challengeWindow; // proposals stay challengeable this long
        uint256 forceDelay; // a request or forced order must be served by a finalized batch within this
        uint256 maxAnchorAge; // blocks
        uint256 minBond; // per proposal
        uint256 takeoverDelay; // after this long without a proposal, anyone may propose
        uint256 appChainId; // the app network's chain id: the EIP-712 domain orders are signed in
    }

    struct Totals {
        uint128 eth;
        uint128 usd;
    }

    struct Request {
        uint32 idx;
        uint8 token;
        uint64 time;
        uint128 amount;
        uint128 inAt; // the user's cumulative deposits of `token` when they asked
    }

    struct Forced {
        bytes32 hash; // ClearingRules.orderHash
        uint64 time;
    }

    struct Pending {
        bytes32 root;
        bytes32 fillsHash;
        uint256 price;
        uint64 anchorBlock;
        uint64 at;
        uint64 reqCursor;
        uint64 forcedCursor;
        address proposer;
        uint256 bond;
    }

    // ---- slots 0–6: read by the app through witnesses ----
    address[] internal _users; // 0
    mapping(uint32 => Totals) internal _cumIn; // 1
    Request[] internal _requests; // 2
    Forced[] internal _forced; // 3
    bytes32 internal _finalizedRoot; // 4
    uint256 internal _finalizedReq; // 5
    uint256 internal _finalizedForced; // 6

    mapping(address => uint32) internal _indexPlusOne;
    mapping(uint32 => uint256[]) internal _userRequests; // queue positions
    mapping(uint32 => Totals) internal _paid;
    Totals internal _userFunds;
    uint256 internal _batches; // finalized
    uint256 internal _lastProposalAt;
    Pending internal _pending;
    bool internal _frozen;
    /// Forced orders were authorized by their trader's own L1 transaction (no typed signature).
    mapping(bytes32 => bool) internal _forcedAuth;
    /// Bonds owed back (refunds and challenge rewards), paid on request: a proposer that
    /// can't receive ETH never blocks finalize or freeze.
    mapping(address => uint256) internal _bondCredit;

    address internal immutable operator;
    IERC20Lite internal immutable usd;
    AnchorRegistry internal immutable anchors;
    WitnessVerifier internal immutable witnessVerifier;
    ClearingCodec internal immutable codec;
    address internal immutable priceFeed;
    bytes32 internal immutable priceSlot;
    uint256 internal immutable bandBps;
    uint256 internal immutable challengeWindow;
    uint256 internal immutable forceDelay;
    uint256 internal immutable maxAnchorAge;
    uint256 internal immutable minBond;
    uint256 internal immutable takeoverDelay;
    uint256 internal immutable appChainId;

    event Deposited(uint32 indexed idx, address user, uint8 token, uint256 amount);
    event WithdrawRequested(uint256 indexed pos, uint32 indexed idx, uint8 token, uint256 amount);
    event ForcedOrder(uint256 indexed pos, uint32 indexed idx, bytes order);
    event Proposed(
        uint256 indexed batch,
        bytes32 root,
        address proposer,
        uint256 price,
        uint64 anchorBlock,
        uint64 reqCursor,
        uint64 forcedCursor
    );
    event ForcedRested(uint256 indexed pos);
    event Finalized(uint256 indexed batch, bytes32 root);
    event Discarded(uint256 indexed batch, address challenger, string reason);
    event Frozen(uint256 overdueRequest, uint256 overdueForced);
    event Paid(uint32 indexed idx, uint8 token, uint256 amount);
    event BondCredited(address indexed to, uint256 amount);

    error WrongState();
    error BadPolicy();
    error BadAnchor();
    error BadProof();
    error BadBatch(string what);
    error NotWrong();
    error NotOverdue();
    error Insolvent();
    error TransferFailed();

    constructor(Config memory c) {
        if (
            c.challengeWindow < MIN_CHALLENGE_WINDOW || c.challengeWindow > MAX_CHALLENGE_WINDOW
                || c.forceDelay < MIN_FORCE_DELAY || c.forceDelay > MAX_FORCE_DELAY
                || 2 * c.challengeWindow > c.forceDelay || c.takeoverDelay > MAX_TAKEOVER_DELAY
                || c.maxAnchorAge > MAX_ANCHOR_AGE || c.bandBps > 10_000
        ) {
            revert BadPolicy();
        }
        operator = c.operator;
        usd = c.usd;
        anchors = c.anchors;
        witnessVerifier = c.witnessVerifier;
        codec = c.codec;
        priceFeed = c.priceFeed;
        priceSlot = c.priceSlot;
        bandBps = c.bandBps;
        challengeWindow = c.challengeWindow;
        forceDelay = c.forceDelay;
        maxAnchorAge = c.maxAnchorAge;
        minBond = c.minBond;
        takeoverDelay = c.takeoverDelay;
        appChainId = c.appChainId;
    }

    function _creditBond(address to, uint256 amount) internal {
        if (amount == 0) return;
        _bondCredit[to] += amount;
        emit BondCredited(to, amount);
    }

    /// The oldest unserved request or forced order is past its deadline (fixed when made).
    function _overdue() internal view returns (bool) {
        uint256 r = _finalizedReq;
        if (r < _requests.length && block.timestamp >= _requests[r].time + forceDelay) return true;
        uint256 f = _finalizedForced;
        return f < _forced.length && block.timestamp >= _forced[f].time + forceDelay;
    }

    function _prove(L.Account memory a, uint32 idx, bytes32[16] calldata sib, bytes32 root) internal pure {
        if (SparseTree16.rootFrom(L.leafHash(a), idx, sib) != root) revert BadProof();
    }

    function _pay(uint32 idx, uint128 eth, uint128 dollars) internal {
        Totals storage f = _userFunds;
        if (eth > f.eth || dollars > f.usd) revert Insolvent();
        f.eth -= eth;
        f.usd -= dollars;
        address to = _users[idx];
        if (eth > 0) {
            emit Paid(idx, 0, eth);
            (bool ok,) = to.call{value: eth}("");
            if (!ok) revert TransferFailed();
        }
        if (dollars > 0) {
            emit Paid(idx, 1, dollars);
            if (!usd.transfer(to, dollars)) revert TransferFailed();
        }
    }
}

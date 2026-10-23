// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingLedger as L} from "./ClearingLedger.sol";
import {ClearingCodec} from "./ClearingCodec.sol";
import {ClearingRules as R} from "./ClearingRules.sol";
import {SparseTree16} from "../predict/SparseTree16.sol";
import {AnchorRegistry} from "../AnchorRegistry.sol";
import {IPriceAdapter} from "./ChainlinkAdapter.sol";

interface IERC20Lite {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// The vault side of a redemption into the vault (ClearingVault.credit).
interface IClearingVault {
    function credit(address user, uint128 usdAmount) external payable;
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
        ClearingCodec codec;
        IPriceAdapter priceAdapter; // segment prices, from witnesses at the blocks they were read
        uint256 bandBps;
        uint256 challengeWindow; // proposals stay challengeable this long
        uint256 forceDelay; // a request or forced order must be served by a finalized batch within this
        uint256 maxAnchorAge; // blocks
        uint256 minBond; // per proposal
        uint256 takeoverDelay; // after this long without a proposal, anyone may propose
        uint256 appChainId; // the app network's chain id: the EIP-712 domain orders are signed in
        address vault; // the app's ClearingVault (may fund deposits; receives redemptions)
        uint64 sessionId; // this session's id in the vault (≥ 1), the EIP-712 domain's salt
    }

    /// Active → Closing → Closed. Closing fixes the admission cutoff: no new deposits,
    /// withdrawal requests or forced orders; the operator may still settle what was executed.
    /// Closed is terminal: the finalized root never changes again, and every user redeems
    /// from it without an executor, watcher or oracle (see `redeem`).
    enum Phase {
        Active,
        Closing,
        Closed
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

    /// One execution segment of a proposal: fills from `firstFill` on ran at L1 block `head`
    /// (recorded in the AnchorRegistry), priced by witness number `price`.
    struct SegmentRef {
        uint32 firstFill;
        uint32 price;
        uint64 head;
    }

    struct Pending {
        bytes32 root;
        bytes32 fillsHash;
        /// keccak256(abi.encode(firstFills, prices, heads)): the batch's execution segments,
        /// each head recorded and each price verified (and fresh at its head) at proposal.
        bytes32 segments;
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
    Phase internal _phase;
    uint64 internal _closingAt;
    /// Bonds owed back (refunds and challenge rewards), paid on request: a proposer that
    /// can't receive ETH never blocks finalize, freeze or close.
    mapping(address => uint256) internal _bondCredit;
    /// Forced orders were authorized by their trader's own L1 transaction (no typed signature).
    mapping(bytes32 => bool) internal _forcedAuth;

    /// The session's configuration, set once by `_initialize` (sessions are minimal proxies of
    /// one shared implementation, so it can't be immutable).
    Config internal _cfg;
    bool internal _initialized;

    event Deposited(uint32 indexed idx, address user, uint8 token, uint256 amount);
    event WithdrawRequested(uint256 indexed pos, uint32 indexed idx, uint8 token, uint256 amount);
    event ForcedOrder(uint256 indexed pos, uint32 indexed idx, bytes order);
    event Proposed(
        uint256 indexed batch, bytes32 root, address proposer, bytes32 segments, uint64 reqCursor, uint64 forcedCursor
    );
    /// A proposal's execution segments: each fill's head and price (challengeFill takes them).
    event Segments(uint256 indexed batch, uint32[] firstFills, uint256[] prices, uint64[] heads);
    event ForcedRested(uint256 indexed pos);
    event Finalized(uint256 indexed batch, bytes32 root);
    event Discarded(uint256 indexed batch, address challenger, string reason);
    event Frozen(uint256 overdueRequest, uint256 overdueForced);
    event Paid(uint32 indexed idx, uint8 token, uint256 amount);
    event ClosingStarted(uint256 requestCutoff, uint256 forcedCutoff, address by);
    event Closed(bytes32 finalRoot, uint256 batches);
    event FinalPublished(bytes32 finalRoot, uint256 start, uint256 count);
    event Redeemed(uint32 indexed idx, uint128 eth, uint128 usd, bool toVault);
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

    /// Once per session, by the vault that creates it (in the same transaction).
    function _initialize(Config memory c) internal {
        if (_initialized) revert WrongState();
        if (
            c.challengeWindow < MIN_CHALLENGE_WINDOW || c.challengeWindow > MAX_CHALLENGE_WINDOW
                || c.forceDelay < MIN_FORCE_DELAY || c.forceDelay > MAX_FORCE_DELAY
                || 2 * c.challengeWindow > c.forceDelay || c.takeoverDelay > MAX_TAKEOVER_DELAY
                || c.maxAnchorAge > MAX_ANCHOR_AGE || c.bandBps > 10_000 || c.sessionId == 0
        ) {
            revert BadPolicy();
        }
        _initialized = true;
        _cfg = c;
    }

    function _domain() internal view returns (bytes32) {
        return R.domainSeparator(_cfg.appChainId, address(this), bytes32(uint256(_cfg.sessionId)));
    }

    function _creditBond(address to, uint256 amount) internal {
        if (amount == 0) return;
        _bondCredit[to] += amount;
        emit BondCredited(to, amount);
    }

    /// The oldest unserved request or forced order is past its deadline (fixed when made).
    function _overdue() internal view returns (bool) {
        uint256 r = _finalizedReq;
        if (r < _requests.length && block.timestamp >= _requests[r].time + _cfg.forceDelay) return true;
        uint256 f = _finalizedForced;
        return f < _forced.length && block.timestamp >= _forced[f].time + _cfg.forceDelay;
    }

    function _prove(L.Account memory a, uint32 idx, bytes32[16] calldata sib, bytes32 root) internal pure {
        if (SparseTree16.rootFrom(L.leafHash(a), idx, sib) != root) revert BadProof();
    }

    /// Pays out of users' funds to the user's wallet, or (`toVault`) into the app's vault as
    /// the user's free balance. Callers record the payout in `_paid` first.
    function _pay(uint32 idx, uint128 eth, uint128 dollars, bool toVault) internal {
        Totals storage f = _userFunds;
        if (eth > f.eth || dollars > f.usd) revert Insolvent();
        f.eth -= eth;
        f.usd -= dollars;
        address to = _users[idx];
        if (toVault) {
            if (dollars > 0 && !_cfg.usd.transfer(_cfg.vault, dollars)) revert TransferFailed();
            IClearingVault(_cfg.vault).credit{value: eth}(to, dollars);
            return;
        }
        if (eth > 0) {
            emit Paid(idx, 0, eth);
            (bool ok,) = to.call{value: eth}("");
            if (!ok) revert TransferFailed();
        }
        if (dollars > 0) {
            emit Paid(idx, 1, dollars);
            if (!_cfg.usd.transfer(to, dollars)) revert TransferFailed();
        }
    }
}

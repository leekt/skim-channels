// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingStorage} from "./ClearingStorage.sol";
import {ClearingDisputes} from "./ClearingDisputes.sol";
import {ClearingLedger as L} from "./ClearingLedger.sol";
import {ClearingRules as R} from "./ClearingRules.sol";
import {SparseTree16} from "../predict/SparseTree16.sol";

/// @notice L1 side of the clearing channel: optimistic, with the app's account state
///         committed on L1.
///
/// - Every batch commits a new **account root** (each trader's balances, deposit and
///   withdrawal counters, nonce floor), publishing only the changed leaves (packed) with a
///   multiproof; L1 computes the new root itself. Fills are published packed (236 B each:
///   both orders and signatures) and only hashed here. The price is proven per oracle
///   segment: the app reads the feed at whatever L1 head its executor has applied, and a batch
///   starts a new segment when the feed's round changed, so each segment's price is checked at
///   its own anchor.
/// - Nothing about a fill is re-checked unless challenged (ClearingDisputes):
///   `challengeFill` (one fill's signatures, price band, limits, expiry) and
///   `challengeAccount` (one account replayed through the batch with ClearingLedger: deposits,
///   withdrawal requests, every fill side, collateral and nonces in order). Either discards
///   the batch and pays the proposer's bond to the challenger.
/// - **Handover:** the operator proposes; after `takeoverDelay` without a proposal, anyone
///   can (with a bond). All state needed to continue is on L1: the finalized root, the
///   published leaves and fills, and the request and forced-order queues.
/// - **Forced orders:** a user posts a signed order on L1. A finalized batch must fill it
///   or publish it as resting (ForcedRested) within `forceDelay`; otherwise anyone can
///   freeze, as for an unserved withdrawal request: the session closes at once.
/// - **Session lifecycle** (one session of an app; its ClearingVault outlives it):
///   Active → `beginClose` → Closing → `close` → Closed. Closing fixes the admission cutoff
///   (no deposits, withdrawal requests or forced orders after it). In Closed nothing can
///   propose, take over or reopen it, and each user redeems from the final root: the leaf's
///   balance, plus deposits it never applied, plus released withdrawals, minus what was paid.
///   That covers queued withdrawal requests and unapplied deposits; forced orders not filled
///   by then are void (nothing was traded, so nothing is owed for them).
contract ClearingChannel is ClearingStorage {
    ClearingDisputes public immutable disputes;

    constructor(ClearingDisputes disputes_) ClearingStorage(disputes_.config()) {
        disputes = disputes_;
        _finalizedRoot = SparseTree16.emptyRoot();
        _lastProposalAt = block.timestamp;
    }

    /// challengeFill, challengeAccount, freeze, exit, claim and the views: ClearingDisputes,
    /// by delegatecall.
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

    /// Orders are signed for the app network (`appChainId`, the chain wallets are connected to
    /// when they sign) and this channel. MetaMask-style wallets refuse typed data for any chain
    /// other than the active one.
    function domain() public view returns (bytes32) {
        return _domain();
    }

    // ---- users ------------------------------------------------------------------------------

    function deposit(uint8 token, uint128 amount) external payable {
        _deposit(msg.sender, msg.sender, token, amount);
    }

    /// @notice The vault moves a user's free balance into this session, on that user's own
    ///         request (ClearingVault.fund).
    function depositFor(address user, uint8 token, uint128 amount) external payable {
        if (msg.sender != vault || vault == address(0)) revert WrongState();
        _deposit(user, msg.sender, token, amount);
    }

    function _deposit(address user, address from, uint8 token, uint128 amount) internal {
        if (_phase != Phase.Active || amount == 0) revert WrongState();
        uint32 idx = _indexPlusOne[user];
        if (idx == 0) {
            if (_users.length >= 1 << 16) revert WrongState();
            _users.push(user);
            idx = uint32(_users.length);
            _indexPlusOne[user] = idx;
        }
        idx -= 1;
        Totals storage t = _cumIn[idx];
        if (token == R.ETH) {
            if (msg.value != amount) revert WrongState();
            t.eth += amount;
            _userFunds.eth += amount;
        } else if (token == R.USD) {
            if (msg.value != 0 || !usd.transferFrom(from, address(this), amount)) revert WrongState();
            t.usd += amount;
            _userFunds.usd += amount;
        } else {
            revert WrongState();
        }
        emit Deposited(idx, user, token, amount);
    }

    /// @notice Withdraw up to `amount` of `token`. Served at the start of a batch (before its
    ///         fills): whatever is free then, up to `amount`, becomes claimable. Covers every
    ///         deposit made before it. Deadline: forceDelay, fixed now.
    function requestWithdraw(uint8 token, uint128 amount) external {
        uint32 idx = _indexPlusOne[msg.sender];
        if (_phase != Phase.Active || idx == 0 || token > R.USD || amount == 0) revert WrongState();
        idx -= 1;
        uint256 pos = _requests.length;
        _requests.push(
            Request(idx, token, uint64(block.timestamp), amount, token == R.ETH ? _cumIn[idx].eth : _cumIn[idx].usd)
        );
        _userRequests[idx].push(pos);
        emit WithdrawRequested(pos, idx, token, amount);
    }

    /// @notice The trader posts an order on L1 with an ordinary transaction (msg.sender is the
    ///         authorization: no typed signature, so it works from a wallet connected to L1).
    ///         A finalized batch must fill it or publish it as resting within forceDelay.
    function forceOrder(R.Order calldata o) external {
        uint32 idx = _indexPlusOne[o.trader];
        if (_phase != Phase.Active || idx == 0 || msg.sender != o.trader) revert WrongState();
        bytes32 h = R.orderHash(o);
        uint256 pos = _forced.length;
        _forced.push(Forced(h, uint64(block.timestamp)));
        _forcedAuth[h] = true;
        emit ForcedOrder(pos, idx - 1, L.encodeOrder(idx - 1, o));
    }

    // ---- batches ----------------------------------------------------------------------------

    /// @param witnesses one price witness per oracle segment, at that segment's anchor (recorded,
    ///        ≤ maxAnchorAge old), as the session's price adapter reads it
    /// @param firstFills each segment's first fill: 0, then strictly increasing, all below the
    ///        number of fills (a batch without fills has one segment)
    /// @param fills packed fills (ClearingLedger.FILL_BYTES each), in execution order
    /// @param updates changed accounts (ClearingLedger.UPDATE_BYTES each), indices ascending
    /// @param proof multiproof of unchanged subtrees (SparseTree16.transition)
    /// @param reqCursor every withdrawal request before it is applied in its account
    /// @param forcedCursor every forced order before it is filled or rests after this batch
    /// @param forcedStatus per forced order from finalizedForced to forcedCursor: uint16,
    ///        0 = rests in the book, else 2·fill + side + 1 = filled there
    function propose(
        bytes[] calldata witnesses,
        uint32[] calldata firstFills,
        bytes calldata fills,
        bytes calldata updates,
        bytes32[] calldata proof,
        uint64 reqCursor,
        uint64 forcedCursor,
        bytes calldata forcedStatus
    ) external payable {
        // Active: the operator, or anyone after takeoverDelay. Closing: only the operator
        // settles what it executed, and only until anyone may close (so proposals can't
        // hold a session open forever). Closed: nobody.
        Phase ph = _phase;
        bool open = ph == Phase.Active && block.timestamp > _lastProposalAt + takeoverDelay;
        if (ph == Phase.Closed || (msg.sender != operator && !open)) revert WrongState();
        if (ph == Phase.Closing && block.timestamp > _closingAt + takeoverDelay) revert WrongState();
        if (_pending.at != 0 || msg.value < minBond) revert WrongState();
        if (fills.length % L.FILL_BYTES != 0 || fills.length / L.FILL_BYTES > MAX_FILLS) revert BadBatch("fills");
        if (reqCursor < _finalizedReq || reqCursor > _requests.length) revert BadBatch("reqCursor");
        uint256 f0 = _finalizedForced;
        if (forcedCursor < f0 || forcedCursor > _forced.length || forcedStatus.length != 2 * (forcedCursor - f0)) {
            revert BadBatch("forcedCursor");
        }
        bytes32 segments = _segments(witnesses, firstFills, fills.length / L.FILL_BYTES);
        for (uint256 j = f0; j < forcedCursor; ++j) {
            uint16 s = uint16(bytes2(forcedStatus[2 * (j - f0):2 * (j - f0) + 2]));
            if (s == 0) {
                emit ForcedRested(j);
                continue;
            }
            L.PackedOrder memory o = codec.orderOf(fills, (s - 1) / 2, (s - 1) % 2 == 1);
            if (o.idx >= _users.length || R.orderHash(L.toOrder(o, _users[o.idx])) != _forced[j].hash) {
                revert BadBatch("forcedStatus");
            }
        }
        bytes32 root = _finalizedRoot;
        if (updates.length != 0) {
            (bytes32 oldRoot, bytes32 newRoot, uint256 lastIdx) = codec.transition(updates, proof);
            if (oldRoot != root) revert BadProof();
            if (lastIdx >= _users.length) revert BadBatch("index");
            root = newRoot;
        }
        _pending = Pending(
            root, keccak256(fills), segments, uint64(block.timestamp), reqCursor, forcedCursor, msg.sender, msg.value
        );
        _lastProposalAt = block.timestamp;
        emit Proposed(_batches + 1, root, msg.sender, segments, reqCursor, forcedCursor);
    }

    /// Verifies every segment's price at its anchor; returns the commitment challengeFill checks.
    function _segments(bytes[] calldata witnesses, uint32[] calldata firstFills, uint256 nFills)
        internal
        returns (bytes32)
    {
        uint256 n = witnesses.length;
        if (n == 0 || firstFills.length != n || firstFills[0] != 0) revert BadBatch("segments");
        uint256[] memory prices = new uint256[](n);
        uint64[] memory blocks = new uint64[](n);
        for (uint256 s; s < n; ++s) {
            if (s > 0 && (firstFills[s] <= firstFills[s - 1] || firstFills[s] >= nFills)) revert BadBatch("segments");
            (prices[s], blocks[s]) = priceAdapter.price(witnesses[s], anchors, maxAnchorAge);
        }
        emit Segments(_batches + 1, firstFills, prices, blocks);
        return keccak256(abi.encode(firstFills, prices, blocks));
    }

    /// @notice Anyone, after the window: the pending root becomes final; the bond is credited
    ///         back to the proposer (withdrawBond).
    function finalize() external {
        Pending memory p = _pending;
        if (_phase == Phase.Closed || p.at == 0 || block.timestamp < p.at + challengeWindow) revert WrongState();
        _finalizedRoot = p.root;
        _finalizedReq = p.reqCursor;
        _finalizedForced = p.forcedCursor;
        _batches += 1;
        delete _pending;
        emit Finalized(_batches, p.root);
        _creditBond(p.proposer, p.bond);
    }

    function withdrawBond() external {
        uint256 b = _bondCredit[msg.sender];
        if (b == 0) revert WrongState();
        delete _bondCredit[msg.sender];
        (bool ok,) = msg.sender.call{value: b}("");
        if (!ok) revert TransferFailed();
    }

    // ---- lifecycle --------------------------------------------------------------------------

    /// @notice Stop admitting deposits, withdrawal requests and forced orders. The operator,
    ///         or anyone once the session has been idle for takeoverDelay (abandoned).
    function beginClose() external {
        if (_phase != Phase.Active) revert WrongState();
        if (msg.sender != operator && block.timestamp <= _lastProposalAt + takeoverDelay) revert WrongState();
        _phase = Phase.Closing;
        _closingAt = uint64(block.timestamp);
        emit ClosingStarted(_requests.length, _forced.length, msg.sender);
    }

    /// @notice Make the session terminal. Nothing may be pending: a proposal must have
    ///         finalized (or been discarded) first. The operator any time in Closing; anyone
    ///         takeoverDelay after Closing began.
    function close() external {
        if (_phase != Phase.Closing || _pending.at != 0) revert WrongState();
        if (msg.sender != operator && block.timestamp <= _closingAt + takeoverDelay) revert WrongState();
        _phase = Phase.Closed;
        emit Closed(_finalizedRoot, _batches);
    }

    // ---- views ------------------------------------------------------------------------------

    function users(uint256 i) external view returns (address) {
        return _users[i];
    }

    function userCount() external view returns (uint256) {
        return _users.length;
    }

    function indexPlusOne(address a) external view returns (uint32) {
        return _indexPlusOne[a];
    }

    function cumIn(uint32 idx) external view returns (Totals memory) {
        return _cumIn[idx];
    }

    function paid(uint32 idx) external view returns (Totals memory) {
        return _paid[idx];
    }

    function requests(uint256 i) external view returns (Request memory) {
        return _requests[i];
    }

    function requestCount() external view returns (uint256) {
        return _requests.length;
    }

    function forced(uint256 i) external view returns (Forced memory) {
        return _forced[i];
    }

    function forcedCount() external view returns (uint256) {
        return _forced.length;
    }

    /// The oldest unserved request or forced order is past its deadline (fixed when made).
    function overdue() external view returns (bool) {
        return _overdue();
    }
}

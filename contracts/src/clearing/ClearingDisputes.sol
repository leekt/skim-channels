// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingStorage} from "./ClearingStorage.sol";
import {ClearingCodec} from "./ClearingCodec.sol";
import {ClearingLedger as L} from "./ClearingLedger.sol";
import {ClearingRules as R} from "./ClearingRules.sol";
import {SparseTree16} from "../predict/SparseTree16.sol";

/// @notice Challenges, freeze and the operator-free exit of ClearingChannel. Runs only by
///         delegatecall from the channel (shared ClearingStorage layout).
contract ClearingDisputes is ClearingStorage {
    address private immutable self;

    constructor() {
        self = address(this);
    }

    // ---- config and views (reached through the channel's address) -------------------------

    function config() external view returns (Config memory) {
        return _cfg;
    }

    function state()
        external
        view
        returns (
            bytes32 finalizedRoot,
            uint256 finalizedReq,
            uint256 finalizedForced,
            uint256 batches,
            uint256 lastProposalAt,
            Phase phase,
            uint64 closingAt
        )
    {
        return (_finalizedRoot, _finalizedReq, _finalizedForced, _batches, _lastProposalAt, _phase, _closingAt);
    }

    function bondCredit(address a) external view returns (uint256) {
        return _bondCredit[a];
    }

    function pending() external view returns (Pending memory) {
        return _pending;
    }

    modifier viaChannel() {
        if (address(this) == self) revert WrongState();
        _;
    }

    /// Discard the pending proposal; its bond is credited to `to` (a challenger, or back to
    /// the proposer when a freeze stops settlement).
    function _discard(address to, string memory reason) internal {
        Pending memory p = _pending;
        delete _pending;
        emit Discarded(_batches + 1, to, reason);
        _creditBond(to, p.bond);
    }

    /// @notice While the session runs: withdrawals released in the finalized leaf, not yet
    ///         paid. After it closes, use `redeem`.
    function claim(uint32 idx, L.Account calldata leaf, bytes32[16] calldata sib) external viaChannel {
        if (_phase == Phase.Closed || idx >= _users.length) revert WrongState();
        _prove(leaf, idx, sib, _finalizedRoot);
        Totals storage pd = _paid[idx];
        uint128 e = leaf.ethOut - pd.eth;
        uint128 u = leaf.usdOut - pd.usd;
        if (e == 0 && u == 0) revert WrongState();
        (pd.eth, pd.usd) = (leaf.ethOut, leaf.usdOut);
        _pay(idx, e, u, false);
    }

    function _live(bytes calldata fills) internal view {
        Pending storage p = _pending;
        if (p.at == 0 || block.timestamp >= p.at + _cfg.challengeWindow) revert WrongState();
        if (keccak256(fills) != p.fillsHash) revert BadProof();
    }

    /// @notice Fill `i` of the pending batch is invalid: an unknown trader, a signature not
    ///         by its trader, or a ClearingRules rejection (band against the price of the fill's
    ///         own oracle segment, limits, expiry at that segment's anchor, same side, same
    ///         trader). The segments are the proposal's (checked against its commitment).
    function challengeFill(
        bytes calldata fills,
        uint256 i,
        uint32[] calldata firstFills,
        uint256[] calldata prices,
        uint64[] calldata anchorBlocks
    ) external viaChannel {
        _live(fills);
        if (i >= fills.length / L.FILL_BYTES) revert WrongState();
        if (keccak256(abi.encode(firstFills, prices, anchorBlocks)) != _pending.segments) revert BadProof();
        uint256 s = firstFills.length - 1;
        while (firstFills[s] > i) --s;
        (L.PackedOrder memory pa, bytes calldata sa, L.PackedOrder memory pb, bytes calldata sb) = L.fillAt(fills, i);
        uint256 n = _users.length;
        bool fault = pa.idx >= n || pb.idx >= n;
        if (!fault) {
            R.Order memory a = L.toOrder(pa, _users[pa.idx]);
            R.Order memory b = L.toOrder(pb, _users[pb.idx]);
            fault = _cfg.codec
                .fillFault(
                    a,
                    sa,
                    _forcedAuth[R.orderHash(a)],
                    b,
                    sb,
                    _forcedAuth[R.orderHash(b)],
                    prices[s],
                    _cfg.bandBps,
                    anchorBlocks[s],
                    _domain()
                );
        }
        if (!fault) revert NotWrong();
        _discard(msg.sender, "fill");
    }

    /// @notice Account `idx`'s leaf in the pending root isn't what ClearingLedger gives when
    ///         the finalized leaf is replayed through the batch — or it claims deposits L1
    ///         doesn't have, or skips (or exceeds) the requests before the batch's cursor.
    ///         An untouched leaf counts too (omission).
    function challengeAccount(
        uint32 idx,
        L.Account calldata oldLeaf,
        bytes32[16] calldata oldSib,
        L.Account calldata newLeaf,
        bytes32[16] calldata newSib,
        bytes calldata fills
    ) external viaChannel {
        _live(fills);
        if (idx >= _users.length) revert WrongState();
        _prove(oldLeaf, idx, oldSib, _finalizedRoot);
        _prove(newLeaf, idx, newSib, _pending.root);
        if (!_fault(idx, oldLeaf, newLeaf, fills)) revert NotWrong();
        _discard(msg.sender, "account");
    }

    function _fault(uint32 idx, L.Account calldata o, L.Account calldata nw, bytes calldata fills)
        internal
        view
        returns (bool)
    {
        Totals memory ins = _cumIn[idx];
        if (nw.ethIn > ins.eth || nw.usdIn > ins.usd) return true;
        uint256[] storage mine = _userRequests[idx];
        uint256 cursor = _pending.reqCursor;
        // Exactly the user's requests before the cursor are applied, at most a bounded number.
        if (nw.requests < o.requests || nw.requests > mine.length || nw.requests - o.requests > MAX_REQUESTS_PER_BATCH)
        {
            return true;
        }
        if (nw.requests < mine.length && mine[nw.requests] < cursor) return true;
        if (nw.requests > 0 && mine[nw.requests - 1] >= cursor) return true;
        ClearingCodec.AppliedRequest[] memory reqs = new ClearingCodec.AppliedRequest[](nw.requests - o.requests);
        for (uint256 r; r < reqs.length; ++r) {
            Request storage q = _requests[mine[o.requests + r]];
            reqs[r] = ClearingCodec.AppliedRequest(q.token, q.amount, q.inAt);
        }
        (L.Account memory want, bool ok) = _cfg.codec.replay(idx, o, nw.ethIn, nw.usdIn, reqs, fills);
        return !ok || L.leafHash(want) != L.leafHash(nw);
    }

    /// @notice Anyone: the oldest unserved withdrawal request or forced order is past its
    ///         deadline. The session closes at once (a pending batch is dropped, its bond
    ///         credited back to its proposer).
    function freeze() external viaChannel {
        if (_phase == Phase.Closed) revert WrongState();
        if (!_overdue()) revert NotOverdue();
        if (_pending.at != 0) _discard(_pending.proposer, "frozen");
        _phase = Phase.Closed;
        if (_closingAt == 0) _closingAt = uint64(block.timestamp);
        emit Frozen(_finalizedReq, _finalizedForced);
        emit Closed(_finalizedRoot, _batches);
    }

    /// @notice After the session closed: everything the user is owed, from the final root.
    ///         The leaf's balances, plus deposits it never applied, plus its released
    ///         withdrawals, minus everything already paid (claims and earlier redemptions).
    ///         Paid to the user's wallet (anyone may trigger it), or, by the user alone, into
    ///         the app's vault as free balance for another session. Both record the same
    ///         payout, so nothing can be redeemed twice either way.
    function redeem(uint32 idx, L.Account calldata leaf, bytes32[16] calldata sib, bool toVault) external viaChannel {
        if (_phase != Phase.Closed || idx >= _users.length) revert WrongState();
        if (toVault && (_cfg.vault == address(0) || msg.sender != _users[idx])) revert WrongState();
        _prove(leaf, idx, sib, _finalizedRoot);
        Totals memory ins = _cumIn[idx];
        Totals storage pd = _paid[idx];
        uint128 e = leaf.eth + (ins.eth - leaf.ethIn) + leaf.ethOut - pd.eth;
        uint128 u = leaf.usd + (ins.usd - leaf.usdIn) + leaf.usdOut - pd.usd;
        if (e == 0 && u == 0) revert WrongState();
        pd.eth += e;
        pd.usd += u;
        emit Redeemed(idx, e, u, toVault);
        _pay(idx, e, u, toVault);
    }

    /// @notice After close, optionally: publish final leaves, one complete aligned subtree
    ///         at a time (2^k leaves from `start`, ClearingLedger.LEAF_BYTES each, with the
    ///         16 − k siblings above it). Accepted only if the chunk is part of the final
    ///         root, so each chunk's calldata is recovery data L1 has checked. Chunks keep
    ///         every transaction bounded whatever the session's size; indices past the last
    ///         user must be empty leaves.
    function publishFinal(uint256 start, bytes calldata leaves, bytes32[] calldata path) external viaChannel {
        if (_phase != Phase.Closed || leaves.length % L.LEAF_BYTES != 0) revert WrongState();
        uint256 n = leaves.length / L.LEAF_BYTES;
        bytes32[] memory h = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            h[i] = L.leafHash(L.decodeLeaf(leaves[i * L.LEAF_BYTES:(i + 1) * L.LEAF_BYTES]));
        }
        if (SparseTree16.rootOfSubtree(h, start, path) != _finalizedRoot) revert BadProof();
        emit FinalPublished(_finalizedRoot, start, n);
    }
}

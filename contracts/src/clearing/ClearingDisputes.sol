// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingStorage} from "./ClearingStorage.sol";
import {ClearingCodec} from "./ClearingCodec.sol";
import {ClearingLedger as L} from "./ClearingLedger.sol";
import {ClearingRules as R} from "./ClearingRules.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

/// @notice Challenges, freeze and the operator-free exit of ClearingChannel. Runs only by
///         delegatecall from the channel (shared ClearingStorage layout).
contract ClearingDisputes is ClearingStorage {
    address private immutable self;

    constructor(Config memory c) ClearingStorage(c) {
        self = address(this);
    }

    // ---- config and views (reached through the channel's address) -------------------------

    function config() external view returns (Config memory) {
        return Config(
            operator,
            usd,
            anchors,
            witnessVerifier,
            codec,
            priceFeed,
            priceSlot,
            bandBps,
            challengeWindow,
            forceDelay,
            maxAnchorAge,
            minBond,
            takeoverDelay
        );
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
            bool frozen
        )
    {
        return (_finalizedRoot, _finalizedReq, _finalizedForced, _batches, _lastProposalAt, _frozen);
    }

    function pending() external view returns (Pending memory) {
        return _pending;
    }

    modifier viaChannel() {
        if (address(this) == self) revert WrongState();
        _;
    }

    /// Discard the pending proposal; its bond goes to `to` (a challenger, or back to the
    /// proposer when a freeze stops settlement).
    function _discard(address to, string memory reason) internal {
        Pending memory p = _pending;
        delete _pending;
        emit Discarded(_batches + 1, to, reason);
        (bool ok,) = to.call{value: p.bond}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Withdrawals released in the finalized leaf, not yet paid.
    function claim(uint32 idx, L.Account calldata leaf, bytes32[16] calldata sib) external viaChannel {
        if (_frozen || idx >= _users.length) revert WrongState();
        _prove(leaf, idx, sib, _finalizedRoot);
        Totals storage pd = _paid[idx];
        uint128 e = leaf.ethOut - pd.eth;
        uint128 u = leaf.usdOut - pd.usd;
        if (e == 0 && u == 0) revert WrongState();
        (pd.eth, pd.usd) = (leaf.ethOut, leaf.usdOut);
        _pay(idx, e, u);
    }

    function _live(bytes calldata fills) internal view {
        Pending storage p = _pending;
        if (p.at == 0 || block.timestamp >= p.at + challengeWindow) revert WrongState();
        if (keccak256(fills) != p.fillsHash) revert BadProof();
    }

    /// @notice Fill `i` of the pending batch is invalid: an unknown trader, a signature not
    ///         by its trader, or a ClearingRules rejection (band against the batch's L1 price,
    ///         limits, expiry, same side, same trader).
    function challengeFill(bytes calldata fills, uint256 i) external viaChannel {
        _live(fills);
        if (i >= fills.length / L.FILL_BYTES) revert WrongState();
        (L.PackedOrder memory pa, bytes calldata sa, L.PackedOrder memory pb, bytes calldata sb) = L.fillAt(fills, i);
        uint256 n = _users.length;
        bool fault = pa.idx >= n || pb.idx >= n;
        if (!fault) {
            Pending storage p = _pending;
            fault = codec.fillFault(
                L.toOrder(pa, _users[pa.idx]),
                sa,
                L.toOrder(pb, _users[pb.idx]),
                sb,
                p.price,
                bandBps,
                p.anchorBlock,
                R.domainSeparator(block.chainid, address(this))
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
        (L.Account memory want, bool ok) = codec.replay(idx, o, nw.ethIn, nw.usdIn, reqs, fills);
        return !ok || L.leafHash(want) != L.leafHash(nw);
    }

    /// @notice Anyone: the oldest unserved withdrawal request or forced order is past its
    ///         deadline. Stops settlement (a pending batch is dropped, its bond returned).
    function freeze() external viaChannel {
        if (_frozen) revert WrongState();
        if (!_overdue()) revert NotOverdue();
        _frozen = true;
        if (_pending.at != 0) _discard(_pending.proposer, "frozen");
        emit Frozen(_finalizedReq, _finalizedForced);
    }

    /// @notice After a freeze: the finalized leaf's balances, plus deposits it hasn't
    ///         applied, plus its released withdrawals, minus what was already paid.
    function exit(uint32 idx, L.Account calldata leaf, bytes32[16] calldata sib) external viaChannel {
        if (!_frozen || idx >= _users.length) revert WrongState();
        _prove(leaf, idx, sib, _finalizedRoot);
        Totals memory ins = _cumIn[idx];
        Totals storage pd = _paid[idx];
        uint128 e = leaf.eth + (ins.eth - leaf.ethIn) + leaf.ethOut - pd.eth;
        uint128 u = leaf.usd + (ins.usd - leaf.usdIn) + leaf.usdOut - pd.usd;
        if (e == 0 && u == 0) revert WrongState();
        pd.eth += e;
        pd.usd += u;
        _pay(idx, e, u);
    }
}

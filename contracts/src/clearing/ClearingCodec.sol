// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingLedger as L} from "./ClearingLedger.sol";
import {ClearingRules as R} from "./ClearingRules.sol";
import {SparseTree16} from "../predict/SparseTree16.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

/// @notice Stateless helpers for the clearing channel, split out for code size: the
///         account-root transition of a proposal, a fill's fault check, and the replay of
///         one account through a batch (ClearingLedger) for disputes. The batch price comes
///         from the session's price adapter (ChainlinkAdapter).
contract ClearingCodec {
    /// A request as an account replay needs it.
    struct AppliedRequest {
        uint8 token;
        uint128 amount;
        uint128 inAt;
    }

    error BadEncoding();

    /// @return oldRoot root the old leaves belong to (caller: must be finalized)
    /// @return newRoot root after the update
    /// @return lastIdx largest index (caller: must be registered)
    function transition(bytes calldata updates, bytes32[] calldata proof)
        external
        pure
        returns (bytes32 oldRoot, bytes32 newRoot, uint256 lastIdx)
    {
        uint256 w = L.UPDATE_BYTES;
        if (updates.length % w != 0) revert BadEncoding();
        uint256 n = updates.length / w;
        uint256[] memory idxs = new uint256[](n);
        bytes32[] memory olds = new bytes32[](n);
        bytes32[] memory news = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            bytes calldata u = updates[i * w:(i + 1) * w];
            idxs[i] = uint32(bytes4(u[0:4]));
            olds[i] = L.leafHash(L.decodeLeaf(u[4:112]));
            news[i] = L.leafHash(L.decodeLeaf(u[112:220]));
        }
        lastIdx = n == 0 ? 0 : idxs[n - 1];
        (oldRoot, newRoot) = SparseTree16.transition(idxs, olds, news, proof);
    }

    /// Whether a fill breaks ClearingRules (band against the batch's L1 price, limits,
    /// expiry, same side, same trader) or carries an order its trader didn't authorize: neither
    /// a typed signature by the trader nor a forced order the trader posted on L1 (`authA/B`).
    function fillFault(
        R.Order calldata a,
        bytes calldata sigA,
        bool authA,
        R.Order calldata b,
        bytes calldata sigB,
        bool authB,
        uint256 l1Price,
        uint256 bandBps,
        uint64 anchorBlock,
        bytes32 domain
    ) external pure returns (bool) {
        return R.check(a, b, l1Price, bandBps, anchorBlock) != R.Reject.None
            || (!authA && ChannelTypes.recoverSigner(R.orderDigest(domain, a), sigA) != a.trader)
            || (!authB && ChannelTypes.recoverSigner(R.orderDigest(domain, b), sigB) != b.trader);
    }

    /// The packed order on side `sideB` of fill `i` (for forced-order statuses).
    function orderOf(bytes calldata fills, uint256 i, bool sideB) external pure returns (L.PackedOrder memory o) {
        if (fills.length % L.FILL_BYTES != 0 || i >= fills.length / L.FILL_BYTES) revert BadEncoding();
        (L.PackedOrder memory a,, L.PackedOrder memory b,) = L.fillAt(fills, i);
        o = sideB ? b : a;
    }

    /// @notice Account `idx` through one batch: deposits up to `ins`, then `reqs`, then every
    ///         fill side naming `idx`, in order. `ok` is false when the transition can't
    ///         happen (deposits backwards, a request whose prior deposits aren't applied, a
    ///         stale nonce, a sale the balance doesn't cover).
    function replay(
        uint32 idx,
        L.Account memory acc,
        uint128 ethIn,
        uint128 usdIn,
        AppliedRequest[] calldata reqs,
        bytes calldata fills
    ) external pure returns (L.Account memory, bool ok) {
        if (fills.length % L.FILL_BYTES != 0) revert BadEncoding();
        if (!L.applyDeposits(acc, ethIn, usdIn)) return (acc, false);
        for (uint256 r; r < reqs.length; ++r) {
            if ((reqs[r].token == R.ETH ? ethIn : usdIn) < reqs[r].inAt) return (acc, false);
            L.applyRequest(acc, reqs[r].token, reqs[r].amount);
        }
        uint256 n = fills.length / L.FILL_BYTES;
        for (uint256 i; i < n; ++i) {
            (L.PackedOrder memory a,, L.PackedOrder memory b,) = L.fillAt(fills, i);
            if (a.idx == idx && !L.applySide(acc, a.sellToken, a.sellAmount, b.sellAmount, a.nonce)) {
                return (acc, false);
            }
            if (b.idx == idx && !L.applySide(acc, b.sellToken, b.sellAmount, a.sellAmount, b.nonce)) {
                return (acc, false);
            }
        }
        return (acc, true);
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingRules as R} from "./ClearingRules.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

/// @notice Stateless half of ClearingSettlement (code-size split): decodes a batch's fills
///         and applies ClearingRules to each, exactly as ClearingApp did when it ran them.
contract ClearingChecker {
    uint256 public constant MAX_USERS = 64;
    uint256 public constant MAX_FILLS = 128;

    error BadBatch(uint256 fill, R.Reject reason);
    error BadNonce(uint256 fill);
    error UnknownTrader(uint256 fill);
    error BadShape();

    /// The batch's market: the L1 price at its anchor, the band, and the anchor block.
    struct Market {
        uint256 price;
        uint256 bandBps;
        uint64 anchorBlock;
    }
    error Undercollateralized(uint256 fill, address trader, uint8 token);

    /// @param fills abi.encode(ClearingRules.Fill[]), in execution order
    /// @param users every trader, strictly ascending
    /// @param at for each fill, the indices in `users` of its two traders (a, then b)
    /// @param floors each user's settled nonce floor
    /// @param free each user's free escrow [ETH, USD] (balance minus reserved withdrawals);
    ///        after every fill, each spending side must still be ≥ 0 — the check ClearingApp
    ///        makes as it executes, in the same order
    /// @return dEth net ETH change per user
    /// @return dUsd net USD change per user
    /// @return nonces each user's highest nonce after the batch
    function net(
        bytes calldata fills,
        address[] calldata users,
        uint16[] calldata at,
        uint64[] memory floors,
        uint256[2][] memory free,
        Market memory m
    ) external pure returns (int256[] memory dEth, int256[] memory dUsd, uint64[] memory nonces) {
        R.Fill[] memory fs = abi.decode(fills, (R.Fill[]));
        uint256 n = users.length;
        if (fs.length > MAX_FILLS || n > MAX_USERS) revert BadShape(); // an empty batch only advances the numbering
        for (uint256 i = 1; i < n; ++i) {
            if (users[i] <= users[i - 1]) revert BadShape();
        }
        dEth = new int256[](n);
        dUsd = new int256[](n);
        if (floors.length != n || free.length != n || at.length != 2 * fs.length) revert BadShape();
        nonces = floors;
        for (uint256 f; f < fs.length; ++f) {
            _fill(fs[f], f, users, at, m, nonces, free, dEth, dUsd);
        }
    }

    function _fill(
        R.Fill memory x,
        uint256 f,
        address[] calldata users,
        uint16[] calldata at,
        Market memory m,
        uint64[] memory nonces,
        uint256[2][] memory free,
        int256[] memory dEth,
        int256[] memory dUsd
    ) internal pure {
        R.Reject why = R.check(x.a, x.b, m.price, m.bandBps, m.anchorBlock);
        if (why != R.Reject.None) revert BadBatch(f, why);
        uint256 ua = at[2 * f];
        uint256 ub = at[2 * f + 1];
        if (ua >= users.length || ub >= users.length || users[ua] != x.a.trader || users[ub] != x.b.trader) {
            revert UnknownTrader(f);
        }
        if (x.a.nonce <= nonces[ua] || x.b.nonce <= nonces[ub]) revert BadNonce(f);
        nonces[ua] = x.a.nonce;
        nonces[ub] = x.b.nonce;
        _apply(x, ua, ub, dEth, dUsd);
        _covered(free[ua], dEth[ua], dUsd[ua], x.a, f);
        _covered(free[ub], dEth[ub], dUsd[ub], x.b, f);
    }

    /// @notice Whether order `sideB ? b : a` of fill `f` isn't signed by its trader.
    function badSignature(bytes32 domain, bytes calldata fills, uint256 f, bool sideB) external pure returns (bool) {
        R.Fill memory fill = abi.decode(fills, (R.Fill[]))[f];
        R.Order memory o = sideB ? fill.b : fill.a;
        bytes memory sig = sideB ? fill.sigB : fill.sigA;
        return ChannelTypes.recoverSigner(R.orderDigest(domain, o), sig) != o.trader;
    }

    /// ClearingRules.effects, with its traders already resolved to indices (a: ua, b: ub).
    function _apply(R.Fill memory x, uint256 ua, uint256 ub, int256[] memory dEth, int256[] memory dUsd) internal pure {
        (, uint8[4] memory tok, int256[4] memory amt) = R.effects(x.a, x.b);
        for (uint256 k; k < 4; ++k) {
            uint256 u = k < 2 ? ua : ub;
            if (tok[k] == R.ETH) dEth[u] += amt[k];
            else dUsd[u] += amt[k];
        }
    }

    function _covered(uint256[2] memory free, int256 dEth, int256 dUsd, R.Order memory o, uint256 f) internal pure {
        int256 left = o.sellToken == R.ETH ? int256(free[0]) + dEth : int256(free[1]) + dUsd;
        if (left < 0) revert Undercollateralized(f, o.trader, o.sellToken);
    }
}

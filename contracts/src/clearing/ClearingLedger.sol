// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingRules as R} from "./ClearingRules.sol";

/// @notice The account state of the clearing channel (v2) and the one transition function
///         both sides use: ClearingBook applies it as it executes on the executor, and
///         ClearingDisputes replays it on L1 to judge a challenged account. Packed calldata
///         formats are defined here too.
///
/// Per account, in this order within a batch: deposits applied, then withdrawal requests (in
/// queue order), then fills (in batch order).
library ClearingLedger {
    /// order: trader index (4) ‖ sellToken (1) ‖ sellAmount (16) ‖ buyAmount (16) ‖ nonce (8) ‖ expiry (8)
    uint256 internal constant ORDER_BYTES = 53;
    /// fill: order a ‖ sig a (65) ‖ order b ‖ sig b (65) ‖ ethAmount (16) ‖ usdAmount (16)
    uint256 internal constant FILL_BYTES = 268;
    /// leaf: eth, usd, ethIn, usdIn, ethOut, usdOut (16 each) ‖ nonce (8) ‖ requests (4) ‖ filled (16)
    uint256 internal constant LEAF_BYTES = 124;
    /// update: index (4) ‖ old leaf ‖ new leaf
    uint256 internal constant UPDATE_BYTES = 252;
    /// The leaf format this code commits to (1: with partial fills). Sessions report it.
    uint256 internal constant LEAF_FORMAT = 1;
    bytes32 internal constant LEAF_TAG = keccak256("skim-clearing/account-leaf/v1");

    struct Account {
        uint128 eth; // free balance
        uint128 usd;
        uint128 ethIn; // cumulative L1 deposits applied
        uint128 usdIn;
        uint128 ethOut; // cumulative withdrawals released (claimable on L1)
        uint128 usdOut;
        uint64 nonce; // the trader's latest order: the highest nonce that has filled
        uint32 requests; // withdrawal requests applied
        /// How much of order `nonce`'s sellAmount has been sold, while it's partly filled; 0 once
        /// it's complete. At most one partly filled order per trader: a newer nonce ends it.
        uint128 filled;
    }

    /// A packed order with its trader as an index (L1 maps it to an address).
    struct PackedOrder {
        uint32 idx;
        uint8 sellToken;
        uint128 sellAmount;
        uint128 buyAmount;
        uint64 nonce;
        uint64 expiry;
    }

    function leafHash(Account memory a) internal pure returns (bytes32) {
        if (
            a.eth == 0 && a.usd == 0 && a.ethIn == 0 && a.usdIn == 0 && a.ethOut == 0 && a.usdOut == 0 && a.nonce == 0
                && a.requests == 0 && a.filled == 0
        ) return 0;
        return keccak256(abi.encode(LEAF_TAG, a));
    }

    function decodeLeaf(bytes calldata b) internal pure returns (Account memory a) {
        a.eth = uint128(bytes16(b[0:16]));
        a.usd = uint128(bytes16(b[16:32]));
        a.ethIn = uint128(bytes16(b[32:48]));
        a.usdIn = uint128(bytes16(b[48:64]));
        a.ethOut = uint128(bytes16(b[64:80]));
        a.usdOut = uint128(bytes16(b[80:96]));
        a.nonce = uint64(bytes8(b[96:104]));
        a.requests = uint32(bytes4(b[104:108]));
        a.filled = uint128(bytes16(b[108:124]));
    }

    function encodeLeaf(Account memory a) internal pure returns (bytes memory) {
        return abi.encodePacked(a.eth, a.usd, a.ethIn, a.usdIn, a.ethOut, a.usdOut, a.nonce, a.requests, a.filled);
    }

    function decodeOrder(bytes calldata b) internal pure returns (PackedOrder memory o) {
        o.idx = uint32(bytes4(b[0:4]));
        o.sellToken = uint8(b[4]);
        o.sellAmount = uint128(bytes16(b[5:21]));
        o.buyAmount = uint128(bytes16(b[21:37]));
        o.nonce = uint64(bytes8(b[37:45]));
        o.expiry = uint64(bytes8(b[45:53]));
    }

    function encodeOrder(uint32 idx, R.Order memory o) internal pure returns (bytes memory) {
        return abi.encodePacked(idx, o.sellToken, o.sellAmount, o.buyAmount, o.nonce, o.expiry);
    }

    /// Fill `i` of packed `fills`: both orders and both signatures.
    function fillAt(bytes calldata fills, uint256 i)
        internal
        pure
        returns (PackedOrder memory a, bytes calldata sigA, PackedOrder memory b, bytes calldata sigB)
    {
        bytes calldata f = fills[i * FILL_BYTES:(i + 1) * FILL_BYTES];
        a = decodeOrder(f[0:53]);
        sigA = f[53:118];
        b = decodeOrder(f[118:171]);
        sigB = f[171:236];
    }

    /// The amounts fill `i` exchanges: `ethAmount` ETH for `usdAmount` USD.
    function amountsAt(bytes calldata fills, uint256 i) internal pure returns (uint128 ethAmount, uint128 usdAmount) {
        bytes calldata f = fills[i * FILL_BYTES:(i + 1) * FILL_BYTES];
        ethAmount = uint128(bytes16(f[236:252]));
        usdAmount = uint128(bytes16(f[252:268]));
    }

    /// One fill side's flows: what the trader of `o` gives and receives in a fill of
    /// `ethAmount` ETH for `usdAmount` USD.
    function sideFlows(PackedOrder memory o, uint128 ethAmount, uint128 usdAmount)
        internal
        pure
        returns (uint128 give, uint128 receive_)
    {
        return o.sellToken == R.ETH ? (ethAmount, usdAmount) : (usdAmount, ethAmount);
    }

    function toOrder(PackedOrder memory p, address trader) internal pure returns (R.Order memory) {
        return R.Order(trader, p.sellToken, p.sellAmount, p.buyAmount, p.nonce, p.expiry);
    }

    // ---- the transition ----------------------------------------------------------------------

    /// Deposits up to the given cumulative amounts. False if they'd go backwards.
    function applyDeposits(Account memory acc, uint128 ethIn, uint128 usdIn) internal pure returns (bool) {
        if (ethIn < acc.ethIn || usdIn < acc.usdIn) return false;
        acc.eth += ethIn - acc.ethIn;
        acc.usd += usdIn - acc.usdIn;
        (acc.ethIn, acc.usdIn) = (ethIn, usdIn);
        return true;
    }

    /// One withdrawal request: releases min(amount, free balance) of the token.
    function applyRequest(Account memory acc, uint8 token, uint128 amount) internal pure returns (uint128 paid) {
        if (token == R.ETH) {
            paid = amount < acc.eth ? amount : acc.eth;
            acc.eth -= paid;
            acc.ethOut += paid;
        } else {
            paid = amount < acc.usd ? amount : acc.usd;
            acc.usd -= paid;
            acc.usdOut += paid;
        }
        acc.requests += 1;
    }

    /// One side of a fill: the trader of order `nonce` (selling up to `orderSell` of
    /// `sellToken`) gives `give` of it and receives `receive_` of the other. A newer nonce
    /// starts a new order (and ends any partly filled one); the same nonce continues the
    /// trader's partly filled order. False if the order is older or already complete, if the
    /// fill would sell more than the order's size, or if the balance can't cover the sale
    /// (collateral, checked fill by fill in execution order).
    function applySide(
        Account memory acc,
        uint8 sellToken,
        uint128 orderSell,
        uint64 nonce,
        uint128 give,
        uint128 receive_
    ) internal pure returns (bool) {
        // (Nonce 0 is never an order: it's not above a fresh account's 0, and filled is 0.)
        if (nonce < acc.nonce || (nonce == acc.nonce && acc.filled == 0)) return false;
        uint256 sold = (nonce == acc.nonce ? uint256(acc.filled) : 0) + give;
        if (sold > orderSell) return false;
        acc.nonce = nonce;
        acc.filled = sold == orderSell ? 0 : uint128(sold);
        if (sellToken == R.ETH) {
            if (acc.eth < give) return false;
            acc.eth -= give;
            acc.usd += receive_;
        } else {
            if (acc.usd < give) return false;
            acc.usd -= give;
            acc.eth += receive_;
        }
        return true;
    }
}

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
    /// fill: order a ‖ sig a (65) ‖ order b ‖ sig b (65)
    uint256 internal constant FILL_BYTES = 236;
    /// leaf: eth, usd, ethIn, usdIn, ethOut, usdOut (16 each) ‖ nonce (8) ‖ requests (4)
    uint256 internal constant LEAF_BYTES = 108;
    /// update: index (4) ‖ old leaf ‖ new leaf
    uint256 internal constant UPDATE_BYTES = 220;
    bytes32 internal constant LEAF_TAG = keccak256("skim-clearing/account-leaf/v0");

    struct Account {
        uint128 eth; // free balance
        uint128 usd;
        uint128 ethIn; // cumulative L1 deposits applied
        uint128 usdIn;
        uint128 ethOut; // cumulative withdrawals released (claimable on L1)
        uint128 usdOut;
        uint64 nonce; // highest order nonce consumed
        uint32 requests; // withdrawal requests applied
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
                && a.requests == 0
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
    }

    function encodeLeaf(Account memory a) internal pure returns (bytes memory) {
        return abi.encodePacked(a.eth, a.usd, a.ethIn, a.usdIn, a.ethOut, a.usdOut, a.nonce, a.requests);
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

    /// One side of a fill: the trader gives `sellAmount` of `sellToken` and receives
    /// `receiveAmount` of the other. False if the nonce isn't fresh or the balance can't
    /// cover the sale (collateral, checked fill by fill in execution order).
    function applySide(Account memory acc, uint8 sellToken, uint128 sellAmount, uint128 receiveAmount, uint64 nonce)
        internal
        pure
        returns (bool)
    {
        if (nonce <= acc.nonce) return false;
        acc.nonce = nonce;
        if (sellToken == R.ETH) {
            if (acc.eth < sellAmount) return false;
            acc.eth -= sellAmount;
            acc.usd += receiveAmount;
        } else {
            if (acc.usd < sellAmount) return false;
            acc.usd -= sellAmount;
            acc.eth += receiveAmount;
        }
        return true;
    }
}

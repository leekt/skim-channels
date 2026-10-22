// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice The one set of clearing rules, used by the app (ClearingApp, on the local
///         executor) and by L1 settlement (ClearingSettlement). Pure: same inputs, same answer
///         on either chain.
///
/// Two assets: token 0 is ETH (wei), token 1 is USD (6 decimals). An order sells
/// `sellAmount` of `sellToken` for at least `buyAmount` of the other. A fill matches two
/// orders on opposite sides; each side gives its full `sellAmount` and must receive at least
/// its `buyAmount`. The fill's price must be within `bandBps` of an L1 price read at the
/// batch's anchor, and the anchor block must not be past either order's expiry.
library ClearingRules {
    uint8 internal constant ETH = 0;
    uint8 internal constant USD = 1;
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,uint8 sellToken,uint128 sellAmount,uint128 buyAmount,uint64 nonce,uint64 expiry)"
    );

    struct Order {
        address trader;
        uint8 sellToken;
        uint128 sellAmount;
        uint128 buyAmount;
        uint64 nonce; // per trader, consumed in increasing order
        uint64 expiry; // last L1 block number the order may be filled at
    }

    struct Fill {
        Order a;
        Order b;
        bytes sigA;
        bytes sigB;
    }

    enum Reject {
        None,
        BadToken,
        ZeroAmount,
        SameSide,
        SameTrader,
        NotCrossing,
        Expired,
        OutsideBand
    }

    /// Orders are signed for the L1 settlement contract on L1's chain, never for the executor.
    function domainSeparator(uint256 l1ChainId, address settlement) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SkimClearing"),
                keccak256("0"),
                l1ChainId,
                settlement
            )
        );
    }

    function orderDigest(bytes32 domain, Order memory o) internal pure returns (bytes32) {
        bytes32 s =
            keccak256(abi.encode(ORDER_TYPEHASH, o.trader, o.sellToken, o.sellAmount, o.buyAmount, o.nonce, o.expiry));
        return keccak256(abi.encodePacked(hex"1901", domain, s));
    }

    function orderHash(Order memory o) internal pure returns (bytes32) {
        return keccak256(abi.encode(o));
    }

    /// USD (6 decimals) per 1 ETH, as the fill executes.
    function fillPrice(Order memory a, Order memory b) internal pure returns (uint256) {
        (Order memory eth, Order memory usd) = a.sellToken == ETH ? (a, b) : (b, a);
        return uint256(usd.sellAmount) * 1e18 / eth.sellAmount;
    }

    function check(Order memory a, Order memory b, uint256 l1Price, uint256 bandBps, uint256 anchorBlock)
        internal
        pure
        returns (Reject)
    {
        if (a.sellToken > USD || b.sellToken > USD) return Reject.BadToken;
        if (a.sellAmount == 0 || b.sellAmount == 0) return Reject.ZeroAmount;
        if (a.sellToken == b.sellToken) return Reject.SameSide;
        if (a.trader == b.trader) return Reject.SameTrader;
        if (a.sellAmount < b.buyAmount || b.sellAmount < a.buyAmount) return Reject.NotCrossing;
        if (anchorBlock > a.expiry || anchorBlock > b.expiry) return Reject.Expired;
        uint256 p = fillPrice(a, b);
        uint256 diff = p > l1Price ? p - l1Price : l1Price - p;
        if (diff * 10_000 > bandBps * l1Price) return Reject.OutsideBand;
        return Reject.None;
    }

    /// The fill's balance changes: (trader, token, signed amount) × 4.
    function effects(Order memory a, Order memory b)
        internal
        pure
        returns (address[4] memory who, uint8[4] memory token, int256[4] memory amount)
    {
        who = [a.trader, a.trader, b.trader, b.trader];
        token = [a.sellToken, b.sellToken, b.sellToken, a.sellToken];
        amount = [
            -int256(uint256(a.sellAmount)),
            int256(uint256(b.sellAmount)),
            -int256(uint256(b.sellAmount)),
            int256(uint256(a.sellAmount))
        ];
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice The one set of clearing rules, used by the app (ClearingBook, on the local
///         executor) and by L1 (ClearingCodec in disputes; ClearingChecker in the cost
///         control). Pure: same inputs, same answer on either chain.
///
/// Two assets: token 0 is ETH (wei), token 1 is USD (6 decimals). An order sells up to
/// `sellAmount` of `sellToken` at no worse a price than `buyAmount` for all of it. A fill
/// matches two orders on opposite sides and exchanges `ethAmount` ETH for `usdAmount` USD:
/// possibly part of either order (how much of each is left is account state, see
/// ClearingLedger). Each order's limit price must be met, the fill's price must be within
/// `bandBps` of the L1 price at the fill's head, and that head must not be past either
/// order's expiry. A full fill gives each order's whole `sellAmount`.
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

    /// The standard EIP-712 domain with all five fields: `chainId` is the chain wallets sign on
    /// (the app network), `verifyingContract` the L1 settlement contract, and `salt` the
    /// session id, so an order signed for one session never verifies in another.
    function domainSeparator(uint256 chainId, address settlement, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)"
                ),
                keccak256("SkimClearing"),
                keccak256("0"),
                chainId,
                settlement,
                salt
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

    /// The amounts a full fill exchanges: each order's whole `sellAmount`.
    function fullAmounts(Order memory a, Order memory b) internal pure returns (uint128 ethAmount, uint128 usdAmount) {
        return a.sellToken == ETH ? (a.sellAmount, b.sellAmount) : (b.sellAmount, a.sellAmount);
    }

    /// A full fill (each order's whole `sellAmount`).
    function check(Order memory a, Order memory b, uint256 l1Price, uint256 bandBps, uint256 head)
        internal
        pure
        returns (Reject)
    {
        (uint128 e, uint128 u) = fullAmounts(a, b);
        return check(a, b, e, u, l1Price, bandBps, head);
    }

    /// A fill of `ethAmount` ETH against `usdAmount` USD between orders `a` and `b`. Limits are
    /// prices: the ETH seller gets at least its `buyAmount / sellAmount` USD per ETH, the USD
    /// seller pays at most its `sellAmount / buyAmount`. How much of each order is left is
    /// checked against account state (ClearingLedger.applySide), not here.
    function check(
        Order memory a,
        Order memory b,
        uint128 ethAmount,
        uint128 usdAmount,
        uint256 l1Price,
        uint256 bandBps,
        uint256 head
    ) internal pure returns (Reject) {
        if (a.sellToken > USD || b.sellToken > USD) return Reject.BadToken;
        if (a.sellAmount == 0 || b.sellAmount == 0 || ethAmount == 0 || usdAmount == 0) return Reject.ZeroAmount;
        if (a.sellToken == b.sellToken) return Reject.SameSide;
        if (a.trader == b.trader) return Reject.SameTrader;
        (Order memory e, Order memory u) = a.sellToken == ETH ? (a, b) : (b, a);
        if (ethAmount > e.sellAmount || usdAmount > u.sellAmount) return Reject.NotCrossing;
        // e: usdAmount / ethAmount ≥ e.buyAmount / e.sellAmount; u: ethAmount / usdAmount ≥ u.buyAmount / u.sellAmount
        if (
            uint256(usdAmount) * e.sellAmount < uint256(e.buyAmount) * ethAmount
                || uint256(ethAmount) * u.sellAmount < uint256(u.buyAmount) * usdAmount
        ) return Reject.NotCrossing;
        if (head > a.expiry || head > b.expiry) return Reject.Expired;
        uint256 p = uint256(usdAmount) * 1e18 / ethAmount;
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

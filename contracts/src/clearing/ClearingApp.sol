// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingRules as R} from "./ClearingRules.sol";
import {L1View} from "./L1View.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

/// @notice The clearing app itself: Solidity, executed on the app's own EVM (a local
///         executor in this repo, not an L2 anyone has to trust). It owns AppState: the order
///         book, consumed orders and nonces, and every fill's obligations, batch by batch,
///         until L1 finalizes them. It reads L1 only through L1View, one pinned anchor per
///         batch, and can't write to L1 at all.
///
/// AppState survives L1 head changes: a new batch pins a new anchor and keeps everything
/// already here. The anchor matters for three reads only — the L1 price (risk band), each
/// trader's free escrow balance on ClearingSettlement, and how many batches L1 has
/// finalized (so obligations already reflected in the escrow aren't counted twice).
///
/// Collateral rule (v1): a fill may only spend what the trader holds in L1 escrow and hasn't
/// reserved for withdrawal, as of the batch anchor, plus the net of every fill L1 hasn't
/// finalized yet. Reading a wallet balance on L1 isn't collateral; only escrow is.
contract ClearingApp {
    /// ClearingSettlement's storage layout (slot 0: finalizedBatches, slot 1: accounts).
    uint256 internal constant SLOT_FINALIZED = 0;
    uint256 internal constant SLOT_ACCOUNTS = 1;

    L1View public immutable l1;
    address public immutable settlement; // on L1
    address public immutable priceFeed; // on L1
    bytes32 public immutable priceSlot;
    uint256 public immutable bandBps;
    address public immutable operator;
    bytes32 public immutable domain; // EIP-712 domain of the L1 settlement contract

    mapping(bytes32 => R.Order) public book; // resting orders by hash
    mapping(bytes32 => bytes) internal sigOf;
    mapping(bytes32 => bool) public consumed; // filled or cancelled: never again
    mapping(address => uint64) public lastNonce; // highest nonce filled

    uint64 public currentBatch = 1;
    bytes32 public batchAnchor; // anchorId pinned for the open batch
    uint64 public settledThrough; // L1's finalizedBatches at the latest anchor
    mapping(uint64 => mapping(address => int256[2])) internal delta; // net per batch, trader, token
    mapping(uint64 => address[]) internal tradersOf;
    mapping(uint64 => mapping(address => bool)) internal inBatch;
    mapping(uint64 => R.Fill[]) internal fillsOf;
    mapping(uint64 => bytes32) public anchorOf;
    /// Running hash of every state transition: equal logs + equal snapshots ⇒ equal digest.
    bytes32 public stateDigest;

    event OrderAccepted(bytes32 indexed hash, address indexed trader, uint64 nonce);
    event BatchOpened(uint64 indexed batch, bytes32 anchorId, uint64 settledThrough);
    event Filled(uint64 indexed batch, bytes32 a, bytes32 b, uint256 price);
    event BatchSealed(uint64 indexed batch, uint256 fills);

    error NotOperator();
    error BadSignature();
    error AlreadySeen();
    error StaleNonce();
    error NoOpenBatch();
    error BatchAlreadyOpen();
    error Rejected(R.Reject reason);
    error Insufficient(address trader, uint8 token);
    error UnknownOrder();
    error SettlementWentBack();

    constructor(
        L1View l1_,
        address settlement_,
        uint256 l1ChainId,
        address priceFeed_,
        bytes32 priceSlot_,
        uint256 bandBps_,
        address operator_
    ) {
        l1 = l1_;
        settlement = settlement_;
        priceFeed = priceFeed_;
        priceSlot = priceSlot_;
        bandBps = bandBps_;
        operator = operator_;
        domain = R.domainSeparator(l1ChainId, settlement_);
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // ---- orders -------------------------------------------------------------------------------

    /// Anyone can relay a signed order; it rests in the book until filled.
    function submitOrder(R.Order calldata o, bytes calldata sig) external returns (bytes32 h) {
        h = R.orderHash(o);
        if (consumed[h] || book[h].trader != address(0)) revert AlreadySeen();
        if (ChannelTypes.recoverSigner(R.orderDigest(domain, o), sig) != o.trader) revert BadSignature();
        if (o.nonce <= lastNonce[o.trader]) revert StaleNonce();
        book[h] = o;
        sigOf[h] = sig;
        _step(keccak256(abi.encode("order", h)));
        emit OrderAccepted(h, o.trader, o.nonce);
    }

    // ---- batches -----------------------------------------------------------------------------

    /// Pin the open batch to an L1 anchor (already pinned in L1View with the price, the
    /// settlement's finalizedBatches and each trader's account slots).
    function openBatch(bytes32 anchorId) external onlyOperator {
        if (batchAnchor != 0) revert BatchAlreadyOpen();
        uint64 f = uint64(l1.read(anchorId, settlement, bytes32(SLOT_FINALIZED)));
        if (f < settledThrough) revert SettlementWentBack();
        settledThrough = f;
        batchAnchor = anchorId;
        anchorOf[currentBatch] = anchorId;
        _step(keccak256(abi.encode("open", currentBatch, anchorId, f)));
        emit BatchOpened(currentBatch, anchorId, f);
    }

    function fill(bytes32 ha, bytes32 hb) external onlyOperator {
        bytes32 anchor = batchAnchor;
        if (anchor == 0) revert NoOpenBatch();
        R.Order memory a = book[ha];
        R.Order memory b = book[hb];
        if (a.trader == address(0) || b.trader == address(0)) revert UnknownOrder();
        uint256 price = l1.read(anchor, priceFeed, priceSlot);
        (uint64 anchorBlock,,) = l1.anchors(anchor);
        R.Reject why = R.check(a, b, price, bandBps, anchorBlock);
        if (why != R.Reject.None) revert Rejected(why);
        // Nonces are consumed in increasing order per trader (L1 checks the same).
        if (a.nonce <= lastNonce[a.trader] || b.nonce <= lastNonce[b.trader]) revert StaleNonce();
        lastNonce[a.trader] = a.nonce;
        lastNonce[b.trader] = b.nonce;
        uint64 batch = currentBatch;
        (address[4] memory who, uint8[4] memory tok, int256[4] memory amt) = R.effects(a, b);
        for (uint256 k; k < 4; ++k) {
            if (!inBatch[batch][who[k]]) {
                inBatch[batch][who[k]] = true;
                tradersOf[batch].push(who[k]);
            }
            delta[batch][who[k]][tok[k]] += amt[k];
        }
        // Spending sides only: each must stay within free escrow + unsettled net.
        if (available(a.trader, a.sellToken) < 0) revert Insufficient(a.trader, a.sellToken);
        if (available(b.trader, b.sellToken) < 0) revert Insufficient(b.trader, b.sellToken);
        consumed[ha] = true;
        consumed[hb] = true;
        fillsOf[batch].push(R.Fill(a, b, sigOf[ha], sigOf[hb]));
        delete book[ha];
        delete book[hb];
        _step(keccak256(abi.encode("fill", batch, ha, hb, price)));
        emit Filled(batch, ha, hb, R.fillPrice(a, b));
    }

    /// Close the open batch; its fills become an L1 proposal. AppState carries on.
    function sealBatch() external onlyOperator returns (uint64 closed) {
        if (batchAnchor == 0) revert NoOpenBatch();
        closed = currentBatch;
        currentBatch = closed + 1;
        batchAnchor = 0;
        _step(keccak256(abi.encode("seal", closed)));
        emit BatchSealed(closed, fillsOf[closed].length);
    }

    // ---- views -------------------------------------------------------------------------------

    /// Free escrow at the open batch's anchor + net of batches L1 hasn't finalized.
    function available(address trader, uint8 token) public view returns (int256 v) {
        uint256 base = uint256(keccak256(abi.encode(trader, SLOT_ACCOUNTS)));
        uint256 bals = l1.read(batchAnchor, settlement, bytes32(base));
        uint256 res = l1.read(batchAnchor, settlement, bytes32(base + 1));
        uint256 bal = token == R.ETH ? uint128(bals) : bals >> 128;
        uint256 r = token == R.ETH ? uint128(res) : res >> 128;
        v = bal > r ? int256(bal - r) : int256(0);
        for (uint64 b = settledThrough + 1; b <= currentBatch; ++b) {
            v += delta[b][trader][token];
        }
    }

    /// Obligations of fills L1 hasn't finalized yet (sealed or open batches).
    function unsettled(address trader, uint8 token) external view returns (int256 v) {
        for (uint64 b = settledThrough + 1; b <= currentBatch; ++b) {
            v += delta[b][trader][token];
        }
    }

    function fills(uint64 batch) external view returns (R.Fill[] memory) {
        return fillsOf[batch];
    }

    function traders(uint64 batch) external view returns (address[] memory) {
        return tradersOf[batch];
    }

    function batchDelta(uint64 batch, address trader) external view returns (int256 eth, int256 usd) {
        return (delta[batch][trader][0], delta[batch][trader][1]);
    }

    function _step(bytes32 t) internal {
        stateDigest = keccak256(abi.encode(stateDigest, t));
    }
}

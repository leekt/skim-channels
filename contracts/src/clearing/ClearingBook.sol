// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingRules as R} from "./ClearingRules.sol";
import {ClearingLedger as L} from "./ClearingLedger.sol";
import {L1View} from "./L1View.sol";
import {SparseTree16} from "../predict/SparseTree16.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

/// @notice The clearing app for ClearingChannel, on the app's executor (local, not
///         trusted by L1). AppState: every account exactly as L1 commits it (ClearingLedger),
///         the order book, and the open batch. Each batch pins one L1 anchor in L1View and
///         reads only what it needs there: the price, the channel's user list, the deposits
///         of the users it names, and the withdrawal and forced-order queues. Balances move
///         only through ClearingLedger, the function L1 replays in disputes.
///
/// A new operator can take over from L1 data alone: `adopt` imports the finalized leaves
/// (from published proposals) and checks them against the finalized root read on L1.
contract ClearingBook {
    // ClearingChannel storage slots (ClearingStorage, slots 0–6).
    uint256 internal constant SLOT_USERS = 0;
    uint256 internal constant SLOT_CUMIN = 1;
    uint256 internal constant SLOT_REQUESTS = 2;
    uint256 internal constant SLOT_FORCED = 3;
    uint256 internal constant SLOT_ROOT = 4;
    uint256 internal constant SLOT_REQ_CURSOR = 5;
    uint256 internal constant SLOT_FORCED_CURSOR = 6;

    struct Resting {
        L.PackedOrder o;
        bytes sig; // 65 zero bytes for a forced order (its trader authorized it on L1)
        uint256 forcedPlusOne; // position in L1's forced queue + 1, or 0
        bool live;
    }

    struct Batch {
        bytes32 anchorId;
        uint256 price;
        uint64 anchorBlock;
        bytes fills; // packed, as L1 takes them
        uint32[] touched;
        uint64 reqFrom;
        uint64 reqTo;
        uint64 forcedFrom;
        uint64 forcedTo;
        bool sealed_;
    }

    L1View public immutable l1;
    address public immutable channel; // on L1
    address public immutable priceFeed;
    bytes32 public immutable priceSlot;
    uint256 public immutable bandBps;
    address public immutable operator;
    bytes32 public immutable domain;

    address[] public users; // mirror of the channel's user list
    mapping(address => uint32) public indexPlusOne;
    mapping(uint32 => L.Account) internal accounts;
    mapping(bytes32 => Resting) internal book;
    mapping(bytes32 => bool) public consumed;
    uint64 public reqCursor; // next request to serve
    uint64 public forcedCursor; // next forced order to take in

    uint256 public current; // open batch number (1-based), 0 before the first
    mapping(uint256 => Batch) internal batches;
    mapping(uint256 => mapping(uint32 => L.Account)) internal before; // leaf at first touch
    mapping(uint256 => mapping(uint32 => bool)) internal touchedIn;
    mapping(uint256 => mapping(uint256 => uint16)) internal forcedStatus; // batch → forced pos → status
    bytes32 public stateDigest;

    event Opened(uint256 indexed batch, bytes32 anchorId, uint256 price);
    event Filled(uint256 indexed batch, bytes32 a, bytes32 b);
    event Sealed(uint256 indexed batch, uint256 fills, uint256 accounts);

    error NotOperator();
    error BatchOpen();
    error NoBatch();
    error Adopted();
    error UnknownTrader();
    error BadSignature();
    error AlreadySeen();
    error StaleNonce();
    error UnknownOrder();
    error Rejected(R.Reject reason);
    error Insufficient(uint32 idx);
    error ForcedMismatch(uint256 pos);
    error RootMismatch(bytes32 computed, bytes32 onL1);

    constructor(
        L1View l1_,
        address channel_,
        address priceFeed_,
        bytes32 priceSlot_,
        uint256 bandBps_,
        address operator_
    ) {
        l1 = l1_;
        channel = channel_;
        priceFeed = priceFeed_;
        priceSlot = priceSlot_;
        bandBps = bandBps_;
        operator = operator_;
        // Orders are signed for this chain (the network wallets connect to) and the L1 channel.
        domain = R.domainSeparator(block.chainid, channel_);
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // ---- reading L1 --------------------------------------------------------------------------

    function _l1(bytes32 anchor, uint256 slot) internal view returns (uint256) {
        return l1.read(anchor, channel, bytes32(slot));
    }

    function _arraySlot(uint256 slot, uint256 i, uint256 width) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(slot))) + i * width;
    }

    function _syncUsers(bytes32 anchor) internal {
        uint256 n = _l1(anchor, SLOT_USERS);
        for (uint256 i = users.length; i < n; ++i) {
            address u = address(uint160(_l1(anchor, _arraySlot(SLOT_USERS, i, 1))));
            users.push(u);
            indexPlusOne[u] = uint32(i + 1);
        }
    }

    // ---- handover ----------------------------------------------------------------------------

    /// @notice Start from L1's finalized state (a new operator, or a restart): the leaves of
    ///         every account (`idx` ascending), checked against the finalized root, and the
    ///         finalized queue cursors.
    function adopt(bytes32 anchor, uint32[] calldata idx, L.Account[] calldata leaves) external onlyOperator {
        if (current != 0) revert Adopted();
        _syncUsers(anchor);
        uint256[] memory ii = new uint256[](idx.length);
        bytes32[] memory hs = new bytes32[](idx.length);
        for (uint256 i; i < idx.length; ++i) {
            if (idx[i] >= users.length) revert UnknownTrader();
            accounts[idx[i]] = leaves[i];
            ii[i] = idx[i];
            hs[i] = L.leafHash(leaves[i]);
        }
        bytes32 root = SparseTree16.build(ii, hs);
        bytes32 onL1 = bytes32(_l1(anchor, SLOT_ROOT));
        if (root != onL1) revert RootMismatch(root, onL1);
        reqCursor = uint64(_l1(anchor, SLOT_REQ_CURSOR));
        forcedCursor = uint64(_l1(anchor, SLOT_FORCED_CURSOR));
        _step(keccak256(abi.encode("adopt", anchor, root)));
    }

    // ---- batches -----------------------------------------------------------------------------

    /// @notice Open the next batch on a pinned L1 anchor. Applies, in order: deposits of
    ///         `depositUsers` (any user may be left for later; nothing is lost), every queued
    ///         withdrawal request (as far as a user's per-batch limit allows), and takes the
    ///         new forced orders (data relayed from L1 events, checked against L1's hashes)
    ///         into the book.
    function openBatch(bytes32 anchor, uint32[] calldata depositUsers, bytes[] calldata forcedOrders)
        external
        onlyOperator
    {
        if (current != 0 && !batches[current].sealed_) revert BatchOpen();
        uint256 b = ++current;
        Batch storage bt = batches[b];
        bt.anchorId = anchor;
        bt.price = l1.read(anchor, priceFeed, priceSlot);
        (bt.anchorBlock,,) = l1.anchors(anchor);
        _syncUsers(anchor);
        for (uint256 i; i < depositUsers.length; ++i) {
            _deposit(b, anchor, depositUsers[i]);
        }
        _serveRequests(b, anchor);
        _takeForced(b, anchor, forcedOrders);
        _step(keccak256(abi.encode("open", b, anchor)));
        emit Opened(b, anchor, bt.price);
    }

    function _deposit(uint256 b, bytes32 anchor, uint32 idx) internal {
        uint256 t = _l1(anchor, uint256(keccak256(abi.encode(idx, SLOT_CUMIN))));
        L.Account memory a = _touch(b, idx);
        L.applyDeposits(a, uint128(t), uint128(t >> 128)); // never backwards: L1 only adds
        accounts[idx] = a;
    }

    function _serveRequests(uint256 b, bytes32 anchor) internal {
        Batch storage bt = batches[b];
        uint256 n = _l1(anchor, SLOT_REQUESTS);
        uint64 pos = reqCursor;
        bt.reqFrom = pos;
        mapping(uint32 => uint256) storage perUser = _perUser[b];
        for (; pos < n; ++pos) {
            uint256 w0 = _l1(anchor, _arraySlot(SLOT_REQUESTS, pos, 2));
            uint32 idx = uint32(w0);
            if (perUser[idx] == 16) break; // ClearingStorage.MAX_REQUESTS_PER_BATCH
            perUser[idx] += 1;
            uint8 token = uint8(w0 >> 32);
            uint128 amount = uint128(w0 >> 104);
            _deposit(b, anchor, idx); // the request covers every earlier deposit
            L.Account memory a = accounts[idx];
            L.applyRequest(a, token, amount);
            accounts[idx] = a;
        }
        reqCursor = pos;
        bt.reqTo = pos;
    }

    mapping(uint256 => mapping(uint32 => uint256)) internal _perUser;

    function _takeForced(uint256 b, bytes32 anchor, bytes[] calldata orders) internal {
        Batch storage bt = batches[b];
        uint256 n = _l1(anchor, SLOT_FORCED);
        uint64 pos = forcedCursor;
        bt.forcedFrom = pos;
        if (orders.length != n - pos) revert ForcedMismatch(pos);
        for (uint256 k; pos < n; ++pos) {
            L.PackedOrder memory p = L.decodeOrder(orders[k]);
            if (p.idx >= users.length) revert UnknownTrader();
            bytes32 h = R.orderHash(L.toOrder(p, users[p.idx]));
            if (bytes32(_l1(anchor, _arraySlot(SLOT_FORCED, pos, 2))) != h) revert ForcedMismatch(pos);
            if (book[h].live) {
                book[h].forcedPlusOne = pos + 1; // already relayed off-chain: now also forced
            } else if (!consumed[h]) {
                book[h] = Resting(p, new bytes(65), pos + 1, true);
            } // consumed earlier: L1 sees it published as resting, which is harmless

            ++k;
        }
        forcedCursor = pos;
        bt.forcedTo = pos;
    }

    /// Anyone can relay a signed order; it rests in the book until filled.
    function submitOrder(R.Order calldata o, bytes calldata sig) external returns (bytes32 h) {
        uint32 ip = indexPlusOne[o.trader];
        if (ip == 0) revert UnknownTrader();
        h = R.orderHash(o);
        if (consumed[h] || book[h].live) revert AlreadySeen();
        if (ChannelTypes.recoverSigner(R.orderDigest(domain, o), sig) != o.trader) revert BadSignature();
        if (o.nonce <= accounts[ip - 1].nonce) revert StaleNonce();
        book[h] =
            Resting(L.PackedOrder(ip - 1, o.sellToken, o.sellAmount, o.buyAmount, o.nonce, o.expiry), sig, 0, true);
        _step(keccak256(abi.encode("order", h)));
    }

    /// The trader withdraws a resting order (AppState only: it was never on L1).
    function cancel(bytes32 h) external {
        Resting storage r = book[h];
        if (!r.live) revert UnknownOrder();
        if (users[r.o.idx] != msg.sender) revert NotOperator();
        if (r.forcedPlusOne != 0) revert ForcedMismatch(r.forcedPlusOne - 1); // L1 must see it published
        consumed[h] = true;
        delete book[h];
        _step(keccak256(abi.encode("cancel", h)));
    }

    function fill(bytes32 ha, bytes32 hb) external onlyOperator {
        uint256 b = current;
        Batch storage bt = batches[b];
        if (b == 0 || bt.sealed_) revert NoBatch();
        Resting memory ra = book[ha];
        Resting memory rb = book[hb];
        if (!ra.live || !rb.live) revert UnknownOrder();
        R.Reject why = R.check(
            L.toOrder(ra.o, users[ra.o.idx]), L.toOrder(rb.o, users[rb.o.idx]), bt.price, bandBps, bt.anchorBlock
        );
        if (why != R.Reject.None) revert Rejected(why);
        L.Account memory a = _touch(b, ra.o.idx);
        if (!L.applySide(a, ra.o.sellToken, ra.o.sellAmount, rb.o.sellAmount, ra.o.nonce)) {
            revert Insufficient(ra.o.idx);
        }
        accounts[ra.o.idx] = a;
        L.Account memory c = _touch(b, rb.o.idx);
        if (!L.applySide(c, rb.o.sellToken, rb.o.sellAmount, ra.o.sellAmount, rb.o.nonce)) {
            revert Insufficient(rb.o.idx);
        }
        accounts[rb.o.idx] = c;
        uint256 i = bt.fills.length / L.FILL_BYTES;
        if (ra.forcedPlusOne != 0) forcedStatus[b][ra.forcedPlusOne - 1] = uint16(2 * i + 1);
        if (rb.forcedPlusOne != 0) forcedStatus[b][rb.forcedPlusOne - 1] = uint16(2 * i + 2);
        bt.fills = bytes.concat(bt.fills, _packed(ra.o), ra.sig, _packed(rb.o), rb.sig);
        consumed[ha] = true;
        consumed[hb] = true;
        delete book[ha];
        delete book[hb];
        _step(keccak256(abi.encode("fill", b, ha, hb)));
        emit Filled(b, ha, hb);
    }

    function seal() external onlyOperator returns (uint256 b) {
        b = current;
        Batch storage bt = batches[b];
        if (b == 0 || bt.sealed_) revert NoBatch();
        bt.sealed_ = true;
        _step(keccak256(abi.encode("seal", b)));
        emit Sealed(b, bt.fills.length / L.FILL_BYTES, bt.touched.length);
    }

    // ---- views for the proposal --------------------------------------------------------------

    /// Everything L1's `propose` needs for batch `b` (the price witness comes from the runtime).
    function proposal(uint256 b)
        external
        view
        returns (
            bytes32 anchorId,
            bytes memory fills,
            uint32[] memory idx,
            L.Account[] memory olds,
            L.Account[] memory news,
            uint64 reqTo,
            uint64 forcedTo,
            bytes memory statuses
        )
    {
        Batch storage bt = batches[b];
        idx = bt.touched;
        olds = new L.Account[](idx.length);
        news = new L.Account[](idx.length);
        for (uint256 i; i < idx.length; ++i) {
            olds[i] = before[b][idx[i]];
            news[i] = b == current ? accounts[idx[i]] : _after(b, idx[i]);
        }
        for (uint64 j = bt.forcedFrom; j < bt.forcedTo; ++j) {
            statuses = bytes.concat(statuses, bytes2(forcedStatus[b][j]));
        }
        return (bt.anchorId, bt.fills, idx, olds, news, bt.reqTo, bt.forcedTo, statuses);
    }

    /// An account's leaf at the end of batch `b`: its leaf before the next batch that touched
    /// it, or its current leaf.
    function _after(uint256 b, uint32 i) internal view returns (L.Account memory) {
        for (uint256 k = b + 1; k <= current; ++k) {
            if (touchedIn[k][i]) return before[k][i];
        }
        return accounts[i];
    }

    function account(uint32 idx) external view returns (L.Account memory) {
        return accounts[idx];
    }

    function resting(bytes32 h) external view returns (bool) {
        return book[h].live;
    }

    function userCount() external view returns (uint256) {
        return users.length;
    }

    // ---- internals ---------------------------------------------------------------------------

    function _touch(uint256 b, uint32 idx) internal returns (L.Account memory a) {
        a = accounts[idx];
        if (!touchedIn[b][idx]) {
            touchedIn[b][idx] = true;
            before[b][idx] = a;
            batches[b].touched.push(idx);
        }
    }

    function _packed(L.PackedOrder memory o) internal pure returns (bytes memory) {
        return abi.encodePacked(o.idx, o.sellToken, o.sellAmount, o.buyAmount, o.nonce, o.expiry);
    }

    function _step(bytes32 t) internal {
        stateDigest = keccak256(abi.encode(stateDigest, t));
    }
}

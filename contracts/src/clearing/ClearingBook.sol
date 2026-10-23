// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingRules as R} from "./ClearingRules.sol";
import {ClearingLedger as L} from "./ClearingLedger.sol";
import {ClearingStorage as S} from "./ClearingStorage.sol";
import {SparseTree16} from "../predict/SparseTree16.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

/// The L1 channel's views, called at their L1 address: on the app executor the channel (and
/// its disputes half) are imported read-only, so each call runs L1's code on L1's state at
/// the L1 head the executor has applied.
interface IClearingL1 {
    function users(uint256 i) external view returns (address);
    function userCount() external view returns (uint256);
    function cumIn(uint32 idx) external view returns (S.Totals memory);
    function requests(uint256 i) external view returns (S.Request memory);
    function requestCount() external view returns (uint256);
    function forced(uint256 i) external view returns (S.Forced memory);
    function forcedCount() external view returns (uint256);
    function state() external view returns (bytes32, uint256, uint256, uint256, uint256, S.Phase, uint64);
    function pending() external view returns (S.Pending memory);
}

/// The app executor's L1 head (crates/app-executor, `db::L1_HEAD`): which L1 block the imported
/// reads in this transaction reflect.
interface IL1Head {
    function head() external view returns (uint256 number, bytes32 hash, uint256 timestamp);
}

/// Chainlink's feed interface (the proxy apps call).
interface IAggregatorV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/// @notice The clearing app for ClearingChannel, on the app executor (crates/app-executor,
///         not trusted by L1). AppState: every account exactly as L1 commits it
///         (ClearingLedger), the order book, and the open batch. L1 state is read with
///         ordinary calls at L1 addresses: the channel's users, deposits and queues, and the
///         price from the real Chainlink feed (`latestRoundData()` through its proxy), all at
///         the L1 head the executor has applied. Balances move only through ClearingLedger,
///         the function L1 replays in disputes.
///
/// Every fill is judged at the L1 head it ran against (its segment, below): expiry against
/// that head's number, and the price must be the feed's latest round as read at or before it
/// (the same rule ChainlinkAdapter enforces on L1 from proofs), answered no later than its
/// read block's time and no more than `maxStaleness` before the fill's head time.
///
/// A new operator can take over from L1 data alone: `adopt` imports the finalized leaves
/// (from published proposals or a session package) and checks them against L1's root.
contract ClearingBook {
    IL1Head internal constant L1_HEAD = IL1Head(0x0000000000000000000000000000000000004C31);

    struct Resting {
        L.PackedOrder o;
        bytes sig; // 65 zero bytes for a forced order (its trader authorized it on L1)
        uint256 forcedPlusOne; // position in L1's forced queue + 1, or 0
        bool live;
    }

    /// One execution segment of a batch: the fills from `firstFill` on ran at L1 head `head`
    /// (block `hash`, header time `time`), priced with the feed's round `round` as first read
    /// at L1 block `priceBlock` (answered at `updatedAt`). A segment starts whenever a fill runs
    /// at a new head; the price is re-read there only if the round changed, otherwise the
    /// earlier read (and its L1 witness) is reused. L1 checks each segment's head (recorded,
    /// recent), its price at `priceBlock` ≤ `head`, and freshness at the head's time; disputes
    /// judge expiry against `head`.
    struct Segment {
        uint64 head;
        uint64 time;
        bytes32 hash;
        uint32 firstFill;
        uint80 round;
        uint64 priceBlock;
        uint64 updatedAt;
        uint256 price;
    }

    struct Batch {
        Segment[] segments;
        bytes fills; // packed, as L1 takes them
        uint32[] touched;
        uint64 reqFrom;
        uint64 reqTo;
        uint64 forcedFrom;
        uint64 forcedTo;
        bool sealed_;
    }

    IClearingL1 public immutable channel; // its L1 address
    IAggregatorV3 public immutable priceFeed; // the Chainlink proxy's L1 address
    uint256 public immutable maxStaleness;
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

    event Opened(uint256 indexed batch, uint64 l1Block);
    /// A new execution segment: a fill ran at a new L1 head. When `priceBlock == head` the feed
    /// had a new round there, and the operator fetches L1's price witness at that block.
    event SegmentStarted(uint256 indexed batch, uint256 segment, uint64 head, uint64 priceBlock, uint256 price);
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
    error StalePrice(uint256 updatedAt, uint64 headTime);
    /// The executor's L1 head is a different block at or below the batch's last segment head:
    /// L1 reorganized under the batch. The runtime recovers (BatchRuntime.tick).
    error L1Rewound(uint64 lastHead, uint256 head);

    constructor(
        address channel_,
        address priceFeed_,
        uint256 maxStaleness_,
        uint256 bandBps_,
        address operator_,
        uint64 sessionId_
    ) {
        channel = IClearingL1(channel_);
        priceFeed = IAggregatorV3(priceFeed_);
        maxStaleness = maxStaleness_;
        bandBps = bandBps_;
        operator = operator_;
        // Orders are signed for this chain (the network wallets connect to), the L1 channel
        // and its session.
        domain = R.domainSeparator(block.chainid, channel_, bytes32(uint256(sessionId_)));
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // ---- reading L1 --------------------------------------------------------------------------

    function _syncUsers() internal {
        uint256 n = channel.userCount();
        for (uint256 i = users.length; i < n; ++i) {
            address u = channel.users(i);
            users.push(u);
            indexPlusOne[u] = uint32(i + 1);
        }
    }

    /// The segment batch `b`'s next fill runs in: the current one if the executor is still at
    /// its head, else a new one at the executor's head. Segments exist only for fills (a
    /// batch's first segment starts at its first fill), so no segment is ever empty and their
    /// first fills strictly increase. Freshness is checked at every head, also when the round
    /// (and so the price and its witness) is reused.
    function _currentSegment(uint256 b) internal returns (Segment memory g) {
        Batch storage bt = batches[b];
        (uint256 number, bytes32 hash, uint256 time) = L1_HEAD.head();
        uint256 n = bt.segments.length;
        Segment memory last;
        if (n != 0) {
            last = bt.segments[n - 1];
            if (hash == last.hash) return last;
            if (number <= last.head) revert L1Rewound(last.head, number);
        }
        (uint80 round, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        g = Segment(uint64(number), uint64(time), hash, uint32(bt.fills.length / L.FILL_BYTES), round, 0, 0, 0);
        if (n != 0 && round == last.round) {
            (g.priceBlock, g.updatedAt, g.price) = (last.priceBlock, last.updatedAt, last.price);
        } else {
            if (answer <= 0 || updatedAt > time) revert StalePrice(updatedAt, uint64(time));
            (g.priceBlock, g.updatedAt, g.price) =
            (uint64(number), uint64(updatedAt), uint256(answer) * 1e6 / 10 ** priceFeed.decimals());
        }
        if (time > g.updatedAt + maxStaleness) revert StalePrice(g.updatedAt, uint64(time));
        bt.segments.push(g);
        emit SegmentStarted(b, n, g.head, g.priceBlock, g.price);
    }

    // ---- handover ----------------------------------------------------------------------------

    /// @notice Start from L1's committed state (a new operator, or a restart): the leaves of
    ///         every account (`idx` ascending), checked against the finalized root and cursors,
    ///         or (`pending`) against the proposed batch's root and cursors, so a proposal in
    ///         its challenge window never has to be re-executed.
    function adopt(uint32[] calldata idx, L.Account[] calldata leaves, bool pending) external onlyOperator {
        if (current != 0) revert Adopted();
        _syncUsers();
        uint256[] memory ii = new uint256[](idx.length);
        bytes32[] memory hs = new bytes32[](idx.length);
        for (uint256 i; i < idx.length; ++i) {
            if (idx[i] >= users.length) revert UnknownTrader();
            accounts[idx[i]] = leaves[i];
            ii[i] = idx[i];
            hs[i] = L.leafHash(leaves[i]);
        }
        bytes32 root = SparseTree16.build(ii, hs);
        (bytes32 onL1, uint256 req, uint256 frc,,,,) = channel.state();
        if (pending) {
            S.Pending memory p = channel.pending();
            (onL1, req, frc) = (p.root, p.reqCursor, p.forcedCursor);
        }
        if (root != onL1) revert RootMismatch(root, onL1);
        reqCursor = uint64(req);
        forcedCursor = uint64(frc);
        _step(keccak256(abi.encode("adopt", root)));
    }

    // ---- batches -----------------------------------------------------------------------------

    /// @notice Open the next batch at the L1 head the executor has applied now. The price isn't
    ///         read here: each fill reads it at its own head (`_currentSegment`), so a stale
    ///         feed never blocks deposits or withdrawals. Applies, in order: deposits of
    ///         `depositUsers` (any user may be left for later; nothing is lost), every queued
    ///         withdrawal request (as far as a user's per-batch limit allows), and takes the
    ///         new forced orders (data relayed from L1 events, checked against L1's hashes)
    ///         into the book.
    function openBatch(uint32[] calldata depositUsers, bytes[] calldata forcedOrders) external onlyOperator {
        if (current != 0 && !batches[current].sealed_) revert BatchOpen();
        uint256 b = ++current;
        _syncUsers();
        for (uint256 i; i < depositUsers.length; ++i) {
            _deposit(b, depositUsers[i]);
        }
        _serveRequests(b);
        _takeForced(b, forcedOrders);
        (uint256 number,,) = L1_HEAD.head();
        _step(keccak256(abi.encode("open", b)));
        emit Opened(b, uint64(number));
    }

    function _deposit(uint256 b, uint32 idx) internal {
        S.Totals memory t = channel.cumIn(idx);
        L.Account memory a = _touch(b, idx);
        L.applyDeposits(a, t.eth, t.usd); // never backwards: L1 only adds
        accounts[idx] = a;
    }

    function _serveRequests(uint256 b) internal {
        Batch storage bt = batches[b];
        uint256 n = channel.requestCount();
        uint64 pos = reqCursor;
        bt.reqFrom = pos;
        mapping(uint32 => uint256) storage perUser = _perUser[b];
        for (; pos < n; ++pos) {
            S.Request memory q = channel.requests(pos);
            uint32 idx = q.idx;
            if (perUser[idx] == 16) break; // ClearingStorage.MAX_REQUESTS_PER_BATCH
            perUser[idx] += 1;
            _deposit(b, idx); // the request covers every earlier deposit
            L.Account memory a = accounts[idx];
            L.applyRequest(a, q.token, q.amount);
            accounts[idx] = a;
        }
        reqCursor = pos;
        bt.reqTo = pos;
    }

    mapping(uint256 => mapping(uint32 => uint256)) internal _perUser;

    function _takeForced(uint256 b, bytes[] calldata orders) internal {
        Batch storage bt = batches[b];
        // The orders relayed (from L1 events); any posted since are taken in by a later batch.
        uint256 n = channel.forcedCount();
        uint64 pos = forcedCursor;
        bt.forcedFrom = pos;
        if (orders.length > n - pos) revert ForcedMismatch(pos);
        n = pos + orders.length;
        for (uint256 k; pos < n; ++pos) {
            L.PackedOrder memory p = L.decodeOrder(orders[k]);
            if (p.idx >= users.length) revert UnknownTrader();
            bytes32 h = R.orderHash(L.toOrder(p, users[p.idx]));
            if (channel.forced(pos).hash != h) revert ForcedMismatch(pos);
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
        Segment memory seg = _currentSegment(b);
        R.Reject why =
            R.check(L.toOrder(ra.o, users[ra.o.idx]), L.toOrder(rb.o, users[rb.o.idx]), seg.price, bandBps, seg.head);
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

    /// Everything L1's `propose` needs for batch `b` (the price witnesses, one per distinct
    /// `priceBlock`, and the raw headers of the segments' heads come from the runtime).
    function proposal(uint256 b)
        external
        view
        returns (
            Segment[] memory segs,
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
        return (bt.segments, bt.fills, idx, olds, news, bt.reqTo, bt.forcedTo, statuses);
    }

    /// An account's leaf at the end of batch `b`: its leaf before the next batch that touched
    /// it, or its current leaf.
    function _after(uint256 b, uint32 i) internal view returns (L.Account memory) {
        for (uint256 k = b + 1; k <= current; ++k) {
            if (touchedIn[k][i]) return before[k][i];
        }
        return accounts[i];
    }

    /// Batch `b`'s latest segment: its L1 head and time, and its price. The open batch before
    /// its first fill: the executor's head and the feed's price there (unchecked; a preview).
    function batchInfo(uint256 b) external view returns (uint64 head, uint64 time, uint256 price) {
        Segment[] storage g = batches[b].segments;
        if (g.length != 0) {
            Segment storage last = g[g.length - 1];
            return (last.head, last.time, last.price);
        }
        if (b != current || batches[b].sealed_) return (0, 0, 0);
        (uint256 number,, uint256 t) = L1_HEAD.head();
        (, int256 answer,,,) = priceFeed.latestRoundData();
        return (uint64(number), uint64(t), answer > 0 ? uint256(answer) * 1e6 / 10 ** priceFeed.decimals() : 0);
    }

    function segments(uint256 b) external view returns (Segment[] memory) {
        return batches[b].segments;
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

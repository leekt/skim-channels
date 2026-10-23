// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingChannelBase} from "./ClearingChannel.t.sol";
import {ClearingRules as R} from "../../src/clearing/ClearingRules.sol";
import {ClearingLedger as L} from "../../src/clearing/ClearingLedger.sol";
import {ClearingStorage} from "../../src/clearing/ClearingStorage.sol";

/// Execution segments: each fill is judged at the L1 head it ran at. Fixture: price 6000 at
/// block 100, 7000 at block 101, both recorded. L1 verifies each price at the block it was
/// read, each head as recorded and recent, and freshness at each head's time (also when a
/// witness is reused); disputes judge expiry against the fill's head.
contract ClearingSegmentsTest is ClearingChannelBase {
    bytes pkg0;

    function setUp() public override {
        super.setUp();
        string memory fx = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/read-and-split.json"));
        bytes memory raw0 = vm.parseJsonBytes(fx, ".h0.rawHeader");
        pkg0 = vm.parseJsonBytes(fx, ".h0.package");
        vm.setBlockhash(100, keccak256(raw0));
        anchors.record(raw0);
    }

    /// Fill 0 at 6000, fill 1 at 7000; `expiry1` is fill 1's orders' last block.
    function _two(uint64 expiry1) internal view returns (bytes memory fills, L.Account[] memory n) {
        fills = bytes.concat(
            _fill(_order(0, R.ETH, uint128(ETH1), 5990, 1), _order(1, R.USD, 6000, uint128(ETH1), 1)),
            _fill(_order(0, R.ETH, uint128(ETH1), 6990, 2, expiry1), _order(1, R.USD, 7000, uint128(ETH1), 2, expiry1))
        );
        n = _copyFin();
        n[0] = L.Account(1 ether, 13_000, 3 ether, 0, 0, 0, 2, 0);
        n[1] = L.Account(2 ether, 7000, 0, 20_000, 0, 0, 2, 0);
    }

    function _seg(uint32 f, uint32 w, uint64 head) internal pure returns (ClearingStorage.SegmentRef memory) {
        return ClearingStorage.SegmentRef(f, w, head);
    }

    function _segs(ClearingStorage.SegmentRef memory a, ClearingStorage.SegmentRef memory b)
        internal
        pure
        returns (ClearingStorage.SegmentRef[] memory s)
    {
        s = new ClearingStorage.SegmentRef[](2);
        (s[0], s[1]) = (a, b);
    }

    function _ws(bytes memory a, bytes memory b) internal pure returns (bytes[] memory w) {
        w = new bytes[](2);
        (w[0], w[1]) = (a, b);
    }

    /// The commitment's arrays for two segments.
    function _c(uint256 p0, uint256 p1, uint64 h0, uint64 h1)
        internal
        pure
        returns (uint32[] memory f, uint256[] memory p, uint64[] memory h)
    {
        f = new uint32[](2);
        f[1] = 1;
        p = new uint256[](2);
        (p[0], p[1]) = (p0, p1);
        h = new uint64[](2);
        (h[0], h[1]) = (h0, h1);
    }

    function _proposeWith(
        bytes memory fills,
        L.Account[] memory n,
        bytes[] memory w,
        ClearingStorage.SegmentRef[] memory s
    ) internal {
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        vm.prank(op);
        ch.propose{value: 1 ether}(w, s, fills, u, proof, 0, 0, "");
    }

    function _rejects(
        bytes memory fills,
        L.Account[] memory n,
        bytes[] memory w,
        ClearingStorage.SegmentRef[] memory s,
        bytes memory err
    ) internal {
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        vm.prank(op);
        vm.expectRevert(err);
        ch.propose{value: 1 ether}(w, s, fills, u, proof, 0, 0, "");
    }

    function test_eachFillIsJudgedAgainstItsOwnSegment() public {
        (bytes memory fills, L.Account[] memory n) = _two(1000);
        _proposeWith(fills, n, _ws(pkg0, pkg1), _segs(_seg(0, 0, 100), _seg(1, 1, 101)));
        (uint32[] memory f, uint256[] memory p, uint64[] memory h) = _c(6000, 7000, 100, 101);
        vm.startPrank(watcher);
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        D.challengeFill(fills, 0, f, p, h); // 6000 at its head (100)
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        D.challengeFill(fills, 1, f, p, h); // 7000 at its head (101)
        vm.stopPrank();
        _finalize(n);
    }

    function test_aFillInTheWrongSegmentIsAFault() public {
        (bytes memory fills, L.Account[] memory n) = _two(1000);
        // One segment at 6000 (block 100) for both fills: fill 1 (7000) is out of band.
        ClearingStorage.SegmentRef[] memory s = new ClearingStorage.SegmentRef[](1);
        s[0] = _seg(0, 0, 100);
        _proposeWith(fills, n, _w(pkg0), s);
        uint32[] memory f = new uint32[](1);
        uint256[] memory p = new uint256[](1);
        p[0] = 6000;
        uint64[] memory h = new uint64[](1);
        h[0] = 100;
        vm.prank(watcher);
        D.challengeFill(fills, 1, f, p, h);
        assertEq(D.pending().at, 0, "discarded");
    }

    function test_segmentsMustMatchTheCommitment() public {
        (bytes memory fills, L.Account[] memory n) = _two(1000);
        _proposeWith(fills, n, _ws(pkg0, pkg1), _segs(_seg(0, 0, 100), _seg(1, 1, 101)));
        (uint32[] memory f, uint256[] memory p, uint64[] memory h) = _c(7000, 7000, 100, 101); // substituted
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.BadProof.selector);
        D.challengeFill(fills, 0, f, p, h);
        (f, p, h) = _c(6000, 7000, 100, 100); // a challenger can't move a fill's head either
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.BadProof.selector);
        D.challengeFill(fills, 1, f, p, h);
    }

    /// Two fills at 6000; fill 1's orders expire at block `expiry1`.
    function _two6000(uint64 expiry1) internal view returns (bytes memory fills, L.Account[] memory n) {
        fills = bytes.concat(
            _fill(_order(0, R.ETH, uint128(ETH1), 5990, 1), _order(1, R.USD, 6000, uint128(ETH1), 1)),
            _fill(_order(0, R.ETH, uint128(ETH1), 5990, 2, expiry1), _order(1, R.USD, 6000, uint128(ETH1), 2, expiry1))
        );
        n = _copyFin();
        n[0] = L.Account(1 ether, 12_000, 3 ether, 0, 0, 0, 2, 0);
        n[1] = L.Account(2 ether, 8000, 0, 20_000, 0, 0, 2, 0);
    }

    /// Regression (review of 174ecfc, #2): the feed's round didn't change, so the price read at
    /// block 100 is reused at head 101 (one witness). Expiry is still judged at head 101: fill
    /// 1's orders expired at 100, so it's a provable fault, while fill 0 at head 100 isn't.
    function test_aReusedPriceDoesNotStopTheClock() public {
        (bytes memory fills, L.Account[] memory n) = _two6000(100);
        _proposeWith(fills, n, _w(pkg0), _segs(_seg(0, 0, 100), _seg(1, 0, 101)));
        (uint32[] memory f, uint256[] memory p, uint64[] memory h) = _c(6000, 6000, 100, 101);
        vm.startPrank(watcher);
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        D.challengeFill(fills, 0, f, p, h);
        D.challengeFill(fills, 1, f, p, h); // expired at its head
        vm.stopPrank();
        assertEq(D.pending().at, 0, "discarded");
    }

    /// Regression (review of 174ecfc, #2): a reused price must still be fresh at the later
    /// head's time, not only at the block it was read.
    function test_aReusedPriceMustBeFreshAtItsHead() public {
        (bytes memory fills, L.Account[] memory n) = _two6000(1000);
        uint256 t100 = anchors.timestampOf(anchors.anchorIdAt(100));
        uint256 t101 = anchors.timestampOf(anchors.anchorIdAt(101));
        assertGt(t101, t100, "fixture blocks are in time order");
        priceAdapter.setMaxStaleness(t101 - t100 - 1); // fresh at 100, stale by 101
        _rejects(
            fills,
            n,
            _w(pkg0),
            _segs(_seg(0, 0, 100), _seg(1, 0, 101)),
            abi.encodeWithSelector(ClearingStorage.BadBatch.selector, "stale")
        );
        priceAdapter.setMaxStaleness(t101 - t100);
        _proposeWith(fills, n, _w(pkg0), _segs(_seg(0, 0, 100), _seg(1, 0, 101)));
    }

    /// Regression (review of 174ecfc, #1): two segments starting at the same fill (an empty
    /// segment) are refused; the executor never makes one (segments start at fills).
    function test_segmentShapeIsChecked() public {
        (bytes memory fills, L.Account[] memory n) = _two(1000);
        bytes memory segErr = abi.encodeWithSelector(ClearingStorage.BadBatch.selector, "segments");
        bytes[] memory w = _ws(pkg0, pkg1);
        _rejects(fills, n, w, _segs(_seg(0, 0, 100), _seg(0, 1, 101)), segErr); // [0, 0]: an empty segment
        _rejects(fills, n, w, _segs(_seg(1, 0, 100), _seg(1, 1, 101)), segErr); // must start at fill 0
        _rejects(fills, n, w, _segs(_seg(0, 0, 100), _seg(2, 1, 101)), segErr); // past the last fill
        _rejects(fills, n, w, _segs(_seg(0, 0, 101), _seg(1, 1, 101)), segErr); // heads must increase
        _rejects(fills, n, w, _segs(_seg(0, 0, 100), _seg(1, 0, 101)), segErr); // a witness nobody uses
        _rejects(fills, n, _ws(pkg1, pkg0), _segs(_seg(0, 0, 100), _seg(1, 1, 101)), segErr); // read after its head
        _rejects(
            fills,
            n,
            _w(pkg0),
            _segs(_seg(0, 0, 100), _seg(1, 0, 102)),
            abi.encodeWithSelector(ClearingStorage.BadAnchor.selector)
        ); // head not recorded
        _rejects(fills, n, _nw(), _ns(), segErr); // fills without segments
        (bytes memory u, bytes32[] memory proof) = _updates(_copyFin());
        vm.prank(op);
        vm.expectRevert(segErr);
        ch.propose{value: 1 ether}(_w(), _ns(), "", u, proof, 0, 0, ""); // no fills: no witness either
        vm.roll(100 + 257);
        _rejects(
            fills,
            n,
            w,
            _segs(_seg(0, 0, 100), _seg(1, 1, 101)),
            abi.encodeWithSelector(ClearingStorage.BadAnchor.selector)
        ); // too old
    }
}

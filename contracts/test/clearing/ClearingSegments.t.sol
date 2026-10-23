// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingChannelBase} from "./ClearingChannel.t.sol";
import {ClearingRules as R} from "../../src/clearing/ClearingRules.sol";
import {ClearingLedger as L} from "../../src/clearing/ClearingLedger.sol";
import {ClearingStorage} from "../../src/clearing/ClearingStorage.sol";

/// Oracle segments: a batch whose app read the feed at two L1 heads (price 6000 at block 100,
/// then 7000 at block 101). L1 verifies each segment's price at its own anchor, and judges
/// each fill against its own segment.
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

    /// Fill 0 at 6000 (segment 0, block 100), fill 1 at 7000 (segment 1, block 101).
    function _two() internal view returns (bytes memory fills, L.Account[] memory n) {
        fills = bytes.concat(
            _fill(_order(0, R.ETH, uint128(ETH1), 5990, 1), _order(1, R.USD, 6000, uint128(ETH1), 1)),
            _fill(_order(0, R.ETH, uint128(ETH1), 6990, 2), _order(1, R.USD, 7000, uint128(ETH1), 2))
        );
        n = _copyFin();
        n[0] = L.Account(1 ether, 13_000, 3 ether, 0, 0, 0, 2, 0);
        n[1] = L.Account(2 ether, 7000, 0, 20_000, 0, 0, 2, 0);
    }

    function _seg2()
        internal
        view
        returns (bytes[] memory w, uint32[] memory f, uint256[] memory p, uint64[] memory b)
    {
        w = new bytes[](2);
        (w[0], w[1]) = (pkg0, pkg1);
        f = new uint32[](2);
        f[1] = 1;
        p = new uint256[](2);
        (p[0], p[1]) = (6000, 7000);
        b = new uint64[](2);
        (b[0], b[1]) = (100, 101);
    }

    function _proposeWith(bytes memory fills, L.Account[] memory n, bytes[] memory w, uint32[] memory f) internal {
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        vm.prank(op);
        ch.propose{value: 1 ether}(w, f, fills, u, proof, 0, 0, "");
    }

    function test_eachFillIsJudgedAgainstItsOwnSegment() public {
        (bytes memory fills, L.Account[] memory n) = _two();
        (bytes[] memory w, uint32[] memory f, uint256[] memory p, uint64[] memory b) = _seg2();
        _proposeWith(fills, n, w, f);
        vm.startPrank(watcher);
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        D.challengeFill(fills, 0, f, p, b); // 6000 in a 6000 segment
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        D.challengeFill(fills, 1, f, p, b); // 7000 in a 7000 segment
        vm.stopPrank();
        _finalize(n);
    }

    function test_aFillInTheWrongSegmentIsAFault() public {
        (bytes memory fills, L.Account[] memory n) = _two();
        (bytes[] memory w,, uint256[] memory p, uint64[] memory b) = _seg2();
        uint32[] memory f = new uint32[](1); // one segment, at 6000 (block 100): fill 1 (7000) is out of band
        bytes[] memory w0 = new bytes[](1);
        w0[0] = w[0];
        _proposeWith(fills, n, w0, f);
        uint256[] memory p0 = new uint256[](1);
        p0[0] = p[0];
        uint64[] memory b0 = new uint64[](1);
        b0[0] = b[0];
        vm.prank(watcher);
        D.challengeFill(fills, 1, f, p0, b0);
        assertEq(D.pending().at, 0, "discarded");
    }

    function test_segmentsMustMatchTheCommitment() public {
        (bytes memory fills, L.Account[] memory n) = _two();
        (bytes[] memory w, uint32[] memory f, uint256[] memory p, uint64[] memory b) = _seg2();
        _proposeWith(fills, n, w, f);
        p[0] = 7000; // a challenger can't substitute prices
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.BadProof.selector);
        D.challengeFill(fills, 0, f, p, b);
    }

    function test_segmentShapeIsChecked() public {
        (bytes memory fills, L.Account[] memory n) = _two();
        (bytes[] memory w,,,) = _seg2();
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        uint32[] memory bad = new uint32[](2);
        bad[0] = 1; // must start at fill 0
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingStorage.BadBatch.selector, "segments"));
        ch.propose{value: 1 ether}(w, bad, fills, u, proof, 0, 0, "");
        bad[0] = 0;
        bad[1] = 2; // past the last fill
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingStorage.BadBatch.selector, "segments"));
        ch.propose{value: 1 ether}(w, bad, fills, u, proof, 0, 0, "");
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingStorage.BadBatch.selector, "segments"));
        ch.propose{value: 1 ether}(w, _f0(), fills, u, proof, 0, 0, ""); // one start for two witnesses
    }
}

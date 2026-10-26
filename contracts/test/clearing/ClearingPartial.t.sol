// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClearingChannelBase} from "./ClearingChannel.t.sol";
import {ClearingRules as R} from "../../src/clearing/ClearingRules.sol";
import {ClearingLedger as L} from "../../src/clearing/ClearingLedger.sol";
import {ClearingStorage} from "../../src/clearing/ClearingStorage.sol";

/// Partial fills on L1: alice's order (sell 1 ETH, limit 6990 per ETH) is filled 0.4 by bob in
/// one batch and 0.6 by carol in the next. Every challenge fails on the honest batches; an
/// overfill, a fill below the limit price, and an order used after a newer nonce are faults.
contract ClearingPartialTest is ClearingChannelBase {
    O aliceSells; // nonce 1: sell 1 ETH for ≥ 6990

    function setUp() public override {
        super.setUp();
        aliceSells = _order(0, R.ETH, uint128(ETH1), 6990, 1);
    }

    function _noChallenge(bytes memory fills, L.Account[] memory n, uint256 accounts) internal {
        vm.startPrank(watcher);
        for (uint32 i; i < accounts; ++i) {
            vm.expectRevert(ClearingStorage.NotWrong.selector);
            D.challengeAccount(i, fin[i], _sib(_copyFin(), i), n[i], _sib(n, i), fills);
        }
        for (uint256 f; f < fills.length / L.FILL_BYTES; ++f) {
            vm.expectRevert(ClearingStorage.NotWrong.selector);
            D.challengeFill(fills, f, _f0(), _p0(), _b0());
        }
        vm.stopPrank();
    }

    /// Batch 1: 0.4 ETH to bob at 7000. Alice's order is 0.4 filled.
    function _first() internal view returns (bytes memory fills, L.Account[] memory n) {
        fills = _fill(aliceSells, _order(1, R.USD, 2800, 0.4 ether, 1), 0.4 ether, 2800);
        n = _copyFin();
        n[0] = L.Account(2.6 ether, 2800, 3 ether, 0, 0, 0, 1, 0, 0.4 ether);
        n[1] = L.Account(0.4 ether, 17_200, 0, 20_000, 0, 0, 1, 0, 0);
    }

    function test_aPartlyFilledOrderCompletesInALaterBatch() public {
        (bytes memory f1, L.Account[] memory n1) = _first();
        _propose(f1, n1, 0, 0, "");
        _noChallenge(f1, n1, 3);
        _finalize(n1);
        // Batch 2: the remaining 0.6 to carol, with the same signed order: alice's is complete.
        bytes memory f2 = _fill(aliceSells, _order(2, R.USD, 4200, 0.6 ether, 1), 0.6 ether, 4200);
        L.Account[] memory n2 = _copyFin();
        n2[0] = L.Account(2 ether, 7000, 3 ether, 0, 0, 0, 1, 0, 0);
        n2[2] = L.Account(1.6 ether, 5800, 1 ether, 10_000, 0, 0, 1, 0, 0);
        _propose(f2, n2, 0, 0, "");
        _noChallenge(f2, n2, 3);
        _finalize(n2);
    }

    /// The same order filled past its size (0.4 then 0.8 of 1 ETH): replaying alice through
    /// the batch fails, so her leaf is a provable fault whatever the proposer claims.
    function test_overfillingAnOrderIsAFault() public {
        (bytes memory f1, L.Account[] memory n1) = _first();
        _propose(f1, n1, 0, 0, "");
        _finalize(n1);
        bytes memory f2 = _fill(aliceSells, _order(2, R.USD, 5600, 0.8 ether, 1), 0.8 ether, 5600);
        L.Account[] memory n2 = _copyFin();
        n2[0] = L.Account(1.8 ether, 8400, 3 ether, 0, 0, 0, 1, 0, 0);
        n2[2] = L.Account(1.8 ether, 4400, 1 ether, 10_000, 0, 0, 1, 0, 0);
        _propose(f2, n2, 0, 0, "");
        _challengeAccount(0, n2, f2);
        assertEq(D.pending().at, 0, "discarded");
    }

    function _fillFault(bytes memory fills) internal {
        L.Account[] memory n = _copyFin();
        n[0].nonce = 1; // whatever the proposer claims: the fill itself is the fault
        _propose(fills, n, 0, 0, "");
        vm.prank(watcher);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0());
        assertEq(D.pending().at, 0, "discarded");
    }

    /// More ETH than alice's order sells (1.2 of 1): a fault of the fill itself.
    function test_aFillLargerThanAnOrderIsAFault() public {
        _fillFault(_fill(aliceSells, _order(1, R.USD, 8400, 1.2 ether, 1), 1.2 ether, 8400));
    }

    /// Bob's limit: at most 7000 per ETH (7000 for 1 ETH). Paying 7050 per ETH is in band but
    /// above his limit.
    function test_aUsdSellerAboveItsLimitIsAFault() public {
        _fillFault(_fill(aliceSells, _order(1, R.USD, 7000, 1 ether, 1), 0.4 ether, 2820));
    }

    /// Nothing for nothing: a zero fill would consume an order without a trade.
    function test_aZeroFillIsAFault() public {
        _fillFault(_fill(aliceSells, _order(1, R.USD, 7000, 1 ether, 1), 0, 0));
    }

    /// In band (6980 vs 7000) but under alice's limit price (6990 per ETH): a fill fault.
    function test_aPartialFillBelowTheLimitPriceIsAFault() public {
        bytes memory fills = _fill(aliceSells, _order(1, R.USD, 2792, 0.4 ether, 1), 0.4 ether, 2792);
        L.Account[] memory n = _copyFin();
        n[0] = L.Account(2.6 ether, 2792, 3 ether, 0, 0, 0, 1, 0, 0.4 ether);
        n[1] = L.Account(0.4 ether, 17_208, 0, 20_000, 0, 0, 1, 0, 0);
        _propose(fills, n, 0, 0, "");
        vm.prank(watcher);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0());
        assertEq(D.pending().at, 0, "discarded");
    }
}

/// ClearingLedger's partial-fill rule on its own.
contract ClearingLedgerPartialTest is Test {
    function _acc() internal pure returns (L.Account memory a) {
        a.eth = 5 ether;
        a.usd = 50_000;
    }

    function test_anOrderFillsInPartsUpToItsSizeThenIsComplete() public pure {
        L.Account memory a = _acc();
        assertTrue(L.applySide(a, R.ETH, 1 ether, 3, 0.25 ether, 1750));
        assertEq(a.filled, 0.25 ether);
        assertTrue(L.applySide(a, R.ETH, 1 ether, 3, 0.75 ether, 5250));
        assertEq(a.filled, 0, "complete");
        assertEq(a.nonce, 3);
        assertFalse(L.applySide(_copy(a), R.ETH, 1 ether, 3, 1, 7), "a complete order can't fill again");
    }

    function test_anOrderCantSellMoreThanItsSize() public pure {
        L.Account memory a = _acc();
        assertTrue(L.applySide(a, R.ETH, 1 ether, 3, 0.6 ether, 4200));
        assertFalse(L.applySide(a, R.ETH, 1 ether, 3, 0.6 ether, 4200));
    }

    function test_aNewerNonceEndsAPartlyFilledOrder() public pure {
        L.Account memory a = _acc();
        assertTrue(L.applySide(a, R.ETH, 1 ether, 3, 0.5 ether, 3500));
        assertTrue(L.applySide(a, R.USD, 7000, 4, 7000, 1 ether));
        assertEq(a.nonce, 4);
        assertFalse(L.applySide(_copy(a), R.ETH, 1 ether, 3, 0.1 ether, 700), "nonce 3's remainder is gone");
        assertFalse(L.applySide(_copy(_acc()), R.ETH, 1 ether, 0, 1, 7), "nonce 0 is never an order");
    }

    function _copy(L.Account memory a) internal pure returns (L.Account memory b) {
        b = L.Account(a.eth, a.usd, a.ethIn, a.usdIn, a.ethOut, a.usdOut, a.nonce, a.requests, a.filled);
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClearingRules as R} from "../../src/clearing/ClearingRules.sol";
import {ClearingSettlement, IERC20Min} from "../../src/clearing/ClearingSettlement.sol";
import {ClearingChecker} from "../../src/clearing/ClearingChecker.sol";
import {L1View} from "../../src/clearing/L1View.sol";
import {AnchorRegistry} from "../../src/AnchorRegistry.sol";
import {WitnessVerifier} from "../../src/verifiers/WitnessVerifier.sol";

/// A plain 6-decimal test token (no fee), used by forge and ts/e2e-clearing.ts.
contract TestUSD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// L1 settlement of clearing batches. The L1 price is the fixture's slot 0 at block 101
/// (7000), proven by fixtures/witnesses/read-and-split.json: "7000 USD units per ETH".
contract ClearingSettlementTest is Test {
    uint256 constant L1 = 11155111;
    uint256 constant ETH1 = 1 ether;

    ClearingSettlement st;
    ClearingChecker checker;
    AnchorRegistry anchors;
    WitnessVerifier wv;
    TestUSD usd;
    address op = address(0x0FE7);
    address watcher = address(0x5EE);
    address oracle;
    bytes raw1;
    bytes pkg1;
    string fx;

    uint256 aliceKey = 0xA11CE;
    uint256 bobKey = 0xB0B;
    uint256 carolKey = 0xCA201;
    address alice;
    address bob;
    address carol;

    function setUp() public {
        vm.chainId(L1);
        vm.warp(1_700_000_000);
        fx = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/read-and-split.json"));
        oracle = vm.parseJsonAddress(fx, ".fixture");
        raw1 = vm.parseJsonBytes(fx, ".h1.rawHeader");
        pkg1 = vm.parseJsonBytes(fx, ".h1.package");
        anchors = new AnchorRegistry();
        wv = new WitnessVerifier();
        checker = new ClearingChecker();
        usd = new TestUSD();
        vm.roll(200);
        vm.setBlockhash(101, keccak256(raw1));
        anchors.record(raw1);
        st = new ClearingSettlement(_config());
        vm.deal(op, 10 ether);
        vm.prank(op);
        st.postBond{value: 1 ether}();
        alice = vm.addr(aliceKey);
        bob = vm.addr(bobKey);
        carol = vm.addr(carolKey);
        _fund(alice, 3 ether, 0);
        _fund(bob, 0, 20_000);
        _fund(carol, 1 ether, 10_000);
    }

    function _config() internal view returns (ClearingSettlement.Config memory) {
        return ClearingSettlement.Config({
            operator: op,
            usd: IERC20Min(address(usd)),
            anchors: anchors,
            witnessVerifier: wv,
            priceFeed: oracle,
            priceSlot: bytes32(0),
            bandBps: 100,
            challengeWindow: 1 hours,
            maxAnchorAge: 256,
            minBond: 1 ether,
            checker: checker
        });
    }

    function _fund(address who, uint256 eth, uint256 dollars) internal {
        if (eth > 0) {
            vm.deal(who, eth);
            vm.prank(who);
            st.deposit{value: eth}(R.ETH, uint128(eth));
        }
        if (dollars > 0) {
            usd.mint(who, dollars);
            vm.startPrank(who);
            usd.approve(address(st), dollars);
            st.deposit(R.USD, uint128(dollars));
            vm.stopPrank();
        }
    }

    function _order(uint256 key, uint8 sell, uint128 sellAmt, uint128 buyAmt, uint64 nonce)
        internal
        view
        returns (R.Order memory o, bytes memory sig)
    {
        o = R.Order(vm.addr(key), sell, sellAmt, buyAmt, nonce, 1000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, R.orderDigest(st.domain(), o));
        sig = abi.encodePacked(r, s, v);
    }

    /// alice sells 1 ETH for ≥ 6990 USD; bob sells 7000 USD for ≥ 1 ETH: price 7000.
    function _fillAB(uint64 na, uint64 nb) internal view returns (R.Fill memory f) {
        (R.Order memory a, bytes memory sa) = _order(aliceKey, R.ETH, uint128(ETH1), 6990, na);
        (R.Order memory b, bytes memory sb) = _order(bobKey, R.USD, 7000, uint128(ETH1), nb);
        f = R.Fill(a, b, sa, sb);
    }

    function _one(R.Fill memory f) internal pure returns (R.Fill[] memory fs) {
        fs = new R.Fill[](1);
        fs[0] = f;
    }

    function _users2(address x, address y) internal pure returns (address[] memory u) {
        u = new address[](2);
        (u[0], u[1]) = x < y ? (x, y) : (y, x);
    }

    function _propose(uint64 batch, R.Fill[] memory fs, address[] memory users) internal {
        vm.prank(op);
        st.proposeBatch(batch, pkg1, abi.encode(fs), users, _at(fs, users));
    }

    /// Each fill's two traders as indices into `users`.
    function _at(R.Fill[] memory fs, address[] memory users) internal pure returns (uint16[] memory at) {
        at = new uint16[](2 * fs.length);
        for (uint256 f; f < fs.length; ++f) {
            for (uint16 i; i < users.length; ++i) {
                if (users[i] == fs[f].a.trader) at[2 * f] = i;
                if (users[i] == fs[f].b.trader) at[2 * f + 1] = i;
            }
        }
    }

    /// The effects as BatchProposed carries them (recomputed here independently).
    function _finalize(R.Fill[] memory fs, address[] memory users) internal {
        int256[] memory dEth = new int256[](users.length);
        int256[] memory dUsd = new int256[](users.length);
        uint64[] memory nonces = new uint64[](users.length);
        for (uint256 i; i < users.length; ++i) {
            (,,,, uint64 floor) = st.accounts(users[i]);
            nonces[i] = floor;
            for (uint256 f; f < fs.length; ++f) {
                R.Order[2] memory os = [fs[f].a, fs[f].b];
                for (uint256 s; s < 2; ++s) {
                    R.Order memory o = os[s];
                    R.Order memory other = os[1 - s];
                    if (o.trader != users[i]) continue;
                    nonces[i] = o.nonce;
                    int256 out = -int256(uint256(o.sellAmount));
                    int256 inn = int256(uint256(other.sellAmount));
                    if (o.sellToken == R.ETH) (dEth[i], dUsd[i]) = (dEth[i] + out, dUsd[i] + inn);
                    else (dUsd[i], dEth[i]) = (dUsd[i] + out, dEth[i] + inn);
                }
            }
        }
        vm.warp(block.timestamp + 1 hours);
        vm.prank(watcher); // anyone
        st.finalize(users, dEth, dUsd, nonces);
    }

    function _bal(address who) internal view returns (uint128 eth, uint128 dollars) {
        (eth, dollars,,,) = st.accounts(who);
    }

    function test_policyBounds() public {
        ClearingSettlement.Config memory c = _config();
        c.challengeWindow = 30 days + 1;
        assertFalse(_deploys(c), "window above 30 days");
        c = _config();
        c.maxAnchorAge = 8192;
        assertFalse(_deploys(c), "anchors older than EIP-2935 reaches");
        assertTrue(_deploys(_config()));
    }

    function _deploys(ClearingSettlement.Config memory c) internal returns (bool) {
        try new ClearingSettlement(c) returns (ClearingSettlement) {
            return true;
        } catch {
            return false;
        }
    }

    // ---- the normal path ----------------------------------------------------------------------

    function test_batchSettlesNetAndNextBatchContinues() public {
        R.Fill[] memory fs = _one(_fillAB(1, 1));
        address[] memory users = _users2(alice, bob);
        _propose(1, fs, users);
        _finalize(fs, users);
        (uint128 ae, uint128 au) = _bal(alice);
        (uint128 be, uint128 bu) = _bal(bob);
        assertEq(ae, 2 ether);
        assertEq(au, 7000);
        assertEq(be, 1 ether);
        assertEq(bu, 13_000);
        assertEq(st.finalizedBatches(), 1);
        // Batch 2 continues from the settled state (nonces move on).
        fs = _one(_fillAB(2, 2));
        _propose(2, fs, users);
        _finalize(fs, users);
        (ae,) = _bal(alice);
        assertEq(ae, 1 ether);
    }

    function test_nettingAcrossFills() public {
        // alice sells 1 ETH to bob for 7000, then buys 1 ETH back from carol for 7000: she
        // had no USD, so the second fill spends the first fill's proceeds (in order).
        R.Fill[] memory fs = new R.Fill[](2);
        fs[0] = _fillAB(1, 1);
        (R.Order memory a2, bytes memory sa2) = _order(aliceKey, R.USD, 7000, uint128(ETH1), 2);
        (R.Order memory c1, bytes memory sc1) = _order(carolKey, R.ETH, uint128(ETH1), 7000, 1);
        fs[1] = R.Fill(a2, c1, sa2, sc1);
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        _sort(users);
        // In the other order the purchase comes first and isn't covered: L1 refuses, as the
        // app would when executing it.
        R.Fill[] memory rev = new R.Fill[](2);
        {
            (R.Order memory buy, bytes memory sb) = _order(aliceKey, R.USD, 7000, uint128(ETH1), 1);
            (R.Order memory sell, bytes memory ss) = _order(aliceKey, R.ETH, uint128(ETH1), 6990, 2);
            rev[0] = R.Fill(buy, c1, sb, sc1);
            rev[1] = R.Fill(sell, fs[0].b, ss, fs[0].sigB);
        }
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingChecker.Undercollateralized.selector, 0, alice, R.USD));
        st.proposeBatch(1, pkg1, abi.encode(rev), users, _at(rev, users));
        _propose(1, fs, users);
        _finalize(fs, users);
        (uint128 ae, uint128 au) = _bal(alice);
        assertEq(ae, 3 ether);
        assertEq(au, 0);
        (uint128 ce, uint128 cu) = _bal(carol);
        assertEq(ce, 0);
        assertEq(cu, 17_000);
    }

    function _sort(address[] memory u) internal pure {
        for (uint256 i; i < u.length; ++i) {
            for (uint256 j = i + 1; j < u.length; ++j) {
                if (u[j] < u[i]) (u[i], u[j]) = (u[j], u[i]);
            }
        }
    }

    // ---- what L1 rejects outright ------------------------------------------------------------

    function test_nonceReuseAcrossBatchesRejected() public {
        R.Fill[] memory fs = _one(_fillAB(1, 1));
        address[] memory users = _users2(alice, bob);
        _propose(1, fs, users);
        _finalize(fs, users);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingChecker.BadNonce.selector, 0));
        st.proposeBatch(2, pkg1, abi.encode(fs), users, _at(fs, users)); // the same signed orders again
    }

    function test_duplicateFillInOneBatchRejected() public {
        R.Fill[] memory fs = new R.Fill[](2);
        fs[0] = _fillAB(1, 1);
        fs[1] = fs[0];
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingChecker.BadNonce.selector, 1));
        st.proposeBatch(1, pkg1, abi.encode(fs), _users2(alice, bob), _at(fs, _users2(alice, bob)));
    }

    function test_collateralCantBeUsedTwice() public {
        // carol has 1 ETH but sells 1 ETH in two different orders.
        R.Fill[] memory fs = new R.Fill[](2);
        (R.Order memory c1, bytes memory s1) = _order(carolKey, R.ETH, uint128(ETH1), 6990, 1);
        (R.Order memory b1, bytes memory t1) = _order(bobKey, R.USD, 7000, uint128(ETH1), 1);
        (R.Order memory c2, bytes memory s2) = _order(carolKey, R.ETH, uint128(ETH1), 6990, 2);
        (R.Order memory b2, bytes memory t2) = _order(bobKey, R.USD, 7000, uint128(ETH1), 2);
        fs[0] = R.Fill(c1, b1, s1, t1);
        fs[1] = R.Fill(c2, b2, s2, t2);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingChecker.Undercollateralized.selector, 1, carol, R.ETH));
        st.proposeBatch(1, pkg1, abi.encode(fs), _users2(bob, carol), _at(fs, _users2(bob, carol)));
    }

    function test_priceBandExpiryAndLimitsChecked() public {
        (R.Order memory a, bytes memory sa) = _order(aliceKey, R.ETH, uint128(ETH1), 6990, 1);
        (R.Order memory b, bytes memory sb) = _order(bobKey, R.USD, 7100, uint128(ETH1), 1); // 7100: +1.4%
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingChecker.BadBatch.selector, 0, R.Reject.OutsideBand));
        st.proposeBatch(
            1,
            pkg1,
            abi.encode(_one(R.Fill(a, b, sa, sb))),
            _users2(alice, bob),
            _at(_one(R.Fill(a, b, sa, sb)), _users2(alice, bob))
        );
        (b, sb) = _order(bobKey, R.USD, 6980, uint128(ETH1), 1); // below alice's 6990 limit
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingChecker.BadBatch.selector, 0, R.Reject.NotCrossing));
        st.proposeBatch(
            1,
            pkg1,
            abi.encode(_one(R.Fill(a, b, sa, sb))),
            _users2(alice, bob),
            _at(_one(R.Fill(a, b, sa, sb)), _users2(alice, bob))
        );
        a.expiry = 100; // the anchor is block 101
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, R.orderDigest(st.domain(), a));
        (b, sb) = _order(bobKey, R.USD, 7000, uint128(ETH1), 1);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingChecker.BadBatch.selector, 0, R.Reject.Expired));
        st.proposeBatch(
            1,
            pkg1,
            abi.encode(_one(R.Fill(a, b, abi.encodePacked(r, s, v), sb))),
            _users2(alice, bob),
            _at(_one(R.Fill(a, b, abi.encodePacked(r, s, v), sb)), _users2(alice, bob))
        );
    }

    function test_anchorMustBeRecordedRecentAndSingleRoot() public {
        R.Fill[] memory fs = _one(_fillAB(1, 1));
        address[] memory users = _users2(alice, bob);
        bytes memory pkg0 = vm.parseJsonBytes(fx, ".h0.package"); // block 100: never recorded
        vm.prank(op);
        vm.expectRevert(ClearingSettlement.BadAnchor.selector);
        st.proposeBatch(1, pkg0, abi.encode(fs), users, _at(fs, users));
        bytes memory mixed = vm.parseJsonBytes(fx, ".bad.mixedRoots");
        vm.prank(op);
        vm.expectRevert();
        st.proposeBatch(1, mixed, abi.encode(fs), users, _at(fs, users));
        vm.roll(101 + 257);
        vm.prank(op);
        vm.expectRevert(ClearingSettlement.BadAnchor.selector);
        st.proposeBatch(1, pkg1, abi.encode(fs), users, _at(fs, users));
    }

    function test_batchShapeChecked() public {
        R.Fill[] memory fs = _one(_fillAB(1, 1));
        address[] memory users = _users2(alice, bob);
        // Both sides selling ETH.
        (R.Order memory c, bytes memory sc) = _order(carolKey, R.ETH, uint128(ETH1), 6990, 1);
        R.Fill[] memory same = _one(R.Fill(fs[0].a, c, fs[0].sigA, sc));
        address[] memory ac = _users2(alice, carol);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingChecker.BadBatch.selector, 0, R.Reject.SameSide));
        st.proposeBatch(1, pkg1, abi.encode(same), ac, _at(same, ac));
        // The b side's collateral is checked too: bob sells more USD than he has.
        (R.Order memory big, bytes memory sbig) = _order(bobKey, R.USD, 21_000, 3 ether, 1);
        (R.Order memory a3, bytes memory sa3) = _order(aliceKey, R.ETH, 3 ether, 20_990, 1);
        R.Fill[] memory over = _one(R.Fill(a3, big, sa3, sbig));
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingChecker.Undercollateralized.selector, 0, bob, R.USD));
        st.proposeBatch(1, pkg1, abi.encode(over), users, _at(over, users));
        // Indices that don't name the fill's traders.
        uint16[] memory wrong = new uint16[](2);
        (wrong[0], wrong[1]) = (_at(fs, users)[1], _at(fs, users)[1]); // a's index points at bob
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingChecker.UnknownTrader.selector, 0));
        st.proposeBatch(1, pkg1, abi.encode(fs), users, wrong);
        // Users not strictly ascending.
        address[] memory unsorted = new address[](2);
        (unsorted[0], unsorted[1]) = (users[1], users[0]);
        vm.prank(op);
        vm.expectRevert(ClearingChecker.BadShape.selector);
        st.proposeBatch(1, pkg1, abi.encode(fs), unsorted, _at(fs, unsorted));
        // Batch numbers follow L1's.
        vm.prank(op);
        vm.expectRevert(ClearingSettlement.WrongState.selector);
        st.proposeBatch(2, pkg1, abi.encode(fs), users, _at(fs, users));
    }

    // ---- signatures: the one optimistic check -------------------------------------------------

    function test_forgedSignatureChallengedThenHonestBatch() public {
        R.Fill memory f = _fillAB(1, 1);
        (, bytes memory carolSig) = _order(carolKey, R.USD, 7000, uint128(ETH1), 1);
        f.sigB = carolSig; // bob's order, carol's signature
        R.Fill[] memory fs = _one(f);
        address[] memory users = _users2(alice, bob);
        _propose(1, fs, users);
        vm.expectRevert(ClearingSettlement.NotWrong.selector);
        st.challengeSignature(abi.encode(fs), 0, false); // alice's is fine
        R.Fill[] memory other = _one(_fillAB(1, 2));
        vm.expectRevert(ClearingSettlement.WrongState.selector);
        st.challengeSignature(abi.encode(other), 0, true); // not the published batch
        uint256 before = watcher.balance;
        vm.prank(watcher);
        st.challengeSignature(abi.encode(fs), 0, true);
        assertEq(watcher.balance - before, 1 ether);
        (,,,, bool live) = st.pending();
        assertFalse(live);
        vm.prank(op);
        st.postBond{value: 1 ether}();
        fs = _one(_fillAB(1, 1));
        _propose(1, fs, users);
        _finalize(fs, users);
    }

    function test_finalizeOnlyWithTheProposedEffectsAfterTheWindow() public {
        R.Fill[] memory fs = _one(_fillAB(1, 1));
        address[] memory users = _users2(alice, bob);
        _propose(1, fs, users);
        int256[] memory z = new int256[](2);
        uint64[] memory n = new uint64[](2);
        // The right effects, one second early.
        int256[] memory dEth = new int256[](2);
        int256[] memory dUsd = new int256[](2);
        uint64[] memory nn = new uint64[](2);
        for (uint256 i; i < 2; ++i) {
            bool isAlice = users[i] == alice;
            (dEth[i], dUsd[i], nn[i]) =
                isAlice ? (-int256(ETH1), int256(7000), uint64(1)) : (int256(ETH1), -int256(7000), uint64(1));
        }
        vm.warp(block.timestamp + 1 hours - 1);
        vm.expectRevert(ClearingSettlement.WrongState.selector);
        st.finalize(users, dEth, dUsd, nn);
        vm.warp(block.timestamp - (1 hours - 1));
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(ClearingSettlement.WrongState.selector);
        st.finalize(users, z, z, n); // not the proposed effects
    }

    // ---- withdrawals ------------------------------------------------------------------------

    /// alice reserves 1 of her 3 ETH and keeps trading with the rest; selling 3 is refused.
    function test_partialWithdrawalWhileTrading() public {
        vm.prank(alice);
        uint256 id = st.requestWithdraw(R.ETH, uint128(ETH1));
        _fund(bob, 0, 1000);
        (R.Order memory a, bytes memory sa) = _order(aliceKey, R.ETH, 3 ether, 20_990, 1);
        (R.Order memory b, bytes memory sb) = _order(bobKey, R.USD, 21_000, 3 ether, 1);
        R.Fill[] memory big = _one(R.Fill(a, b, sa, sb));
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingChecker.Undercollateralized.selector, 0, alice, R.ETH));
        st.proposeBatch(1, pkg1, abi.encode(big), _users2(alice, bob), _at(big, _users2(alice, bob))); // 3 ETH but 1 reserved
        // Requested before any batch: claimable now, while trading continues.
        uint256 before = alice.balance;
        st.claimWithdraw(id);
        assertEq(alice.balance - before, 1 ether);
        R.Fill[] memory fs = _one(_fillAB(1, 1));
        address[] memory users = _users2(alice, bob);
        _propose(1, fs, users);
        // A request made while a batch is pending waits for it, so the batch's counterparty
        // is never short.
        vm.prank(alice);
        uint256 id2 = st.requestWithdraw(R.ETH, uint128(ETH1));
        vm.expectRevert(ClearingSettlement.WrongState.selector);
        st.claimWithdraw(id2);
        _finalize(fs, users);
        before = alice.balance;
        st.claimWithdraw(id2);
        assertEq(alice.balance - before, 1 ether);
        (uint128 ae, uint128 au) = _bal(alice);
        assertEq(ae, 0);
        assertEq(au, 7000);
        (uint128 be,) = _bal(bob);
        assertEq(be, 1 ether, "bob got the ETH he bought");
    }

    /// The operator disappears with a batch pending: anyone finalizes it after the window,
    /// and every finalized balance is withdrawable without an operator.
    function test_operatorGoneEverythingWithdrawable() public {
        R.Fill[] memory fs = _one(_fillAB(1, 1));
        address[] memory users = _users2(alice, bob);
        _propose(1, fs, users);
        // From here on, no operator.
        _finalize(fs, users); // by the watcher
        vm.prank(alice);
        uint256 ia = st.requestWithdraw(R.ETH, 2 ether);
        vm.prank(alice);
        uint256 iu = st.requestWithdraw(R.USD, 7000);
        vm.prank(bob);
        uint256 ib = st.requestWithdraw(R.ETH, 1 ether);
        st.claimWithdraw(ia);
        st.claimWithdraw(iu);
        st.claimWithdraw(ib);
        assertEq(alice.balance, 2 ether);
        assertEq(usd.balanceOf(alice), 7000);
        assertEq(bob.balance, 1 ether);
    }
}

/// L1View: the app's read-only window on L1 fails closed.
contract L1ViewTest is Test {
    L1View view_;
    string fx;
    address oracle;

    function setUp() public {
        view_ = new L1View(11155111);
        fx = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/read-and-split.json"));
        oracle = vm.parseJsonAddress(fx, ".fixture");
    }

    function test_pinThenRead() public {
        bytes32 id = view_.pin(vm.parseJsonBytes(fx, ".h1.rawHeader"), vm.parseJsonBytes(fx, ".h1.package"));
        assertEq(view_.read(id, oracle, bytes32(0)), 7000);
        bytes32 id0 = view_.pin(vm.parseJsonBytes(fx, ".h0.rawHeader"), vm.parseJsonBytes(fx, ".h0.package"));
        assertEq(view_.read(id0, oracle, bytes32(0)), 6000, "another snapshot, its own value");
        assertEq(view_.read(id, oracle, bytes32(0)), 7000, "the first is unchanged");
    }

    function test_missingStateFailsClosed() public {
        bytes32 id = view_.pin(vm.parseJsonBytes(fx, ".h1.rawHeader"), vm.parseJsonBytes(fx, ".h1.package"));
        vm.expectRevert(abi.encodeWithSelector(L1View.NotWitnessed.selector, id, oracle, bytes32(uint256(1))));
        view_.read(id, oracle, bytes32(uint256(1)));
        vm.expectRevert();
        view_.read(bytes32(uint256(123)), oracle, bytes32(0)); // never pinned
    }

    function test_badWitnessesFailClosed() public {
        bytes memory raw1 = vm.parseJsonBytes(fx, ".h1.rawHeader");
        string[4] memory bad = ["mixedRoots", "wrongValue", "presentClaimedAbsent", "unsorted"];
        for (uint256 i; i < bad.length; ++i) {
            (bool ok,) = address(view_)
                .call(abi.encodeCall(view_.pin, (raw1, vm.parseJsonBytes(fx, string.concat(".bad.", bad[i])))));
            assertFalse(ok, bad[i]);
        }
        // A header that isn't the package's anchor.
        vm.expectRevert(L1View.HeaderMismatch.selector);
        view_.pin(vm.parseJsonBytes(fx, ".h0.rawHeader"), vm.parseJsonBytes(fx, ".h1.package"));
        // Another chain's anchor.
        L1View other = new L1View(1);
        vm.expectRevert(L1View.WrongChain.selector);
        other.pin(raw1, vm.parseJsonBytes(fx, ".h1.package"));
    }
}

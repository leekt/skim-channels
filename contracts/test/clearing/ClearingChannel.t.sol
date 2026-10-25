// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tree} from "../predict/PredictionBase.sol";
import {TestUSD, SlotPriceAdapter} from "./Clearing.t.sol";
import {ChainlinkAdapter} from "../../src/clearing/ChainlinkAdapter.sol";
import {ClearingRules as R} from "../../src/clearing/ClearingRules.sol";
import {ClearingLedger as L} from "../../src/clearing/ClearingLedger.sol";
import {ClearingChannel} from "../../src/clearing/ClearingChannel.sol";
import {ClearingDisputes} from "../../src/clearing/ClearingDisputes.sol";
import {ClearingStorage, IERC20Lite} from "../../src/clearing/ClearingStorage.sol";
import {ClearingCodec} from "../../src/clearing/ClearingCodec.sol";
import {Clone1167} from "../../src/clearing/Clone1167.sol";
import {AnchorRegistry} from "../../src/AnchorRegistry.sol";

/// Shared setup for the v2 clearing channel: L1 price 7000 (fixture slot 0 at block 101),
/// three users, and a model of the finalized account tree.
/// A proposer that can't receive ETH (its bond refund must not block anything).
contract Unpayable {
    function propose(ClearingChannel ch, bytes calldata data) external payable {
        (bool ok, bytes memory err) = address(ch).call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }

    function withdrawBond(ClearingChannel ch) external {
        ch.withdrawBond();
    }
}

abstract contract ClearingChannelBase is Test {
    uint256 constant ETH1 = 1 ether;
    ClearingChannel ch;
    ClearingDisputes D; // the channel's address, typed for its delegatecalled half
    ClearingCodec codec;
    AnchorRegistry anchors;
    SlotPriceAdapter priceAdapter;
    TestUSD usd;
    address op = address(0x0FE7);
    address watcher = address(0x5EE);
    address oracle;
    bytes pkg1;

    uint256[3] keys = [uint256(0xA11CE), 0xB0B, 0xCA201];
    address[3] who;
    L.Account[] fin; // finalized leaves by index
    address vaultAddr; // none unless a suite sets one up (_beforeChannel)
    ClearingChannel impl; // the shared session implementation; sessions are clones of it

    function setUp() public virtual {
        vm.chainId(11155111);
        vm.warp(1_700_000_000);
        string memory fx = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/read-and-split.json"));
        oracle = vm.parseJsonAddress(fx, ".fixture");
        bytes memory raw1 = vm.parseJsonBytes(fx, ".h1.rawHeader");
        pkg1 = vm.parseJsonBytes(fx, ".h1.package");
        anchors = new AnchorRegistry();
        priceAdapter = new SlotPriceAdapter(oracle, bytes32(0));
        codec = new ClearingCodec();
        usd = new TestUSD();
        vm.roll(200);
        vm.setBlockhash(101, keccak256(raw1));
        anchors.record(raw1);
        impl = new ClearingChannel(new ClearingDisputes());
        _beforeChannel();
        ch = _open(_config());
        D = ClearingDisputes(address(ch));
        vm.deal(op, 100 ether);
        vm.deal(watcher, 10 ether);
        for (uint256 i; i < 3; ++i) {
            who[i] = vm.addr(keys[i]);
            fin.push();
        }
        _fund(0, 3 ether, 0);
        _fund(1, 0, 20_000);
        _fund(2, 1 ether, 10_000);
    }

    function _beforeChannel() internal virtual {}

    /// A session: a minimal proxy of the implementation, initialized with `c`.
    function _open(ClearingStorage.Config memory c) internal virtual returns (ClearingChannel s) {
        s = ClearingChannel(Clone1167.clone(address(impl)));
        s.initialize(c);
    }

    function tryOpen(ClearingStorage.Config memory c) external {
        _open(c);
    }

    // One oracle segment: the fixture's price (7000) at its anchor (block 101).
    function _w() internal view returns (bytes[] memory w) {
        w = new bytes[](1);
        w[0] = pkg1;
    }

    function _w(bytes memory p) internal pure returns (bytes[] memory w) {
        w = new bytes[](1);
        w[0] = p;
    }

    /// One execution segment: every fill at block 101, priced by the one witness.
    function _s0() internal pure returns (ClearingStorage.SegmentRef[] memory s) {
        s = new ClearingStorage.SegmentRef[](1);
        s[0] = ClearingStorage.SegmentRef(0, 0, 101);
    }

    /// A batch without fills: no segments, no price witness.
    function _nw() internal pure returns (bytes[] memory) {}

    function _ns() internal pure returns (ClearingStorage.SegmentRef[] memory) {}

    function _f0() internal pure returns (uint32[] memory f) {
        f = new uint32[](1);
    }

    function _p0() internal pure returns (uint256[] memory p) {
        p = new uint256[](1);
        p[0] = 7000;
    }

    function _b0() internal pure returns (uint64[] memory b) {
        b = new uint64[](1);
        b[0] = 101;
    }

    function _config() internal view returns (ClearingStorage.Config memory) {
        return ClearingStorage.Config({
            operator: op,
            usd: IERC20Lite(address(usd)),
            anchors: anchors,
            codec: codec,
            priceAdapter: priceAdapter,
            bandBps: 100,
            challengeWindow: 1 hours,
            forceDelay: 1 days,
            maxAnchorAge: 256,
            minBond: 1 ether,
            takeoverDelay: 2 days,
            appChainId: 7001,
            vault: vaultAddr,
            sessionId: 1
        });
    }

    function _fund(uint256 i, uint256 eth, uint256 dollars) internal {
        if (eth > 0) {
            vm.deal(who[i], eth);
            vm.prank(who[i]);
            ch.deposit{value: eth}(R.ETH, uint128(eth));
        }
        if (dollars > 0) {
            usd.mint(who[i], dollars);
            vm.startPrank(who[i]);
            usd.approve(address(ch), dollars);
            ch.deposit(R.USD, uint128(dollars));
            vm.stopPrank();
        }
    }

    // ---- orders and fills ----------------------------------------------------------------

    struct O {
        uint32 idx;
        R.Order o;
        bytes sig;
    }

    function _order(uint32 i, uint8 sell, uint128 sellAmt, uint128 buyAmt, uint64 nonce)
        internal
        view
        returns (O memory x)
    {
        return _order(i, sell, sellAmt, buyAmt, nonce, 1000);
    }

    function _order(uint32 i, uint8 sell, uint128 sellAmt, uint128 buyAmt, uint64 nonce, uint64 expiry)
        internal
        view
        returns (O memory x)
    {
        x.idx = i;
        x.o = R.Order(who[i], sell, sellAmt, buyAmt, nonce, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], R.orderDigest(ch.domain(), x.o));
        x.sig = abi.encodePacked(r, s, v);
    }

    function _fill(O memory a, O memory b) internal pure returns (bytes memory) {
        return bytes.concat(L.encodeOrder(a.idx, a.o), a.sig, L.encodeOrder(b.idx, b.o), b.sig);
    }

    /// alice (0) sells 1 ETH for ≥ 6990; bob (1) sells 7000 USD for ≥ 1 ETH.
    function _ab(uint64 na, uint64 nb) internal view returns (bytes memory) {
        return _fill(_order(0, R.ETH, uint128(ETH1), 6990, na), _order(1, R.USD, 7000, uint128(ETH1), nb));
    }

    // ---- the account tree ------------------------------------------------------------------

    function _hashes(L.Account[] memory ls) internal pure returns (bytes32[] memory h) {
        h = new bytes32[](ls.length);
        for (uint256 i; i < ls.length; ++i) {
            h[i] = L.leafHash(ls[i]);
        }
    }

    function _copyFin() internal view returns (L.Account[] memory c) {
        c = new L.Account[](fin.length);
        for (uint256 i; i < fin.length; ++i) {
            c[i] = fin[i];
        }
    }

    function _updates(L.Account[] memory next) internal view returns (bytes memory u, bytes32[] memory proof) {
        bytes32[] memory h = _hashes(_copyFin());
        uint256 n;
        for (uint256 i; i < next.length; ++i) {
            if (L.leafHash(next[i]) != h[i]) n++;
        }
        uint256[] memory idx = new uint256[](n);
        uint256 k;
        for (uint256 i; i < next.length; ++i) {
            if (L.leafHash(next[i]) == h[i]) continue;
            u = bytes.concat(u, abi.encodePacked(uint32(i)), L.encodeLeaf(fin[i]), L.encodeLeaf(next[i]));
            idx[k++] = i;
        }
        if (n != 0) proof = Tree.multiproof(h, idx);
    }

    function _propose(
        bytes memory fills,
        L.Account[] memory next,
        uint64 reqCursor,
        uint64 forcedCursor,
        bytes memory statuses
    ) internal {
        (bytes memory u, bytes32[] memory proof) = _updates(next);
        vm.prank(op);
        if (fills.length == 0) {
            ch.propose{value: 1 ether}(_nw(), _ns(), fills, u, proof, reqCursor, forcedCursor, statuses);
        } else {
            ch.propose{value: 1 ether}(_w(), _s0(), fills, u, proof, reqCursor, forcedCursor, statuses);
        }
    }

    function _finalize(L.Account[] memory next) internal {
        vm.warp(block.timestamp + 1 hours);
        ch.finalize();
        for (uint256 i; i < next.length; ++i) {
            fin[i] = next[i];
        }
        (bytes32 root,,,,,,) = D.state();
        assertEq(root, Tree.root(_hashes(_copyFin())), "model root");
    }

    function _sib(L.Account[] memory ls, uint256 i) internal pure returns (bytes32[16] memory) {
        return Tree.siblings(_hashes(ls), i);
    }

    function _challengeAccount(uint32 i, L.Account[] memory proposed, bytes memory fills) internal {
        vm.prank(watcher);
        D.challengeAccount(i, fin[i], _sib(_copyFin(), i), proposed[i], _sib(proposed, i), fills);
    }

    /// Batch 1, honest: alice sells 1 ETH to bob at 7000.
    function _batch1() internal view returns (bytes memory fills, L.Account[] memory n) {
        fills = _ab(1, 1);
        n = _copyFin();
        n[0] = L.Account(2 ether, 7000, 3 ether, 0, 0, 0, 1, 0);
        n[1] = L.Account(uint128(ETH1), 13_000, 0, 20_000, 0, 0, 1, 0);
    }
}

contract ClearingChannelTest is ClearingChannelBase {
    // ---- mutation gaps (2026-10-25): every rule is a fault on L1 ----------------------------------

    /// A fill whose orders both sell ETH (in band, "crossing" by amounts) is a fault: SameSide.
    function test_aSameSideFillIsAFault() public {
        bytes memory fills = _fill(_order(0, R.ETH, uint128(ETH1), 7000, 1), _order(2, R.ETH, 7000, uint128(ETH1), 1));
        _propose(fills, _copyFin(), 0, 0, "");
        vm.prank(watcher);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0());
        assertEq(D.pending().at, 0, "discarded");
    }

    /// In band (6990 vs 7000), but bob gives less than alice's limit: a fault, NotCrossing.
    function test_aFillBelowALimitIsAFault() public {
        bytes memory fills = _fill(_order(0, R.ETH, uint128(ETH1), 7000, 1), _order(1, R.USD, 6990, uint128(ETH1), 1));
        _propose(fills, _copyFin(), 0, 0, "");
        vm.prank(watcher);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0());
        assertEq(D.pending().at, 0, "discarded");
    }

    // ---- the normal path ----------------------------------------------------------------------

    function test_honestBatchSurvivesEveryChallengeAndSettles() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0());
        for (uint32 i; i < 3; ++i) {
            vm.expectRevert(ClearingStorage.NotWrong.selector);
            _challengeAccount(i, n, fills); // carol's untouched leaf too
        }
        _finalize(n);
        assertEq(D.bondCredit(op), 1 ether, "bond credited back");
        uint256 before = op.balance;
        vm.prank(op);
        ch.withdrawBond();
        assertEq(op.balance - before, 1 ether, "and withdrawn");
        // Batch 2 continues from the committed state.
        L.Account[] memory m = _copyFin();
        m[0] = L.Account(1 ether, 14_000, 3 ether, 0, 0, 0, 2, 0);
        m[1] = L.Account(2 ether, 6000, 0, 20_000, 0, 0, 2, 0);
        _propose(_ab(2, 2), m, 0, 0, "");
        _finalize(m);
    }

    function test_withdrawalServedBeforeFillsThenClaimed() public {
        vm.prank(who[0]);
        ch.requestWithdraw(R.ETH, 2 ether); // alice keeps 1 ETH to trade
        (bytes memory fills,) = _batch1();
        L.Account[] memory n = _copyFin();
        n[0] = L.Account(0, 7000, 3 ether, 0, 2 ether, 0, 1, 1); // 3 − 2 withdrawn − 1 sold
        n[1] = L.Account(uint128(ETH1), 13_000, 0, 20_000, 0, 0, 1, 0);
        _propose(fills, n, 1, 0, "");
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        _challengeAccount(0, n, fills);
        _finalize(n);
        uint256 before = who[0].balance;
        D.claim(0, fin[0], _sib(_copyFin(), 0));
        assertEq(who[0].balance - before, 2 ether);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        D.claim(0, fin[0], _sib(_copyFin(), 0));
    }

    // ---- what a watcher catches -------------------------------------------------------------

    function test_forgedSignature() public {
        O memory a = _order(0, R.ETH, uint128(ETH1), 6990, 1);
        O memory b = _order(1, R.USD, 7000, uint128(ETH1), 1);
        b.sig = _order(2, R.USD, 7000, uint128(ETH1), 1).sig; // carol signed bob's order
        bytes memory fills = _fill(a, b);
        (, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        vm.prank(watcher);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0());
        assertEq(D.bondCredit(watcher), 1 ether, "bond to the challenger");
        assertEq(D.pending().at, 0, "batch discarded");
    }

    function test_outOfBandFill() public {
        bytes memory fills = _fill(_order(0, R.ETH, uint128(ETH1), 6990, 1), _order(1, R.USD, 7200, uint128(ETH1), 1));
        L.Account[] memory n = _copyFin();
        n[0] = L.Account(2 ether, 7200, 3 ether, 0, 0, 0, 1, 0);
        n[1] = L.Account(uint128(ETH1), 12_800, 0, 20_000, 0, 0, 1, 0);
        _propose(fills, n, 0, 0, "");
        vm.prank(watcher);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0());
    }

    function test_overpaidAccount() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        n[0].usd += 1;
        _propose(fills, n, 0, 0, "");
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        _challengeAccount(1, n, fills);
        _challengeAccount(0, n, fills);
    }

    function test_omittedTrader() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        n[1] = fin[1]; // bob's leaf untouched
        _propose(fills, n, 0, 0, "");
        _challengeAccount(1, n, fills);
    }

    function test_nonceReuseAcrossBatches() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        _finalize(n);
        // The same signed orders again in batch 2.
        L.Account[] memory m = _copyFin();
        m[0] = L.Account(1 ether, 14_000, 3 ether, 0, 0, 0, 1, 0);
        m[1] = L.Account(2 ether, 6000, 0, 20_000, 0, 0, 1, 0);
        _propose(fills, m, 0, 0, "");
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0()); // the fill itself is valid
        _challengeAccount(0, m, fills); // but alice's nonce was spent
    }

    function test_collateralUsedTwice() public {
        // carol has 1 ETH and sells it twice.
        bytes memory fills = bytes.concat(
            _fill(_order(2, R.ETH, uint128(ETH1), 6990, 1), _order(1, R.USD, 7000, uint128(ETH1), 1)),
            _fill(_order(2, R.ETH, uint128(ETH1), 6990, 2), _order(1, R.USD, 7000, uint128(ETH1), 2))
        );
        L.Account[] memory n = _copyFin();
        n[1] = L.Account(2 ether, 6000, 0, 20_000, 0, 0, 2, 0);
        n[2] = L.Account(0, 24_000, 1 ether, 10_000, 0, 0, 2, 0); // whatever it claims
        _propose(fills, n, 0, 0, "");
        _challengeAccount(2, n, fills);
    }

    function test_requestRules() public {
        vm.prank(who[0]);
        ch.requestWithdraw(R.ETH, 1 ether);
        (bytes memory fills, L.Account[] memory n) = _batch1();
        // Cursor past the request but the leaf skips it.
        _propose(fills, n, 1, 0, "");
        _challengeAccount(0, n, fills);
        // Applying it without the deposits it covers.
        n[0] = L.Account(0, 7000, 0, 0, 0, 0, 1, 1);
        _propose(fills, n, 1, 0, "");
        _challengeAccount(0, n, fills);
        // Claiming deposits L1 doesn't have.
        (fills, n) = _batch1();
        n[0].ethIn = 4 ether;
        n[0].eth = 3 ether;
        _propose(fills, n, 0, 0, "");
        _challengeAccount(0, n, fills);
    }

    function test_proposalShape() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        vm.deal(who[2], 2 ether);
        vm.prank(who[2]);
        vm.expectRevert(ClearingStorage.WrongState.selector); // not the operator, no takeover yet
        ch.propose{value: 1 ether}(_w(), _s0(), fills, u, proof, 0, 0, "");
        vm.prank(op);
        vm.expectRevert(ClearingStorage.WrongState.selector); // no bond
        ch.propose(_w(), _s0(), fills, u, proof, 0, 0, "");
        u[30] = bytes1(uint8(u[30]) ^ 1); // an old leaf that isn't finalized
        vm.prank(op);
        vm.expectRevert(ClearingStorage.BadProof.selector);
        ch.propose{value: 1 ether}(_w(), _s0(), fills, u, proof, 0, 0, "");
        (u, proof) = _updates(n);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingStorage.BadBatch.selector, "reqCursor"));
        ch.propose{value: 1 ether}(_w(), _s0(), fills, u, proof, 1, 0, "");
        vm.roll(101 + 257);
        vm.prank(op);
        vm.expectRevert(ChainlinkAdapter.BadAnchor.selector);
        ch.propose{value: 1 ether}(_w(), _s0(), fills, u, proof, 0, 0, "");
    }

    function test_finalizeAfterTheWindowOnly() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        vm.warp(block.timestamp + 1 hours - 1);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.finalize();
        vm.warp(block.timestamp + 1);
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0()); // and challenges end exactly then
        ch.finalize();
    }

    // ---- edges pinned by mutation checks ------------------------------------------------------

    function test_depositsCannotGoBackwards() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        _finalize(n);
        L.Account[] memory m = _copyFin();
        m[0] = L.Account(1 ether, 7000, 2 ether, 0, 0, 0, 1, 0); // "un-applies" 1 ETH of deposits
        _propose("", m, 0, 0, "");
        _challengeAccount(0, m, "");
    }

    function test_requestLargerThanBalancePaysWhatIsFree() public {
        vm.prank(who[2]);
        ch.requestWithdraw(R.ETH, 5 ether); // carol has 1
        L.Account[] memory n = _copyFin();
        n[2] = L.Account(0, 10_000, 1 ether, 10_000, 1 ether, 0, 0, 1);
        _propose("", n, 1, 0, "");
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        _challengeAccount(2, n, "");
    }

    function test_requestCannotBeConsumedWithoutItsDeposits() public {
        vm.prank(who[2]);
        ch.requestWithdraw(R.ETH, 1 ether);
        L.Account[] memory n = _copyFin();
        n[2] = L.Account(0, 0, 0, 0, 0, 0, 0, 1); // consumed, nothing paid, deposits left unapplied
        _propose("", n, 1, 0, "");
        _challengeAccount(2, n, "");
    }

    function test_requestBeyondTheCursorIsAFault() public {
        vm.prank(who[2]);
        ch.requestWithdraw(R.ETH, 0.5 ether);
        vm.prank(who[2]);
        ch.requestWithdraw(R.ETH, 0.5 ether);
        L.Account[] memory n = _copyFin();
        n[2] = L.Account(0, 10_000, 1 ether, 10_000, 1 ether, 0, 0, 2); // applies both
        _propose("", n, 1, 0, ""); // but the cursor covers only the first
        _challengeAccount(2, n, "");
    }

    /// The replay stops at the first impossible step; a leaf equal to that partial state is
    /// still a fault (carol's second sale is unpaid while bob is credited).
    function test_partialReplayIsNotAcceptance() public {
        bytes memory fills = bytes.concat(
            _fill(_order(2, R.ETH, uint128(ETH1), 6990, 1), _order(1, R.USD, 7000, uint128(ETH1), 1)),
            _fill(_order(2, R.ETH, uint128(ETH1), 6990, 2), _order(1, R.USD, 7000, uint128(ETH1), 2))
        );
        L.Account[] memory n = _copyFin();
        n[1] = L.Account(2 ether, 6000, 0, 20_000, 0, 0, 2, 0);
        n[2] = L.Account(0, 17_000, 1 ether, 10_000, 0, 0, 2, 0); // the state where replay stops
        _propose(fills, n, 0, 0, "");
        _challengeAccount(2, n, fills);
    }

    function test_falseEvidenceCannotConvictAnHonestBatch() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        L.Account memory fake = L.Account(9 ether, 0, 9 ether, 0, 0, 0, 0, 0);
        bytes memory other = _ab(9, 9); // (signs through ch.domain(): before expectRevert)
        vm.startPrank(watcher);
        vm.expectRevert(ClearingStorage.BadProof.selector);
        D.challengeAccount(0, fake, _sib(_copyFin(), 0), n[0], _sib(n, 0), fills);
        vm.expectRevert(ClearingStorage.BadProof.selector);
        D.challengeAccount(0, fin[0], _sib(_copyFin(), 0), fake, _sib(n, 0), fills);
        vm.expectRevert(ClearingStorage.BadProof.selector);
        D.challengeFill(other, 0, _f0(), _p0(), _b0()); // not the published fills
        vm.stopPrank();
    }

    function test_unknownTraderIndexIsAFault() public {
        O memory a = _order(0, R.ETH, uint128(ETH1), 6990, 1);
        O memory b = _order(1, R.USD, 7000, uint128(ETH1), 1);
        b.idx = 7;
        bytes memory fills = _fill(a, b);
        (, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        vm.prank(watcher);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0());
    }

    function test_indexBeyondUsersRejected() public {
        fin.push();
        L.Account[] memory n = _copyFin();
        n[3] = L.Account(1, 0, 0, 0, 0, 0, 0, 0);
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        fin.pop();
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(ClearingStorage.BadBatch.selector, "index"));
        ch.propose{value: 1 ether}(_nw(), _ns(), "", u, proof, 0, 0, "");
    }

    function test_unservedRequestFreezesServedOneDoesNot() public {
        vm.prank(who[2]);
        ch.requestWithdraw(R.ETH, 1 ether);
        L.Account[] memory n = _copyFin();
        n[2] = L.Account(0, 10_000, 1 ether, 10_000, 1 ether, 0, 0, 1);
        _propose("", n, 1, 0, "");
        _finalize(n);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(ClearingStorage.NotOverdue.selector);
        D.freeze(); // served: the finalized cursor moved past it
        vm.prank(who[0]);
        ch.requestWithdraw(R.USD, 1);
        vm.warp(block.timestamp + 1 days);
        D.freeze(); // alice's isn't served: the session closes
        // Redemptions pay once.
        uint256 e0 = who[2].balance;
        D.redeem(2, fin[2], _sib(_copyFin(), 2), false);
        assertEq(who[2].balance - e0, 1 ether, "carol's released 1 ETH");
        vm.expectRevert(ClearingStorage.WrongState.selector);
        D.redeem(2, fin[2], _sib(_copyFin(), 2), false);
    }

    function test_badAnchorRejected() public {
        string memory fx = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/read-and-split.json"));
        (bytes memory fills, L.Account[] memory n) = _batch1();
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        vm.prank(op);
        vm.expectRevert(ChainlinkAdapter.BadAnchor.selector); // block 100: never recorded
        ch.propose{value: 1 ether}(_w(vm.parseJsonBytes(fx, ".h0.package")), _s0(), fills, u, proof, 0, 0, "");
    }

    // ---- forced orders ------------------------------------------------------------------------

    function test_forcedOrderPublishedAsResting() public {
        O memory c = _order(2, R.ETH, uint128(ETH1), 6990, 1);
        vm.prank(who[2]);
        ch.forceOrder(c.o);
        (bytes memory fills, L.Account[] memory n) = _batch1();
        vm.expectEmit(true, false, false, false, address(ch));
        emit ClearingStorage.ForcedRested(0);
        _propose(fills, n, 0, 1, abi.encodePacked(uint16(0)));
        _finalize(n);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(ClearingStorage.NotOverdue.selector);
        D.freeze();
    }

    function test_forcedOrderFilledStatusChecked() public {
        O memory a = _order(0, R.ETH, uint128(ETH1), 6990, 1);
        vm.prank(who[0]);
        ch.forceOrder(a.o);
        (bytes memory fills, L.Account[] memory n) = _batch1();
        vm.expectRevert(abi.encodeWithSelector(ClearingStorage.BadBatch.selector, "forcedStatus"));
        _propose(fills, n, 0, 1, abi.encodePacked(uint16(2))); // fill 0, side b: that's bob's
        _propose(fills, n, 0, 1, abi.encodePacked(uint16(1))); // fill 0, side a: alice's ✓
    }

    function test_forcedOrderIgnoredFreezesAndEveryoneExits() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        _finalize(n);
        O memory c = _order(2, R.ETH, uint128(ETH1), 6990, 1);
        vm.prank(who[2]);
        ch.forceOrder(c.o);
        // The operator keeps proposing without serving it.
        L.Account[] memory m = _copyFin();
        m[0] = L.Account(1 ether, 14_000, 3 ether, 0, 0, 0, 2, 0);
        m[1] = L.Account(2 ether, 6000, 0, 20_000, 0, 0, 2, 0);
        _propose(_ab(2, 2), m, 0, 0, "");
        vm.expectRevert(ClearingStorage.NotOverdue.selector);
        D.freeze();
        vm.warp(block.timestamp + 1 days);
        D.freeze();
        // Batch 1's bond (finalized, not yet withdrawn) plus the frozen batch's.
        assertEq(D.bondCredit(op), 2 ether, "a frozen batch's bond is credited back to its proposer");
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.finalize();
        uint256[3] memory wantEth = [uint256(2 ether), 1 ether, 1 ether];
        uint256[3] memory wantUsd = [uint256(7000), 13_000, 10_000];
        for (uint32 i; i < 3; ++i) {
            uint256 e0 = who[i].balance;
            uint256 u0 = usd.balanceOf(who[i]);
            D.redeem(i, fin[i], _sib(_copyFin(), i), false);
            assertEq(who[i].balance - e0, wantEth[i]);
            assertEq(usd.balanceOf(who[i]) - u0, wantUsd[i]);
        }
        assertEq(address(ch).balance, 2 ether, "only the credited bonds are left");
        assertEq(usd.balanceOf(address(ch)), 0);
    }

    /// Regression: a proposer that rejects ETH used to make finalize (and freeze) revert,
    /// stalling settlement. Its bond is now credited; withdrawing is its own problem.
    function test_proposerThatRejectsEthBlocksNothing() public {
        Unpayable p = new Unpayable();
        vm.warp(block.timestamp + 2 days + 1); // takeover
        (bytes memory fills, L.Account[] memory n) = _batch1();
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        p.propose{value: 1 ether}(ch, abi.encodeCall(ch.propose, (_w(), _s0(), fills, u, proof, 0, 0, "")));
        _finalize(n);
        assertEq(D.bondCredit(address(p)), 1 ether);
        vm.expectRevert(ClearingStorage.TransferFailed.selector);
        p.withdrawBond(ch);
        // Its next proposal is discarded by a freeze: that works too.
        vm.prank(who[0]);
        ch.requestWithdraw(R.ETH, 1);
        vm.warp(block.timestamp + 2 days + 1);
        L.Account[] memory m = _copyFin();
        (u, proof) = _updates(m);
        p.propose{value: 1 ether}(ch, abi.encodeCall(ch.propose, (_nw(), _ns(), "", u, proof, 0, 0, "")));
        D.freeze();
        assertEq(D.bondCredit(address(p)), 2 ether);
    }

    /// The trader's own L1 transaction authorizes a forced order: nobody else can post one.
    function test_forceOrderOnlyFromTheTrader() public {
        O memory c = _order(2, R.ETH, uint128(ETH1), 6990, 1);
        vm.prank(who[1]);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.forceOrder(c.o);
    }

    /// A forced order needs no typed signature in a fill (its trader authorized it on L1); any
    /// other order with an empty signature is a fault.
    function test_forcedOrderNeedsNoTypedSignature() public {
        O memory a = _order(0, R.ETH, uint128(ETH1), 6990, 1);
        vm.prank(who[0]);
        ch.forceOrder(a.o);
        O memory b = _order(1, R.USD, 7000, uint128(ETH1), 1);
        a.sig = new bytes(65);
        bytes memory fills = _fill(a, b);
        (, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 1, abi.encodePacked(uint16(1)));
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0());
        vm.warp(block.timestamp + 1 hours);
        ch.finalize();
    }

    function test_unsignedNonForcedOrderIsAFault() public {
        O memory a = _order(0, R.ETH, uint128(ETH1), 6990, 1);
        O memory b = _order(1, R.USD, 7000, uint128(ETH1), 1);
        b.sig = new bytes(65);
        bytes memory fills = _fill(a, b);
        (, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        vm.prank(watcher);
        D.challengeFill(fills, 0, _f0(), _p0(), _b0());
    }

    /// Orders are signed in the app network's domain (what a wallet connected to it can sign),
    /// salted with the session id.
    function test_domainIsTheAppChainAndSession() public view {
        assertEq(ch.domain(), R.domainSeparator(7001, address(ch), bytes32(uint256(1))));
    }

    // ---- handover -----------------------------------------------------------------------------

    function test_anyoneProposesAfterTheTakeoverDelay() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        vm.deal(who[2], 2 ether);
        vm.warp(block.timestamp + 2 days);
        vm.prank(who[2]);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.propose{value: 1 ether}(_w(), _s0(), fills, u, proof, 0, 0, "");
        vm.warp(block.timestamp + 1);
        vm.prank(who[2]);
        ch.propose{value: 1 ether}(_w(), _s0(), fills, u, proof, 0, 0, "");
        assertEq(D.pending().proposer, who[2]);
    }

    function test_disputesOnlyViaChannel() public {
        ClearingDisputes direct = ch.disputes();
        vm.expectRevert(ClearingStorage.WrongState.selector);
        direct.freeze();
    }

    function test_policyFloors() public {
        ClearingStorage.Config memory c = _config();
        c.challengeWindow = 1 hours - 1;
        assertFalse(_deploys(c));
        c = _config();
        c.forceDelay = 1 days - 1;
        assertFalse(_deploys(c));
        c = _config();
        c.challengeWindow = 13 hours; // two windows must fit in the forced delay
        assertFalse(_deploys(c));
        c = _config();
        c.forceDelay = 60 days + 1; // upper bounds keep at + window far from overflow
        assertFalse(_deploys(c));
        c = _config();
        c.takeoverDelay = 60 days + 1;
        assertFalse(_deploys(c));
        c = _config();
        c.maxAnchorAge = 8192;
        assertFalse(_deploys(c));
        c = _config();
        c.bandBps = 10_001;
        assertFalse(_deploys(c));
        assertTrue(_deploys(_config()));
    }

    function _deploys(ClearingStorage.Config memory c) internal returns (bool) {
        try this.tryOpen(c) {
            return true;
        } catch {
            return false;
        }
    }

    function test_aSessionInitializesOnce() public {
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.initialize(_config());
    }
}

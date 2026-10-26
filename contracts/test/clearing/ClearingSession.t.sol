// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingChannelBase, Unpayable} from "./ClearingChannel.t.sol";
import {Tree} from "../predict/PredictionBase.sol";
import {ClearingRules as R} from "../../src/clearing/ClearingRules.sol";
import {ClearingLedger as L} from "../../src/clearing/ClearingLedger.sol";
import {ClearingChannel} from "../../src/clearing/ClearingChannel.sol";
import {ClearingDisputes} from "../../src/clearing/ClearingDisputes.sol";
import {ClearingStorage, IERC20Lite} from "../../src/clearing/ClearingStorage.sol";
import {ClearingVault} from "../../src/clearing/ClearingVault.sol";

/// Session lifecycle (Active → Closing → Closed), redemption, the vault, rollover between
/// sessions, and signatures bound to their session.
/// Accepts any depositFor (not a session).
contract AcceptsAnything {
    function depositFor(address, uint8, uint128) external payable {}
}

contract ClearingSessionTest is ClearingChannelBase {
    ClearingVault vault;

    function _beforeChannel() internal override {
        vault = new ClearingVault(op, IERC20Lite(address(usd)));
        vaultAddr = address(vault);
    }

    /// Sessions of this app are opened by its vault (the owner registers their configuration).
    function _open(ClearingStorage.Config memory c) internal override returns (ClearingChannel s) {
        vm.prank(op);
        s = ClearingChannel(vault.openSession(address(impl), c));
    }

    function _phase(ClearingDisputes d) internal view returns (ClearingStorage.Phase p) {
        (,,,,, p,) = d.state();
    }

    /// The app's next session (the vault assigns id `id`).
    function _session(uint64 id) internal returns (ClearingChannel s) {
        s = _open(_config());
        assertEq(vault.sessionIdOf(address(s)), id);
    }

    function _closeNow() internal {
        vm.startPrank(op);
        ch.beginClose();
        ch.close();
        vm.stopPrank();
    }

    // ---- lifecycle ------------------------------------------------------------------------------

    function test_closingFixesTheCutoffAndClosedIsTerminal() public {
        vm.prank(who[0]);
        ch.requestWithdraw(R.ETH, 1 ether); // before the cutoff
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.WrongState.selector); // not the operator, not abandoned
        ch.beginClose();
        vm.prank(op);
        ch.beginClose();
        assertEq(uint8(_phase(D)), uint8(ClearingStorage.Phase.Closing));

        // No new obligations.
        vm.deal(who[2], 1 ether);
        vm.prank(who[2]);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.deposit{value: 1 ether}(R.ETH, 1 ether);
        vm.prank(who[1]);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.requestWithdraw(R.USD, 1);
        O memory c = _order(2, R.ETH, uint128(ETH1), 6990, 1);
        vm.prank(who[2]);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.forceOrder(c.o);

        // The operator settles what it executed before the cutoff, request included.
        (bytes memory fills,) = _batch1();
        L.Account[] memory n = _copyFin();
        n[0] = L.Account(1 ether, 7000, 3 ether, 0, 1 ether, 0, 1, 1, 0);
        n[1] = L.Account(uint128(ETH1), 13_000, 0, 20_000, 0, 0, 1, 0, 0);
        _propose(fills, n, 1, 0, "");
        vm.prank(op);
        vm.expectRevert(ClearingStorage.WrongState.selector); // something is pending
        ch.close();
        _finalize(n);
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.WrongState.selector); // only the operator, this early
        ch.close();
        vm.prank(op);
        ch.close();
        assertEq(uint8(_phase(D)), uint8(ClearingStorage.Phase.Closed));

        // Terminal: no proposal (not even a takeover), no reopening, no new deposits.
        vm.warp(block.timestamp + 30 days);
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        vm.deal(watcher, 5 ether);
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.propose{value: 1 ether}(_nw(), _ns(), "", u, proof, 1, 0, "");
        vm.prank(op);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.beginClose();
        vm.prank(op);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.close();
        vm.expectRevert(ClearingStorage.WrongState.selector);
        D.freeze();
        vm.expectRevert(ClearingStorage.WrongState.selector);
        D.claim(0, fin[0], _sib(_copyFin(), 0)); // after close: redeem
    }

    function test_takeoverCantProposeWhileClosing() public {
        vm.prank(op);
        ch.beginClose();
        vm.warp(block.timestamp + 3 days);
        (bytes memory fills, L.Account[] memory n) = _batch1();
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.propose{value: 1 ether}(_w(), _s0(), fills, u, proof, 0, 0, "");
    }

    /// Proposals during Closing stop at the deadline after which anyone may close.
    function test_closingCantBeHeldOpenByProposals() public {
        vm.prank(op);
        ch.beginClose();
        (bytes memory fills, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        _finalize(n);
        vm.warp(block.timestamp + 2 days);
        L.Account[] memory m = _copyFin();
        (bytes memory u, bytes32[] memory proof) = _updates(m);
        vm.prank(op);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.propose{value: 1 ether}(_nw(), _ns(), "", u, proof, 0, 0, "");
        vm.prank(watcher);
        ch.close();
        assertEq(uint8(_phase(D)), uint8(ClearingStorage.Phase.Closed));
    }

    /// The operator is gone: anyone closes an idle session, then everyone redeems.
    function test_abandonedSessionClosesWithoutTheOperator() public {
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.beginClose();
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(watcher);
        ch.beginClose();
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.close();
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(watcher);
        ch.close();
        uint256 e0 = who[0].balance;
        D.redeem(0, fin[0], _sib(_copyFin(), 0), false); // nothing was ever applied: all deposits
        assertEq(who[0].balance - e0, 3 ether);
    }

    /// Queued withdrawal requests and deposits no batch applied are both covered at close.
    function test_redeemCoversQueuedRequestsAndUnappliedDeposits() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        _finalize(n);
        vm.prank(who[0]);
        ch.requestWithdraw(R.ETH, 1 ether); // never served
        _fund(2, 2 ether, 0); // never applied
        _closeNow();
        uint256[3] memory wantEth = [uint256(2 ether), 1 ether, 3 ether];
        uint256[3] memory wantUsd = [uint256(7000), 13_000, 10_000];
        for (uint32 i; i < 3; ++i) {
            uint256 e0 = who[i].balance;
            uint256 u0 = usd.balanceOf(who[i]);
            D.redeem(i, fin[i], _sib(_copyFin(), i), false);
            assertEq(who[i].balance - e0, wantEth[i]);
            assertEq(usd.balanceOf(who[i]) - u0, wantUsd[i]);
        }
        assertEq(address(ch).balance, 1 ether, "only the operator's credited bond");
        assertEq(usd.balanceOf(address(ch)), 0);
    }

    function test_claimBeforeCloseIsDeductedFromRedemption() public {
        vm.prank(who[0]);
        ch.requestWithdraw(R.ETH, 2 ether);
        L.Account[] memory n = _copyFin();
        n[0] = L.Account(1 ether, 0, 3 ether, 0, 2 ether, 0, 0, 1, 0);
        _propose("", n, 1, 0, "");
        _finalize(n);
        D.claim(0, fin[0], _sib(_copyFin(), 0));
        _closeNow();
        uint256 e0 = who[0].balance;
        D.redeem(0, fin[0], _sib(_copyFin(), 0), false);
        assertEq(who[0].balance - e0, 1 ether, "3 deposited - 2 already claimed");
    }

    // ---- bonds are pulled ------------------------------------------------------------------------

    function test_proposerThatRejectsEthBlocksNothing() public {
        Unpayable p = new Unpayable();
        vm.deal(address(p), 0);
        vm.deal(address(this), 1 ether);
        vm.warp(block.timestamp + 2 days + 1); // takeover
        (bytes memory fills, L.Account[] memory n) = _batch1();
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        p.propose{value: 1 ether}(ch, abi.encodeCall(ch.propose, (_w(), _s0(), fills, u, proof, 0, 0, "")));
        _finalize(n); // the refund can't be pushed to it: finalize still works
        assertEq(D.bondCredit(address(p)), 1 ether);
        vm.expectRevert(ClearingStorage.TransferFailed.selector);
        p.withdrawBond(ch); // its own problem, nobody else's
        _closeNow();
        D.redeem(0, fin[0], _sib(_copyFin(), 0), false);
    }

    // ---- the vault and rollover ------------------------------------------------------------------

    function test_rolloverIntoTheVaultThenFundTheNextSession() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        _finalize(n);
        _closeNow();
        // Only alice can send her entitlement to the vault.
        bytes32[16] memory sib = _sib(_copyFin(), 0);
        vm.prank(op);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        D.redeem(0, fin[0], sib, true);
        vm.prank(who[0]);
        D.redeem(0, fin[0], sib, true);
        ClearingVault.Totals memory f = vault.free(who[0]);
        assertEq(f.eth, 2 ether);
        assertEq(f.usd, 7000);
        // Session 2: registered, then funded by alice herself.
        ClearingChannel s2 = _session(2);
        vm.prank(op);
        vm.expectRevert(ClearingVault.WrongState.selector); // the operator has no free balance of hers
        vault.fund(address(s2), R.ETH, 1 ether);
        vm.startPrank(who[0]);
        vault.fund(address(s2), R.ETH, 1 ether);
        vault.fund(address(s2), R.USD, 7000);
        vm.stopPrank();
        assertEq(s2.cumIn(0).eth, 1 ether);
        assertEq(s2.cumIn(0).usd, 7000);
        assertEq(s2.users(0), who[0]);
        assertEq(vault.free(who[0]).eth, 1 ether);
        // The rest goes back to her wallet.
        uint256 e0 = who[0].balance;
        vm.prank(who[0]);
        vault.withdraw(R.ETH, 1 ether);
        assertEq(who[0].balance - e0, 1 ether);
    }

    function test_noDoubleRedemptionEitherWay() public {
        _closeNow();
        bytes32[16] memory sib0 = _sib(_copyFin(), 0);
        vm.prank(who[0]);
        D.redeem(0, fin[0], sib0, true);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        D.redeem(0, fin[0], sib0, false); // already rolled over
        bytes32[16] memory sib1 = _sib(_copyFin(), 1);
        D.redeem(1, fin[1], sib1, false);
        vm.prank(who[1]);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        D.redeem(1, fin[1], sib1, true); // already paid to the wallet
        assertEq(vault.free(who[1]).usd, 0);
    }

    function test_openingSessionsAndCreditRules() public {
        // Only the app's owner opens sessions; ids are consecutive; the vault sets its own
        // address, token and the id whatever the config says.
        ClearingStorage.Config memory c = _config();
        c.vault = watcher;
        c.sessionId = 77;
        vm.prank(watcher);
        vm.expectRevert(ClearingVault.WrongState.selector);
        vault.openSession(address(impl), c);
        vm.prank(op);
        ClearingChannel s2 = ClearingChannel(vault.openSession(address(impl), c));
        ClearingStorage.Config memory got = ClearingDisputes(address(s2)).config();
        assertEq(got.vault, address(vault));
        assertEq(got.sessionId, 2);
        assertEq(address(got.usd), address(usd));
        assertEq(address(s2).code.length, 45, "a session is a 45-byte minimal proxy");
        vm.deal(watcher, 1 ether);
        vm.prank(watcher);
        vm.expectRevert(ClearingVault.WrongState.selector); // credits only from sessions
        vault.credit{value: 1 ether}(watcher, 0);
        vm.prank(address(ch));
        vm.expectRevert(ClearingVault.WrongState.selector); // USD must already be there
        vault.credit(who[0], 1);
    }

    // ---- signatures belong to their session ------------------------------------------------------

    function test_orderSignedForSession1IsAFaultInSession2() public {
        ClearingChannel s2 = _session(2);
        assertTrue(s2.domain() != ch.domain());
        // Same app, same users, same orders: signed in session 1's domain.
        bytes memory fills = _ab(1, 1);
        for (uint256 i; i < 3; ++i) {
            vm.deal(who[i], 1 ether);
            vm.prank(who[i]);
            s2.deposit{value: 1 ether}(R.ETH, 1 ether);
        }
        ClearingDisputes d2 = ClearingDisputes(address(s2));
        L.Account[] memory empty = new L.Account[](3);
        L.Account[] memory n = new L.Account[](3);
        n[0] = L.Account(0, 7000, 1 ether, 0, 0, 0, 1, 0, 0);
        n[1] = L.Account(2 ether, 0, 1 ether, 0, 0, 0, 1, 0, 0);
        bytes memory u = bytes.concat(
            abi.encodePacked(uint32(0)),
            L.encodeLeaf(empty[0]),
            L.encodeLeaf(n[0]),
            abi.encodePacked(uint32(1)),
            L.encodeLeaf(empty[1]),
            L.encodeLeaf(n[1])
        );
        uint256[] memory idx = new uint256[](2);
        idx[1] = 1;
        bytes32[] memory proof = Tree.multiproof(new bytes32[](3), idx);
        vm.prank(op);
        s2.propose{value: 1 ether}(_w(), _s0(), fills, u, proof, 0, 0, "");
        // Valid signatures, in session 1's domain: in session 2 they are a provable fault.
        vm.prank(watcher);
        d2.challengeFill(fills, 0, _f0(), _p0(), _b0());
        assertEq(d2.pending().at, 0, "discarded");
        assertEq(d2.bondCredit(watcher), 1 ether);
        // The same orders signed for session 2 are fine there.
        bytes memory again =
            _fill(_signedIn(s2, 0, R.ETH, uint128(ETH1), 6990, 1), _signedIn(s2, 1, R.USD, 7000, uint128(ETH1), 1));
        vm.prank(op);
        s2.propose{value: 1 ether}(_w(), _s0(), again, u, proof, 0, 0, "");
        vm.prank(watcher);
        vm.expectRevert(ClearingStorage.NotWrong.selector);
        d2.challengeFill(again, 0, _f0(), _p0(), _b0());
    }

    function _signedIn(ClearingChannel s, uint32 i, uint8 sell, uint128 sellAmt, uint128 buyAmt, uint64 nonce)
        internal
        view
        returns (O memory x)
    {
        x.idx = i;
        x.o = R.Order(who[i], sell, sellAmt, buyAmt, nonce, 1000);
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(keys[i], R.orderDigest(s.domain(), x.o));
        x.sig = abi.encodePacked(r, ss, v);
    }

    // ---- recovery data ---------------------------------------------------------------------------

    /// Chunk `c` of size 2^k of the final leaves, with the path above it.
    function _chunk(L.Account[] memory ls, uint256 start, uint256 size)
        internal
        pure
        returns (bytes memory leaves, bytes32[] memory path)
    {
        for (uint256 i = start; i < start + size; ++i) {
            leaves = bytes.concat(leaves, L.encodeLeaf(i < ls.length ? ls[i] : L.Account(0, 0, 0, 0, 0, 0, 0, 0, 0)));
        }
        bytes32[16] memory sib = Tree.siblings(_hashes(ls), start);
        uint256 k;
        while ((1 << k) < size) ++k;
        path = new bytes32[](16 - k);
        for (uint256 j; j < path.length; ++j) {
            path[j] = sib[j + k];
        }
    }

    function test_publishFinalChunksMustBePartOfTheFinalRoot() public {
        (bytes memory fills, L.Account[] memory n) = _batch1();
        _propose(fills, n, 0, 0, "");
        _finalize(n);
        (bytes memory all4, bytes32[] memory path4) = _chunk(_copyFin(), 0, 4);
        vm.expectRevert(ClearingStorage.WrongState.selector); // not closed yet
        D.publishFinal(0, all4, path4);
        _closeNow();
        bytes memory wrong = bytes.concat(all4);
        wrong[0] = 0x01;
        vm.expectRevert(abi.encodeWithSignature("BadProof()"));
        D.publishFinal(0, wrong, path4);
        D.publishFinal(0, all4, path4); // the whole session as one chunk
        (bytes memory first2, bytes32[] memory p2) = _chunk(_copyFin(), 0, 2);
        D.publishFinal(0, first2, p2); // or chunk by chunk
        (bytes memory next2, bytes32[] memory q2) = _chunk(_copyFin(), 2, 2);
        D.publishFinal(2, next2, q2);
        vm.expectRevert(abi.encodeWithSignature("BadProof()")); // a chunk must be aligned
        D.publishFinal(1, first2, p2);
    }

    // ---- mutation gaps (2026-10-25) --------------------------------------------------------------

    function test_redeemOnlyAfterCloseAndOnlyAFinalLeaf() public {
        bytes32[16] memory sib = _sib(_copyFin(), 0);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        D.redeem(0, fin[0], sib, false); // still active
        _closeNow();
        L.Account memory forged = fin[0];
        forged.eth += 1 ether;
        vm.expectRevert(ClearingStorage.BadProof.selector);
        D.redeem(0, forged, sib, false); // not the final leaf
        D.redeem(0, fin[0], sib, false);
    }

    function test_onlyTheVaultDepositsForAUserAndOnlyIntoItsSessions() public {
        vm.deal(op, 1 ether);
        vm.prank(op);
        vm.expectRevert(ClearingStorage.WrongState.selector);
        ch.depositFor{value: 1 ether}(who[0], R.ETH, 1 ether); // not the vault
        _closeNow();
        vm.prank(who[0]);
        D.redeem(0, fin[0], _sib(_copyFin(), 0), true); // alice has free balance in the vault now
        // A contract that takes any deposit (what a phished user might be pointed at): the vault
        // only funds sessions it opened.
        AcceptsAnything sink = new AcceptsAnything();
        vm.prank(who[0]);
        vm.expectRevert(ClearingVault.WrongState.selector);
        vault.fund(address(sink), R.ETH, 1 ether);
        assertEq(address(sink).balance, 0);
    }
}

/// Cost of publishing a closed session's final leaves (optional), by session size.
contract ClearingPublishCost is ClearingChannelBase {
    function _many(uint256 n) internal returns (ClearingChannel s, bytes memory leaves) {
        ClearingStorage.Config memory c = _config();
        c.sessionId = 9;
        s = _open(c);
        for (uint256 i; i < n; ++i) {
            address u = address(uint160(0x10000 + i));
            vm.deal(u, 1);
            vm.prank(u);
            s.deposit{value: 1}(R.ETH, 1);
        }
        leaves = new bytes(n * L.LEAF_BYTES); // nothing applied: empty leaves (one allocation)
        vm.startPrank(op);
        s.beginClose();
        s.close();
        vm.stopPrank();
    }

    function test_publishFinalCost() public {
        uint256[4] memory sizes = [uint256(16), 128, 512, 1024];
        for (uint256 k; k < sizes.length; ++k) {
            (ClearingChannel s, bytes memory leaves) = _many(sizes[k]);
            uint256 lg;
            while ((1 << lg) < sizes[k]) ++lg;
            bytes32[] memory path = new bytes32[](16 - lg);
            bytes32 z;
            for (uint256 j; j < lg; ++j) {
                z = keccak256(abi.encodePacked(z, z));
            }
            for (uint256 j; j < path.length; ++j) {
                path[j] = z; // empty subtrees beside the chunk
                z = keccak256(abi.encodePacked(z, z));
            }
            uint256 g = gasleft();
            ClearingDisputes(address(s)).publishFinal(0, leaves, path);
            g -= gasleft();
            emit log_named_uint(string.concat("users ", vm.toString(sizes[k]), ": execution gas"), g);
            emit log_named_uint(string.concat("users ", vm.toString(sizes[k]), ": calldata bytes"), leaves.length);
            emit log_named_uint(
                string.concat("users ", vm.toString(sizes[k]), ": calldata gas, all non-zero"), leaves.length * 16
            );
        }
    }
}

/// What opening a session costs: a clone plus its configuration. The session's code (the two
/// implementations) is deployed once per app; on Sepolia under Amsterdam pricing deploying it per
/// session cost ~35.7M gas (docs/experiments/sessions.md).
contract ClearingOpenCost is ClearingChannelBase {
    function test_openSessionCost() public {
        uint256 g = gasleft();
        ClearingChannel s = _open(_config());
        g -= gasleft();
        emit log_named_uint("open a session (clone + initialize): gas", g);
        emit log_named_uint("open a session: runtime bytes deployed", address(s).code.length);
        emit log_named_uint(
            "session code, deployed once per app: runtime bytes",
            address(impl).code.length + address(impl.disputes()).code.length
        );
    }
}

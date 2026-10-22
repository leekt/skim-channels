// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {PredictionBase, Tree} from "./PredictionBase.sol";
import {PredictionChannel} from "../../src/predict/PredictionChannel.sol";
import {PredictionTypes as T} from "../../src/predict/PredictionTypes.sol";
import {PredictionRules} from "../../src/predict/PredictionRules.sol";
import {SparseTree16} from "../../src/predict/SparseTree16.sol";

/// The prediction-round path: commit → resolve → proposal → challenge → operator-free exit.
contract PredictionChannelTest is PredictionBase {
    uint32 constant A = 0;
    uint32 constant B = 1;
    uint32 constant C = 2;

    function setUp() public override {
        super.setUp();
        _addUsers(3, 10 ether);
    }

    /// A: UP 2 (ticket 2, after staking 1 twice), B: DOWN 3, C: UP 1. Oracle 7000 ≥ strike
    /// 6500: UP. Pot 6, UP total 3: A 10 − 2 + 4 = 12, B 10 − 3 = 7, C 10 − 1 + 2 = 11.
    function _roundOneEntries(uint256 r) internal view returns (Tk[] memory e) {
        e = new Tk[](3);
        e[0] = Tk(A, _ticket(keys[A], r, 2 ether, 0, 2));
        e[1] = Tk(B, _ticket(keys[B], r, 0, 3 ether, 1));
        e[2] = Tk(C, _ticket(keys[C], r, 1 ether, 0, 1));
    }

    function _roundOneResult() internal pure returns (T.Leaf[] memory n) {
        n = new T.Leaf[](3);
        n[A] = T.Leaf(12 ether, 0, 10 ether, 0);
        n[B] = T.Leaf(7 ether, 0, 10 ether, 0);
        n[C] = T.Leaf(11 ether, 0, 10 ether, 0);
    }

    function _committedAndResolved() internal returns (uint256 r, Tk[] memory e) {
        r = _open(6500);
        e = _roundOneEntries(r);
        _commit(r, e);
        _recordResolution();
        ch.resolve(r, package1);
    }

    function _challengeUpdate(uint32 idx, T.Leaf memory newLeaf, T.Leaf[] memory proposed, Tk[] memory e) internal {
        vm.prank(watcher);
        ch.challengeUpdate(
            idx,
            abi.encode(
                fin[idx],
                _finSiblings(idx),
                newLeaf,
                Tree.siblings(_hashes(proposed), idx),
                _partOf(e, idx),
                Tree.siblings(_partLeaves(e), idx)
            )
        );
    }

    // ---- the happy path ---------------------------------------------------------------------

    function test_round_settles_and_withdraws() public {
        (uint256 r, Tk[] memory e) = _committedAndResolved();
        (,,,,,,,,,, bytes32 partRoot, uint256 up, uint256 down) = ch.rounds(r);
        assertEq(partRoot, Tree.root(_partLeaves(e)), "L1 built the participation root");
        assertEq(up, 3 ether);
        assertEq(down, 3 ether);
        (, uint8 outcome,,,,,,,,,,,) = ch.rounds(r);
        assertEq(outcome, T.UP);

        T.Leaf[] memory n = _roundOneResult();
        _propose(r, n);
        // An honest proposal survives every challenge.
        for (uint32 i; i < 3; ++i) {
            vm.expectRevert(PredictionChannel.NotWrong.selector);
            _challengeUpdate(i, n[i], n, e);
        }
        _finalize(n);
        (PredictionChannel.Status st,,,,,,,,,,,,) = ch.rounds(r);
        assertEq(uint8(st), uint8(PredictionChannel.Status.Settled));

        // A withdraws everything.
        vm.prank(who[A]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[A] = T.Leaf(0, 12 ether, 10 ether, 1);
        _propose(0, w);
        _finalize(w);
        uint256 before = who[A].balance;
        ch.claim(A, fin[A], _finSiblings(A));
        assertEq(who[A].balance - before, 12 ether);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.claim(A, fin[A], _finSiblings(A));
    }

    function test_deposit_after_commit_is_not_stakeable_but_is_applied() public {
        uint256 r = _open(6500);
        Tk[] memory e = _roundOneEntries(r);
        _commit(r, e);
        vm.deal(who[B], 5 ether);
        vm.prank(who[B]);
        ch.deposit{value: 5 ether}();
        assertEq(ch.depositsAtCommit(B, r), 10 ether);
        _recordResolution();
        ch.resolve(r, package1);
        T.Leaf[] memory n = _roundOneResult();
        n[B] = T.Leaf(12 ether, 0, 15 ether, 0); // 15 − 3
        _propose(r, n);
        vm.expectRevert(PredictionChannel.NotWrong.selector);
        _challengeUpdate(B, n[B], n, e);
        // Applying only the deposits from before the commit is also correct.
        vm.warp(block.timestamp + WINDOW);
        ch.finalize();
    }

    // ---- commit challenges (before the outcome exists) -------------------------------------

    function test_commit_challenge_bad_signature_voids_and_slashes() public {
        uint256 r = _open(6500);
        Tk[] memory e = _roundOneEntries(r);
        e[1].t = _ticket(keys[C], r, 0, 3 ether, 1); // C signed B's ticket
        _commit(r, e);
        uint256 before = watcher.balance;
        vm.prank(watcher);
        ch.challengeCommit(r, B, abi.encode(e[1].t), Tree.siblings(_partLeaves(e), B), fin[B], _finSiblings(B));
        assertEq(watcher.balance - before, BOND, "bond to challenger");
        (PredictionChannel.Status st,,,,,,,,,,,,) = ch.rounds(r);
        assertEq(uint8(st), uint8(PredictionChannel.Status.Void));
        // The void round settles with balances unchanged; the operator must rebond first.
        T.Leaf[] memory n = _copyFin();
        vm.expectRevert(PredictionChannel.WrongState.selector);
        _propose(r, n);
        vm.prank(op);
        ch.postBond{value: BOND}();
        _propose(r, n);
        _finalize(n);
    }

    function test_commit_challenge_overdraft() public {
        uint256 r = _open(6500);
        Tk[] memory e = _roundOneEntries(r);
        e[1].t = _ticket(keys[B], r, 0, 11 ether, 1); // has 10
        _commit(r, e);
        vm.prank(watcher);
        ch.challengeCommit(r, B, abi.encode(e[1].t), Tree.siblings(_partLeaves(e), B), fin[B], _finSiblings(B));
        assertEq(ch.bond(), 0);
    }

    function test_commit_challenge_rejects_valid_late_or_unproven() public {
        uint256 r = _open(6500);
        Tk[] memory e = _roundOneEntries(r);
        _commit(r, e);
        bytes32[16] memory ps = Tree.siblings(_partLeaves(e), B);
        bytes memory ticket = abi.encode(e[1].t);
        vm.expectRevert(PredictionChannel.NotWrong.selector);
        ch.challengeCommit(r, B, ticket, ps, fin[B], _finSiblings(B));
        // A ticket that isn't the committed one (an earlier, smaller one B also signed).
        bytes memory other = abi.encode(_ticket(keys[B], r, 0, 2 ether, 0));
        vm.expectRevert(PredictionRules.BadProof.selector);
        ch.challengeCommit(r, B, other, ps, fin[B], _finSiblings(B));
        // A balance leaf that isn't finalized.
        vm.expectRevert(PredictionRules.BadProof.selector);
        ch.challengeCommit(r, B, ticket, ps, T.Leaf(1, 0, 0, 0), _finSiblings(B));
        vm.roll(CHALLENGE_END);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.challengeCommit(r, B, ticket, ps, fin[B], _finSiblings(B));
    }

    function test_commit_rules() public {
        uint256 r = _open(6500);
        Tk[] memory e = _roundOneEntries(r);
        vm.expectRevert(PredictionChannel.NotOperator.selector);
        ch.commit(r, _pack(e));
        // Unsorted indices.
        Tk[] memory bad = new Tk[](2);
        (bad[0], bad[1]) = (e[1], e[0]);
        vm.prank(op);
        vm.expectRevert(SparseTree16.NotSorted.selector);
        ch.commit(r, _pack(bad));
        // Unregistered user index.
        bad = new Tk[](1);
        bad[0] = Tk(3, e[0].t);
        vm.prank(op);
        vm.expectRevert(PredictionChannel.BadUpdate.selector);
        ch.commit(r, _pack(bad));
        // An empty ticket.
        bad[0] = Tk(A, _ticket(keys[A], r, 0, 0, 1));
        vm.prank(op);
        vm.expectRevert(PredictionRules.BadTicket.selector);
        ch.commit(r, _pack(bad));
        // Truncated encoding.
        bytes memory packed = _pack(e);
        assembly {
            mstore(packed, sub(mload(packed), 1))
        }
        vm.prank(op);
        vm.expectRevert(PredictionRules.BadEncoding.selector);
        ch.commit(r, packed);
        vm.roll(DEADLINE + 1);
        vm.prank(op);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.commit(r, _pack(e));
    }

    // ---- resolution -------------------------------------------------------------------------

    function test_resolve_needs_the_recorded_resolution_block() public {
        uint256 r = _open(6500);
        _commit(r, _roundOneEntries(r));
        vm.roll(200);
        vm.expectRevert(); // not recorded
        ch.resolve(r, package1);
        _recordResolution();
        ch.resolve(r, package1);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.resolve(r, package1);
    }

    function test_no_winning_stake_refunds() public {
        uint256 r = _open(8000); // 7000 < 8000: DOWN; only B bet DOWN... make nobody bet DOWN
        Tk[] memory e = new Tk[](1);
        e[0] = Tk(A, _ticket(keys[A], r, 2 ether, 0, 1));
        _commit(r, e);
        _recordResolution();
        ch.resolve(r, package1);
        (, uint8 outcome,,,,,,,,,,,) = ch.rounds(r);
        assertEq(outcome, 0);
        T.Leaf[] memory n = _copyFin();
        n[A] = T.Leaf(10 ether, 0, 10 ether, 0);
        _propose(r, n);
        vm.expectRevert(PredictionChannel.NotWrong.selector);
        _challengeUpdate(A, n[A], n, e);
    }

    function test_void_rules_are_outcome_independent() public {
        uint256 r = _open(6500);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.voidRound(r);
        vm.roll(DEADLINE + 1);
        ch.voidRound(r); // never committed

        // A committed round can't be voided while its anchor is recordable, nor once recorded.
        T.Leaf[] memory n = _copyFin();
        _propose(r, n);
        _finalize(n);
        vm.roll(300);
        vm.prank(op);
        r = ch.openRound(6500, oracle, oracleSlot, 0, 256, 300, 301, 302);
        _commit(r, new Tk[](0));
        vm.roll(302 + 8191);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.voidRound(r);
        vm.roll(302 + 8192);
        ch.voidRound(r);
    }

    // ---- settlement challenges --------------------------------------------------------------

    function test_overpaying_a_winner_is_challenged() public {
        (uint256 r, Tk[] memory e) = _committedAndResolved();
        T.Leaf[] memory n = _roundOneResult();
        n[A].balance += 1 ether;
        _propose(r, n);
        vm.expectRevert(PredictionChannel.NotWrong.selector);
        _challengeUpdate(B, n[B], n, e);
        uint256 before = watcher.balance;
        _challengeUpdate(A, n[A], n, e);
        assertEq(watcher.balance - before, BOND);
        assertEq(ch.pendingAt(), 0, "proposal discarded");
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.finalize();
    }

    function test_omitting_a_participant_is_challenged() public {
        (uint256 r, Tk[] memory e) = _committedAndResolved();
        T.Leaf[] memory n = _roundOneResult();
        n[C] = fin[C]; // C's leaf left untouched (empty)
        _propose(r, n);
        _challengeUpdate(C, n[C], n, e);
        assertEq(ch.bond(), 0);
    }

    function test_wrong_counters_are_challenged() public {
        (uint256 r, Tk[] memory e) = _committedAndResolved();
        // B's deposits not applied: 0 + 0 can't cover the 3 ETH stake committed against 10.
        T.Leaf[] memory n = _roundOneResult();
        n[B] = T.Leaf(0, 0, 0, 0);
        n[A] = T.Leaf(12 ether, 0, 10 ether, 0);
        _propose(r, n);
        _challengeUpdate(B, n[B], n, e);
    }

    function test_challenge_window_and_proofs() public {
        (uint256 r, Tk[] memory e) = _committedAndResolved();
        T.Leaf[] memory n = _roundOneResult();
        n[A].balance += 1;
        _propose(r, n);
        T.PartLeaf memory p = _partOf(e, A);
        bytes32[16] memory ps = Tree.siblings(_partLeaves(e), A);
        bytes32[16] memory ns = Tree.siblings(_hashes(n), A);
        // A forged round leaf.
        T.PartLeaf memory forged = p;
        forged.up += 1;
        bytes32[16] memory os = _finSiblings(A);
        vm.expectRevert(PredictionRules.BadProof.selector);
        ch.challengeUpdate(A, abi.encode(fin[A], os, n[A], ns, forged, ps));
        // A leaf that isn't in the proposal.
        vm.expectRevert(PredictionRules.BadProof.selector);
        ch.challengeUpdate(A, abi.encode(fin[A], os, _roundOneResult()[A], ns, p, ps));
        // An old leaf that isn't finalized.
        vm.expectRevert(PredictionRules.BadProof.selector);
        ch.challengeUpdate(A, abi.encode(n[A], os, n[A], ns, p, ps));
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.challengeUpdate(A, abi.encode(fin[A], os, n[A], ns, p, ps));
    }

    function test_propose_rules() public {
        uint256 r = _open(6500);
        T.Leaf[] memory n = _copyFin();
        vm.expectRevert(PredictionChannel.WrongState.selector); // round open: no proposals
        _propose(0, n);
        _commit(r, _roundOneEntries(r));
        vm.expectRevert(PredictionChannel.WrongState.selector);
        _propose(r, n); // not resolved yet
        _recordResolution();
        ch.resolve(r, package1);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        _propose(0, n); // must settle the round
        // An old leaf that isn't finalized.
        (bytes memory u, bytes32[] memory proof) = _updates(_roundOneResult());
        u[19] = bytes1(uint8(u[19]) ^ 1); // the low byte of the first old balance
        vm.prank(op);
        vm.expectRevert(PredictionChannel.BadProof.selector);
        ch.propose(r, u, proof);
        // A tampered multiproof.
        (u, proof) = _updates(_roundOneResult());
        proof[proof.length - 1] ^= bytes32(uint256(1));
        vm.prank(op);
        vm.expectRevert(PredictionChannel.BadProof.selector);
        ch.propose(r, u, proof);
        // A truncated multiproof.
        (u, proof) = _updates(_roundOneResult());
        bytes32[] memory short = new bytes32[](proof.length - 1);
        for (uint256 i; i < short.length; ++i) {
            short[i] = proof[i];
        }
        vm.prank(op);
        vm.expectRevert();
        ch.propose(r, u, short);
    }

    /// Counters aren't checked at proposal time (that would cost two cold reads per user on
    /// the normal path); a leaf claiming more than L1 recorded loses the challenge.
    function test_overclaimed_counters_are_challenged() public {
        (uint256 r, Tk[] memory e) = _committedAndResolved();
        T.Leaf[] memory n = _roundOneResult();
        n[A] = T.Leaf(13 ether, 0, 11 ether, 0); // a deposit that never happened
        _propose(r, n);
        _challengeUpdate(A, n[A], n, e);
        vm.prank(op);
        ch.postBond{value: BOND}();
        n = _roundOneResult();
        n[B] = T.Leaf(0, 7 ether, 10 ether, 1); // a withdrawal B never requested
        _propose(r, n);
        _challengeUpdate(B, n[B], n, e);
    }

    // ---- the operator-free exit -------------------------------------------------------------

    function test_operator_gone_after_resolution_everyone_exits() public {
        (uint256 r, Tk[] memory e) = _committedAndResolved();
        r;
        vm.prank(who[A]);
        ch.requestWithdraw();
        vm.expectRevert(PredictionChannel.NotOverdue.selector);
        ch.freeze(A, fin[A], _finSiblings(A));
        vm.warp(block.timestamp + 1 days);
        ch.freeze(A, fin[A], _finSiblings(A));
        assertTrue(ch.frozen());
        vm.expectRevert(PredictionChannel.WrongState.selector);
        _propose(r, _roundOneResult());

        uint256[3] memory want = [uint256(12 ether), 7 ether, 11 ether];
        for (uint32 i; i < 3; ++i) {
            uint256 before = who[i].balance;
            ch.exit(i, fin[i], _finSiblings(i), _partOf(e, i), Tree.siblings(_partLeaves(e), i));
            assertEq(who[i].balance - before, want[i]);
        }
        assertEq(address(ch).balance, BOND, "only the bond is left");
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.exit(A, fin[A], _finSiblings(A), _partOf(e, A), Tree.siblings(_partLeaves(e), A));
    }

    function test_operator_gone_before_resolution_resolve_then_exit() public {
        uint256 r = _open(6500);
        Tk[] memory e = _roundOneEntries(r);
        _commit(r, e);
        vm.prank(who[B]);
        ch.requestWithdraw();
        vm.warp(block.timestamp + 1 days);
        ch.freeze(B, fin[B], _finSiblings(B));
        bytes32[16] memory ps = Tree.siblings(_partLeaves(e), B);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.exit(B, fin[B], _finSiblings(B), _partOf(e, B), ps);
        _recordResolution();
        ch.resolve(r, package1); // anyone
        // A lie about the round leaf is caught.
        vm.expectRevert(PredictionRules.BadProof.selector);
        ch.exit(B, fin[B], _finSiblings(B), T.PartLeaf(0, 0, 0), ps);
        uint256 before = who[B].balance;
        ch.exit(B, fin[B], _finSiblings(B), _partOf(e, B), ps);
        assertEq(who[B].balance - before, 7 ether);
    }

    function test_exit_after_settled_rounds_and_partial_claims() public {
        (uint256 r, Tk[] memory e) = _committedAndResolved();
        e;
        T.Leaf[] memory n = _roundOneResult();
        _propose(r, n);
        _finalize(n);
        // A withdraws through the normal path, then deposits again.
        vm.prank(who[A]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[A] = T.Leaf(0, 12 ether, 10 ether, 1);
        _propose(0, w);
        _finalize(w);
        ch.claim(A, fin[A], _finSiblings(A));
        vm.deal(who[A], 4 ether);
        vm.prank(who[A]);
        ch.deposit{value: 4 ether}();
        // The operator stops; C's request goes unanswered.
        vm.prank(who[C]);
        ch.requestWithdraw();
        vm.warp(block.timestamp + 1 days);
        ch.freeze(C, fin[C], _finSiblings(C));
        T.PartLeaf memory none;
        bytes32[16] memory z;
        uint256[3] memory want = [uint256(4 ether), 7 ether, 11 ether];
        for (uint32 i; i < 3; ++i) {
            uint256 before = who[i].balance;
            ch.exit(i, fin[i], _finSiblings(i), none, z);
            assertEq(who[i].balance - before, want[i]);
        }
        assertEq(address(ch).balance, BOND);
    }

    function test_freeze_needs_an_unapplied_overdue_request() public {
        vm.expectRevert(PredictionChannel.NotOverdue.selector);
        ch.freeze(A, fin[A], _finSiblings(A));
        vm.prank(who[A]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[A] = T.Leaf(0, 10 ether, 10 ether, 1);
        _propose(0, w);
        _finalize(w);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(PredictionChannel.NotOverdue.selector);
        ch.freeze(A, fin[A], _finSiblings(A));
    }

    function test_schedule_bounds() public {
        vm.startPrank(op);
        vm.expectRevert(PredictionChannel.BadSchedule.selector);
        ch.openRound(1, oracle, oracleSlot, 0, 256, 95, 95, 101);
        vm.expectRevert(PredictionChannel.BadSchedule.selector);
        ch.openRound(1, oracle, oracleSlot, 0, 256, 95, 98, 90 + 1801);
        vm.expectRevert(PredictionChannel.BadSchedule.selector);
        ch.openRound(1, oracle, oracleSlot, 200, 57, 95, 98, 101);
        ch.openRound(1, oracle, oracleSlot, 0, 256, 95, 98, 101);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.openRound(1, oracle, oracleSlot, 0, 256, 95, 98, 101);
        vm.stopPrank();
        vm.expectRevert(PredictionChannel.BadSchedule.selector);
        new PredictionChannel(op, anchors, wv, rules, BOND, 6 hours + 1);
    }

    // ---- edges (each pinned by a mutation check) --------------------------------------------

    /// An overdraft no one challenged in time: the user forfeits what they had, wins nothing.
    function test_unchallenged_overdraft_forfeits() public {
        uint256 r = _open(6500);
        Tk[] memory e = _roundOneEntries(r);
        e[2] = Tk(C, _ticket(keys[C], r, 20 ether, 0, 1)); // C has 10
        _commit(r, e);
        _recordResolution();
        ch.resolve(r, package1);
        // Pot 25, UP total 22: A wins 2 * 25 / 22.
        T.Leaf[] memory n = _roundOneResult();
        n[A].balance = 10 ether - 2 ether + uint256(2 ether) * 25 / 22;
        n[C] = T.Leaf(0, 0, 10 ether, 0);
        _propose(r, n);
        for (uint32 i; i < 3; ++i) {
            vm.expectRevert(PredictionChannel.NotWrong.selector);
            _challengeUpdate(i, n[i], n, e);
        }
    }

    function test_stake_equal_to_balance_is_valid() public {
        uint256 r = _open(6500);
        Tk[] memory e = _roundOneEntries(r);
        e[1] = Tk(B, _ticket(keys[B], r, 0, 10 ether, 1));
        _commit(r, e);
        vm.expectRevert(PredictionChannel.NotWrong.selector);
        ch.challengeCommit(r, B, abi.encode(e[1].t), Tree.siblings(_partLeaves(e), B), fin[B], _finSiblings(B));
    }

    function test_withdrawal_amount_is_checked() public {
        vm.prank(who[A]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[A] = T.Leaf(0, 10 ether, 10 ether, 1);
        _propose(0, w);
        Tk[] memory none;
        vm.expectRevert(PredictionChannel.NotWrong.selector);
        _challengeUpdate(A, w[A], w, none);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.finalize(); // window not over
        vm.warp(block.timestamp + WINDOW);
        ch.finalize();
        fin[A] = w[A];
        vm.prank(who[B]);
        ch.requestWithdraw();
        w = _copyFin();
        w[B] = T.Leaf(0, 11 ether, 10 ether, 1); // one more than B has
        _propose(0, w);
        _challengeUpdate(B, w[B], w, none);
    }

    function test_strike_is_inclusive_and_bits_are_masked() public {
        uint256 r = _open(7000);
        _commit(r, _roundOneEntries(r));
        _recordResolution();
        ch.resolve(r, package1);
        (, uint8 outcome,,,,,,,,,,,) = ch.rounds(r);
        assertEq(outcome, T.UP, "7000 >= 7000");

        // 7000 = 0x1b58: bits [0, 8) = 0x58, bits [8, 16) = 0x1b.
        assertEq(rules.oracleValue(package1, anchors, wv, RESOLUTION, oracle, oracleSlot, 0, 8), 0x58);
        assertEq(rules.oracleValue(package1, anchors, wv, RESOLUTION, oracle, oracleSlot, 8, 8), 0x1b);
    }

    function test_resolve_rejects_another_recorded_block() public {
        uint256 r = _open(6500);
        _commit(r, _roundOneEntries(r));
        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/read-and-split.json"));
        bytes memory raw0 = vm.parseJsonBytes(j, ".h0.rawHeader");
        vm.roll(200);
        vm.setBlockhash(100, keccak256(raw0));
        anchors.record(raw0);
        vm.expectRevert(PredictionRules.BadAnchor.selector);
        ch.resolve(r, vm.parseJsonBytes(j, ".h0.package"));
    }

    function test_recorded_resolution_block_is_never_voided() public {
        uint256 r = _open(6500);
        _commit(r, _roundOneEntries(r));
        _recordResolution();
        vm.roll(RESOLUTION + 8192);
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.voidRound(r);
        ch.resolve(r, package1); // still resolvable: the state root is stored on L1
    }

    function test_no_round_effect_means_no_round_leaf() public {
        vm.prank(who[A]);
        ch.requestWithdraw();
        vm.warp(block.timestamp + 1 days);
        ch.freeze(A, fin[A], _finSiblings(A));
        bytes32[16] memory z;
        vm.expectRevert(PredictionRules.BadProof.selector);
        ch.exit(A, fin[A], _finSiblings(A), T.PartLeaf(1, 0, 0), z);
        // Indices beyond the tree don't alias real ones.
        vm.expectRevert(PredictionChannel.WrongState.selector);
        ch.exit(A + 65536, fin[A], _finSiblings(A), T.PartLeaf(0, 0, 0), z);
        uint256 before = who[A].balance;
        ch.exit(A, fin[A], _finSiblings(A), T.PartLeaf(0, 0, 0), z);
        assertEq(who[A].balance - before, 10 ether);
    }

    /// Each evidence check on its own: with the other parts valid, a false old or new leaf
    /// is rejected (otherwise it would convict an honest proposal).
    function test_false_evidence_cannot_convict_an_honest_proposal() public {
        (uint256 r, Tk[] memory e) = _committedAndResolved();
        T.Leaf[] memory n = _roundOneResult();
        _propose(r, n);
        T.PartLeaf memory p = _partOf(e, A);
        bytes32[16] memory ps = Tree.siblings(_partLeaves(e), A);
        bytes32[16] memory ns = Tree.siblings(_hashes(n), A);
        bytes32[16] memory os = _finSiblings(A);
        vm.startPrank(watcher);
        vm.expectRevert(PredictionRules.BadProof.selector);
        ch.challengeUpdate(A, abi.encode(T.Leaf(5 ether, 0, 0, 0), os, n[A], ns, p, ps));
        vm.expectRevert(PredictionRules.BadProof.selector);
        ch.challengeUpdate(A, abi.encode(fin[A], os, T.Leaf(13 ether, 0, 10 ether, 0), ns, p, ps));
        vm.stopPrank();
    }

    /// Counters only move forward: lowering depositsApplied would let deposits count twice.
    function test_counters_cannot_go_backwards() public {
        (uint256 r, Tk[] memory e) = _committedAndResolved();
        T.Leaf[] memory n = _roundOneResult();
        _propose(r, n);
        _finalize(n);
        T.Leaf[] memory w = _copyFin();
        w[A] = T.Leaf(2 ether, 0, 0, 0); // 12 − 10 "unapplied", ready to be applied again
        _propose(0, w);
        Tk[] memory none;
        e;
        _challengeUpdate(A, w[A], w, none);
    }

    function test_propose_rejects_unsorted_and_unregistered() public {
        (uint256 r,) = _committedAndResolved();
        T.Leaf[] memory n = _roundOneResult();
        (bytes memory u, bytes32[] memory proof) = _updates(n);
        // Swap the first two packed updates.
        bytes memory swapped = bytes.concat(_slice(u, 108, 216), _slice(u, 0, 108), _slice(u, 216, u.length));
        vm.prank(op);
        vm.expectRevert(SparseTree16.NotSorted.selector);
        ch.propose(r, swapped, proof);
        // A leaf for an index no one registered.
        fin.push(T.Leaf(0, 0, 0, 0));
        T.Leaf[] memory m = new T.Leaf[](4);
        for (uint256 i; i < 3; ++i) {
            m[i] = n[i];
        }
        m[3] = T.Leaf(1 ether, 0, 0, 0);
        (u, proof) = _updates(m);
        fin.pop();
        vm.prank(op);
        vm.expectRevert(PredictionChannel.BadUpdate.selector);
        ch.propose(r, u, proof);
    }

    /// If no one challenges a bad root, payouts are still capped by the channel's own funds.
    function test_unchallenged_bad_root_cannot_pay_beyond_deposits() public {
        T.Leaf[] memory w = _copyFin();
        w[A] = T.Leaf(0, 100 ether, 0, 0);
        _propose(0, w);
        _finalize(w);
        vm.expectRevert(PredictionChannel.Insolvent.selector);
        ch.claim(A, fin[A], _finSiblings(A));
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[from + i];
        }
    }

    // ---- conservation -----------------------------------------------------------------------

    /// Random stakes and either outcome: after a freeze, total exits never exceed deposits and
    /// lose at most rounding dust (one wei per participant).
    function testFuzz_exits_conserve_funds(uint256 seed, bool up) public {
        uint256 r = _open(up ? 6500 : 8000);
        Tk[] memory e = new Tk[](3);
        for (uint32 i; i < 3; ++i) {
            uint256 a = uint256(keccak256(abi.encode(seed, i))) % 5 ether;
            uint256 b = uint256(keccak256(abi.encode(seed, i, "down"))) % 5 ether;
            if (a + b == 0) a = 1;
            e[i] = Tk(i, _ticket(keys[i], r, a, b, 1));
        }
        _commit(r, e);
        _recordResolution();
        ch.resolve(r, package1);
        vm.prank(who[A]);
        ch.requestWithdraw();
        vm.warp(block.timestamp + 1 days);
        ch.freeze(A, fin[A], _finSiblings(A));
        uint256 total;
        for (uint32 i; i < 3; ++i) {
            uint256 before = who[i].balance;
            ch.exit(i, fin[i], _finSiblings(i), _partOf(e, i), Tree.siblings(_partLeaves(e), i));
            total += who[i].balance - before;
        }
        assertLe(total, 30 ether);
        assertGe(total + 3, 30 ether);
    }
}

contract SparseTree16Harness {
    function rootFrom(bytes32 leaf, uint256 index, bytes32[16] calldata siblings) external pure returns (bytes32) {
        return SparseTree16.rootFrom(leaf, index, siblings);
    }

    function build(uint256[] memory indices, bytes32[] memory leaves) external pure returns (bytes32) {
        return SparseTree16.build(indices, leaves);
    }

    function transition(
        uint256[] memory indices,
        bytes32[] memory oldLeaves,
        bytes32[] memory newLeaves,
        bytes32[] calldata proof
    ) external pure returns (bytes32, bytes32) {
        return SparseTree16.transition(indices, oldLeaves, newLeaves, proof);
    }
}

contract SparseTree16Test is PredictionBase {
    function test_build_matches_independent_tree_and_paths() public {
        SparseTree16Harness h = new SparseTree16Harness();
        bytes32[] memory dense = new bytes32[](37);
        uint256[] memory idx = new uint256[](5);
        bytes32[] memory lv = new bytes32[](5);
        uint256[5] memory at = [uint256(0), 1, 7, 20, 36];
        for (uint256 i; i < 5; ++i) {
            idx[i] = at[i];
            lv[i] = keccak256(abi.encode(i));
            dense[at[i]] = lv[i];
        }
        bytes32 root = Tree.root(dense);
        assertEq(h.build(idx, lv), root);
        for (uint256 i; i < 5; ++i) {
            assertEq(h.rootFrom(dense[at[i]], at[i], Tree.siblings(dense, at[i])), root);
        }
        vm.expectRevert(SparseTree16.BadProof.selector);
        h.rootFrom(dense[1], 1 + 65536, Tree.siblings(dense, 1));
        (idx[1], idx[2]) = (idx[2], idx[1]);
        vm.expectRevert(SparseTree16.NotSorted.selector);
        h.build(idx, lv);
    }

    /// Random subsets of a random-length tree: the multiproof transition gives the same old and
    /// new roots as the independent tree, and a wrong old leaf or an extra proof node fails.
    function testFuzz_transition_matches_independent_tree(uint256 seed, uint8 size) public {
        SparseTree16Harness h = new SparseTree16Harness();
        uint256 n = 1 + uint256(size) % 70;
        bytes32[] memory olds = new bytes32[](n);
        bytes32[] memory news = new bytes32[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            olds[i] =
                uint256(keccak256(abi.encode(seed, i))) % 4 == 0 ? bytes32(0) : keccak256(abi.encode(seed, i, "o"));
            news[i] = olds[i];
            if (uint256(keccak256(abi.encode(seed, i, "pick"))) % 3 == 0) {
                news[i] = keccak256(abi.encode(seed, i, "n"));
                k++;
            }
        }
        vm.assume(k > 0);
        uint256[] memory idx = new uint256[](k);
        bytes32[] memory o = new bytes32[](k);
        bytes32[] memory nw = new bytes32[](k);
        uint256 j;
        for (uint256 i; i < n; ++i) {
            if (news[i] == olds[i]) continue;
            (idx[j], o[j], nw[j]) = (i, olds[i], news[i]);
            j++;
        }
        bytes32[] memory proof = Tree.multiproof(olds, idx);
        (bytes32 a, bytes32 b) = h.transition(_copyU(idx), _copyB(o), _copyB(nw), proof);
        assertEq(a, Tree.root(olds));
        assertEq(b, Tree.root(news));
        o[0] ^= bytes32(uint256(1));
        (a,) = h.transition(_copyU(idx), _copyB(o), _copyB(nw), proof);
        assertTrue(a != Tree.root(olds));
        bytes32[] memory longer = new bytes32[](proof.length + 1);
        for (uint256 i; i < proof.length; ++i) {
            longer[i] = proof[i];
        }
        vm.expectRevert(SparseTree16.BadProof.selector);
        h.transition(_copyU(idx), _copyB(o), _copyB(nw), longer);
    }

    function _copyU(uint256[] memory a) internal pure returns (uint256[] memory c) {
        c = new uint256[](a.length);
        for (uint256 i; i < a.length; ++i) {
            c[i] = a[i];
        }
    }

    function _copyB(bytes32[] memory a) internal pure returns (bytes32[] memory c) {
        c = new bytes32[](a.length);
        for (uint256 i; i < a.length; ++i) {
            c[i] = a[i];
        }
    }
}

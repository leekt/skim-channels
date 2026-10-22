// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {PredictionBase, Tree} from "./PredictionBase.sol";
import {PredictionChannel} from "../../src/predict/PredictionChannel.sol";
import {PredictionStorage} from "../../src/predict/PredictionStorage.sol";
import {PredictionDisputes} from "../../src/predict/PredictionDisputes.sol";
import {PredictionTypes as T} from "../../src/predict/PredictionTypes.sol";
import {PredictionRules} from "../../src/predict/PredictionRules.sol";

/// Regressions for the f4aab62 review (A1–A4). Each scenario failed on f4aab62 (see
/// docs/experiments/prediction-review-fixes.md for the recorded failures).
contract ReviewReproTest is PredictionBase {
    function setUp() public override {
        super.setUp();
        _addUsers(3, 10 ether);
    }

    function _none() internal pure returns (Tk[] memory none) {}

    function _challenge(uint32 idx, T.Leaf[] memory proposed, Tk[] memory e) internal {
        vm.prank(watcher);
        D.challengeUpdate(
            idx,
            proposed[idx].requestsApplied,
            abi.encode(
                fin[idx],
                _finSiblings(idx),
                proposed[idx],
                Tree.siblings(_hashes(proposed), idx),
                _partOf(e, idx),
                Tree.siblings(_partLeaves(e), idx)
            )
        );
    }

    // ---- A1: challenge periods can't collapse ------------------------------------------------

    function _deploys(PredictionStorage.Config memory c) internal returns (bool) {
        try new PredictionDisputes(c) returns (PredictionDisputes) {
            return true;
        } catch (bytes memory err) {
            assertEq(bytes4(err), PredictionStorage.BadPolicy.selector);
            return false;
        }
    }

    function test_A1_policyFloorsEnforced() public {
        assertTrue(_deploys(_policy()), "the production floors themselves are accepted");
        PredictionStorage.Config memory c = _policy();
        c.challengeWindow = 0;
        assertFalse(_deploys(c), "zero window");
        c = _policy();
        c.challengeWindow = 1 hours - 1;
        assertFalse(_deploys(c), "window under 1 h");
        c = _policy();
        c.commitChallengeBlocks = 63;
        assertFalse(_deploys(c), "commit challenge under 64 blocks");
        c = _policy();
        c.forceDelay = 1 days - 1;
        assertFalse(_deploys(c), "forced delay under 1 day");
        c = _policy();
        c.challengeWindow = 12 hours; // 1800 blocks + 2 x 12 h > 1 day
        assertFalse(_deploys(c), "round plus two windows must fit the forced delay");
        c.forceDelay = 2 days; // a longer forced delay admits a longer window
        assertTrue(_deploys(c));
        c = _policy();
        c.forceDelay = 60 days + 1; // upper bounds keep at + delay far from overflow
        assertFalse(_deploys(c), "forced delay above 60 days");
    }

    /// The review's schedule (N, N+1, N+2) is refused, and a commit made in its last allowed
    /// block still leaves 64 blocks in which an honest watcher voids a forged ticket.
    function test_A1_forgedCommitChallengeableAfterPublication() public {
        uint256 n = block.number;
        vm.prank(op);
        vm.expectRevert(PredictionStorage.BadSchedule.selector);
        ch.openRound(6500, oracle, oracleSlot, 0, 256, uint64(n), uint64(n + 1), uint64(n + 2));

        vm.prank(op);
        uint256 r = ch.openRound(6500, oracle, oracleSlot, 0, 256, DEADLINE, CHALLENGE_END, RESOLUTION);
        Tk[] memory e = new Tk[](1);
        e[0] = Tk(0, _ticket(keys[1], r, 1 ether, 0, 1)); // user 1 signed user 0's ticket
        vm.roll(DEADLINE); // the latest block the operator may commit in
        _commit(r, e);
        vm.roll(CHALLENGE_END - 1); // the watcher shows up late, but inside the period
        vm.prank(watcher);
        D.challengeCommit(r, 0, abi.encode(e[0].t), Tree.siblings(_partLeaves(e), 0), fin[0], _finSiblings(0));
        (PredictionStorage.Status st,,,,,,,,,,,,) = ch.rounds(r);
        assertEq(uint8(st), uint8(PredictionStorage.Status.Void));
    }

    // ---- A2: a withdraw-all request can't be consumed without paying what it covers ---------

    function test_A2_requestConsumedWithoutPaymentIsAFault() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[0] = T.Leaf(0, 0, 0, 1);
        _propose(0, w, 1);
        _challenge(0, w, _none());
        assertEq(ch.bond(), 0, "bond to the watcher");
    }

    function test_A2_correctWithdrawalPaysEverythingRequested() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[0] = T.Leaf(0, 10 ether, 10 ether, 1);
        _propose(0, w, 1);
        vm.expectRevert(PredictionStorage.NotWrong.selector);
        _challenge(0, w, _none());
        _finalize(w);
        uint256 before = who[0].balance;
        ch.claim(0, fin[0], _finSiblings(0));
        assertEq(who[0].balance - before, 10 ether);
    }

    /// A challenger can't pick k to convict an honest proposal: k must be the leaf's own count.
    function test_A2_challengerCannotMisstateK() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[0] = T.Leaf(0, 10 ether, 10 ether, 1);
        _propose(0, w, 1);
        Tk[] memory none;
        vm.prank(watcher);
        vm.expectRevert(PredictionRules.BadProof.selector);
        D.challengeUpdate(
            0,
            0,
            abi.encode(
                fin[0],
                _finSiblings(0),
                w[0],
                Tree.siblings(_hashes(w), 0),
                _partOf(none, 0),
                Tree.siblings(_partLeaves(none), 0)
            )
        );
    }

    /// A proposal whose cursor covers a request must apply it: leaving the leaf untouched
    /// is a fault for that user.
    function test_A2_cursorCoversRequestButLeafUntouched() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[1] = T.Leaf(10 ether, 0, 10 ether, 0);
        _propose(0, w, 1); // claims to serve request 0, doesn't touch user 0
        _challenge(0, w, _none());
    }

    /// The cursor can't move backwards or past the queue.
    function test_A2_cursorBounds() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[0] = T.Leaf(0, 10 ether, 10 ether, 1);
        vm.expectRevert(PredictionStorage.BadUpdate.selector);
        _propose(0, w, 2);
        _propose(0, w, 1);
        _finalize(w);
        vm.expectRevert(PredictionStorage.BadUpdate.selector);
        _propose(0, w, 0);
    }

    /// Claims stop at freeze (exit pays from then on, counting what claims paid).
    function test_A3_noClaimsAfterFreeze() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[0] = T.Leaf(0, 10 ether, 10 ether, 1);
        _propose(0, w, 1);
        _finalize(w);
        vm.prank(who[1]);
        ch.requestWithdraw();
        vm.warp(block.timestamp + 1 days);
        D.freeze();
        vm.expectRevert(PredictionStorage.WrongState.selector);
        ch.claim(0, fin[0], _finSiblings(0));
        bytes32[16] memory z;
        uint256 before = who[0].balance;
        D.exit(0, fin[0], _finSiblings(0), T.PartLeaf(0, 0, 0), z); // pays the 10 once
        assertEq(who[0].balance - before, 10 ether);
        vm.expectRevert(PredictionStorage.WrongState.selector);
        D.exit(0, fin[0], _finSiblings(0), T.PartLeaf(0, 0, 0), z);
    }

    /// The disputes contract holds no state of its own: called directly, it refuses.
    function test_disputesOnlyViaChannel() public {
        PredictionDisputes direct = ch.disputes();
        vm.expectRevert(PredictionStorage.WrongState.selector);
        direct.freeze();
    }

    /// A request the finalized root didn't serve (its cursor stopped before it) keeps its
    /// deadline: a day later anyone freezes and the user exits with everything.
    function test_A2_unservedRequestStillFreezes() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[1] = T.Leaf(10 ether, 0, 10 ether, 0); // the operator does other work only
        _propose(0, w, 0);
        _finalize(w);
        vm.warp(block.timestamp + 1 days);
        D.freeze();
        bytes32[16] memory z;
        uint256 before = who[0].balance;
        D.exit(0, fin[0], _finSiblings(0), T.PartLeaf(0, 0, 0), z);
        assertEq(who[0].balance - before, 10 ether);
    }

    /// A deposit made after the request isn't covered by it; deposits before it are.
    function test_A2_depositAfterRequestIsNotCoveredButEarlierOnesAre() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        vm.deal(who[0], 5 ether);
        vm.prank(who[0]);
        ch.deposit{value: 5 ether}();
        T.Leaf[] memory w = _copyFin();
        w[0] = T.Leaf(0, 10 ether, 10 ether, 1); // pays the 10 it covers; the 5 stays
        _propose(0, w, 1);
        vm.expectRevert(PredictionStorage.NotWrong.selector);
        _challenge(0, w, _none());
        _finalize(w);
        // Paying only the 5 deposited later (and skipping the 10 before) is a fault.
        T.Leaf[] memory bad = _copyFin();
        bad[0] = T.Leaf(0, 10 ether, 10 ether, 1);
        vm.prank(who[0]);
        ch.requestWithdraw();
        bad[0] = T.Leaf(0, 10 ether, 10 ether, 2); // claims the second request, applies no deposit
        _propose(0, bad, 2);
        _challenge(0, bad, _none());
    }

    /// During a round: a participant's request is applied at the round's settlement, after
    /// the payout; a non-participant's too; deposits made after the commit are covered when
    /// made before the request.
    function test_A2_requestsDuringARound() public {
        uint256 r = _open(6500);
        Tk[] memory e = new Tk[](2);
        e[0] = Tk(0, _ticket(keys[0], r, 2 ether, 0, 1));
        e[1] = Tk(1, _ticket(keys[1], r, 0, 2 ether, 1));
        _commit(r, e);
        vm.deal(who[0], 1 ether);
        vm.prank(who[0]);
        ch.deposit{value: 1 ether}(); // after the commit, before the request
        vm.prank(who[0]);
        ch.requestWithdraw();
        vm.prank(who[2]); // non-participant
        ch.requestWithdraw();
        _recordResolution();
        D.resolve(r, package1); // UP: user 0 wins 4 (stake 2), user 1 loses 2
        T.Leaf[] memory n = _copyFin();
        n[0] = T.Leaf(0, 13 ether, 11 ether, 1); // 11 − 2 + 4
        n[1] = T.Leaf(8 ether, 0, 10 ether, 0);
        n[2] = T.Leaf(0, 10 ether, 10 ether, 1);
        uint256 snap = vm.snapshotState();
        // Consuming user 0's request without the post-commit deposit is a fault.
        T.Leaf[] memory bad = _copyFin();
        for (uint256 i; i < 3; ++i) {
            bad[i] = n[i];
        }
        bad[0] = T.Leaf(0, 12 ether, 10 ether, 1);
        _propose(r, bad, 2);
        _challenge(0, bad, e);
        vm.revertToState(snap);
        _propose(r, n, 2);
        for (uint32 i; i < 3; ++i) {
            vm.expectRevert(PredictionStorage.NotWrong.selector);
            _challenge(i, n, e);
        }
    }

    /// Repeated requests: each must cover its own deposits; skipping to the second request
    /// while the first is unpaid is still a fault for the first.
    function test_A2_repeatedRequests() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        vm.prank(who[0]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[0] = T.Leaf(0, 0, 0, 2);
        _propose(0, w, 2);
        _challenge(0, w, _none());
    }

    // ---- A3: forced deadlines can't be raced or restarted ----------------------------------

    function test_A3_freezeNeedsNoLeafEvidence() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[1] = T.Leaf(10 ether, 0, 10 ether, 0); // the operator updates someone else only
        _propose(0, w, 0);
        _finalize(w);
        vm.warp(block.timestamp + 1 days);
        D.freeze(); // no siblings to go stale
        assertTrue(ch.frozen());
    }

    function test_A3_overdueRequestBlocksNewRounds() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        vm.warp(block.timestamp + 1 days);
        vm.prank(op);
        vm.expectRevert(PredictionStorage.Overdue.selector);
        ch.openRound(6500, oracle, oracleSlot, 0, 256, DEADLINE, CHALLENGE_END, RESOLUTION);
    }

    /// A round opened before the request doesn't move its deadline: if the round can't be
    /// settled in time, the channel freezes mid-round and exits handle the round.
    function test_A3_roundDoesNotExtendDeadline() public {
        uint256 r = _open(6500);
        Tk[] memory e = new Tk[](1);
        e[0] = Tk(0, _ticket(keys[0], r, 1 ether, 0, 1));
        _commit(r, e);
        vm.prank(who[2]);
        ch.requestWithdraw();
        vm.warp(block.timestamp + 1 days);
        D.freeze();
        uint256 before = who[2].balance;
        D.exit(2, fin[2], _finSiblings(2), T.PartLeaf(0, 0, 0), Tree.siblings(_partLeaves(e), 2));
        assertEq(who[2].balance - before, 10 ether);
    }

    /// Same block, both orders: finalize-then-freeze (the request is served: freeze refused,
    /// the user claims) and freeze-then-finalize (frozen: finalize refused, the user exits).
    function test_A3_finalizeFreezeOrderInOneBlock() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        T.Leaf[] memory w = _copyFin();
        w[0] = T.Leaf(0, 10 ether, 10 ether, 1);
        _propose(0, w, 1);
        vm.warp(block.timestamp + 1 days); // window over and request overdue together
        uint256 snap = vm.snapshotState();
        ch.finalize();
        vm.expectRevert(PredictionStorage.NotOverdue.selector);
        D.freeze();
        for (uint256 i; i < 3; ++i) {
            fin[i] = w[i];
        }
        uint256 before = who[0].balance;
        ch.claim(0, fin[0], _finSiblings(0));
        assertEq(who[0].balance - before, 10 ether);

        vm.revertToState(snap);
        for (uint256 i; i < 3; ++i) {
            fin[i] = T.Leaf(0, 0, 0, 0);
        }
        D.freeze();
        vm.expectRevert(PredictionStorage.WrongState.selector);
        ch.finalize();
        bytes32[16] memory z;
        before = who[0].balance;
        D.exit(0, fin[0], _finSiblings(0), T.PartLeaf(0, 0, 0), z);
        assertEq(who[0].balance - before, 10 ether);
    }

    /// A late proposal or re-proposal doesn't restart anything: the deadline is the
    /// request's, and an older unserved request keeps the channel freezable.
    function test_A3_reproposalDoesNotRestartDeadline() public {
        vm.prank(who[0]);
        ch.requestWithdraw();
        vm.warp(block.timestamp + 23 hours);
        T.Leaf[] memory w = _copyFin();
        w[0] = T.Leaf(0, 0, 0, 1); // wrong: caught
        _propose(0, w, 1);
        _challenge(0, w, _none());
        vm.prank(op);
        ch.postBond{value: BOND}();
        w[0] = T.Leaf(0, 10 ether, 10 ether, 1);
        _propose(0, w, 1); // honest, but its window ends after the deadline
        vm.warp(block.timestamp + 1 hours);
        D.freeze(); // deadline passed with the request unserved in the finalized root
        assertTrue(ch.frozen());
    }

    // ---- A4: losing the resolution witness -------------------------------------------------

    /// Anchor recorded, never resolved, operator gone: non-participants exit in full; a
    /// participant gets everything but the stake now; once someone resolves with a retained
    /// witness, the rest. Nothing is cancelled because the witness went missing.
    function test_A4_exitsWithoutResolutionThenWithRetainedWitness() public {
        uint256 r = _open(6500);
        Tk[] memory e = new Tk[](2);
        e[0] = Tk(0, _ticket(keys[0], r, 1 ether, 0, 1));
        e[1] = Tk(1, _ticket(keys[1], r, 0, 3 ether, 1));
        _commit(r, e);
        _recordResolution(); // recorded; no one has resolved
        vm.prank(who[2]);
        ch.requestWithdraw();
        vm.warp(block.timestamp + 1 days);
        D.freeze();
        uint256 b2 = who[2].balance;
        D.exit(2, fin[2], _finSiblings(2), T.PartLeaf(0, 0, 0), Tree.siblings(_partLeaves(e), 2));
        assertEq(who[2].balance - b2, 10 ether, "non-participant in full");

        bytes32[16] memory ps0 = Tree.siblings(_partLeaves(e), 0);
        uint256 b0 = who[0].balance;
        D.exit(0, fin[0], _finSiblings(0), _partOf(e, 0), ps0);
        assertEq(who[0].balance - b0, 9 ether, "all but the stake");
        vm.expectRevert(PredictionStorage.WrongState.selector);
        D.exit(0, fin[0], _finSiblings(0), _partOf(e, 0), ps0); // nothing more yet

        // Far past the history horizon: still not voidable, because the anchor was recorded.
        vm.roll(RESOLUTION + 8192 + 10);
        vm.expectRevert(PredictionStorage.WrongState.selector);
        D.voidRound(r);
        // A watcher's retained copy of the witness resolves it (UP: user 0 wins 4).
        D.resolve(r, package1);
        D.exit(0, fin[0], _finSiblings(0), _partOf(e, 0), ps0);
        assertEq(who[0].balance - b0, 13 ether, "then the rest: 10 - 1 + 4");
        uint256 b1 = who[1].balance;
        D.exit(1, fin[1], _finSiblings(1), _partOf(e, 1), Tree.siblings(_partLeaves(e), 1));
        assertEq(who[1].balance - b1, 7 ether);
        assertEq(address(ch).balance, BOND);
    }
}

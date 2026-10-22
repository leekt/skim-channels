// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AppChannelVault} from "../../src/app/AppChannelVault.sol";
import {MockAppCheckpointVerifier} from "../../src/app/MockAppCheckpointVerifier.sol";
import {IAppCheckpointVerifier} from "../../src/app/IAppCheckpointVerifier.sol";
import {AnchorRegistry} from "../../src/AnchorRegistry.sol";
import {AppLedger} from "./AppLedger.sol";

contract TestToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public feeBps; // nonzero = fee-on-transfer

    function setFee(uint256 b) external {
        feeBps = b;
    }

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
        balanceOf[to] += a - a * feeBps / 10_000;
        return true;
    }
}

/// App channels: checkpoint accounting behind the labeled MOCK verifier
/// (docs/guide/app-channels.md §9, experiments 1, 2 and 4).
contract AppChannelVaultTest is Test {
    AppChannelVault vault;
    MockAppCheckpointVerifier mock;
    TestToken usd;
    AppLedger app;
    bytes32 id;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address[3] users;
    uint64 deadline;
    bytes[] published; // every accepted checkpoint's net diff, as it appears in L1 calldata
    uint64[2][] cursors; // and its accepted cursors

    function setUp() public {
        vm.warp(1_700_000_000);
        mock = new MockAppCheckpointVerifier();
        vault = new AppChannelVault(new AnchorRegistry());
        usd = new TestToken();
        users = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            vm.deal(users[i], 100 ether);
            usd.mint(users[i], 1_000e6);
            vm.prank(users[i]);
            usd.approve(address(vault), type(uint256).max);
        }
        deadline = uint64(block.timestamp + 30 days);
        id = _open(mock, 2 days);
        app = new AppLedger(vault, id);
    }

    function _open(IAppCheckpointVerifier v, uint32 delay) internal returns (bytes32) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(usd);
        return vault.openChannel(
            AppChannelVault.Config(address(this), v, keccak256("ledger-app"), deadline, delay, tokens),
            keccak256(abi.encode(address(v), delay, gasleft()))
        );
    }

    function _depositEth(address u, uint256 a) internal {
        vm.prank(u);
        vault.deposit{value: a}(id, address(0), a);
    }

    function _depositUsd(address u, uint256 a) internal {
        vm.prank(u);
        vault.deposit(id, address(usd), a);
    }

    function _checkpoint() internal {
        app.consumeDeposits(uint64(vault.depositCount(id)));
        app.consumeForced(uint64(vault.forcedCount(id)));
        _submit(false);
    }

    function _submit(bool terminal) internal {
        AppChannelVault.Claim memory c = app.claim(terminal);
        bytes memory d = app.data();
        vault.submitCheckpoint(id, c, d, app.mockProof(c, d));
        app.markPublished();
        published.push(d);
        cursors.push([c.depositCursor, c.forcedCursor]);
    }

    /// Recovery: a fresh ledger built only from the last accepted checkpoint's published data
    /// and the vault's accepted cursors. Provisional (unproven) activity is gone.
    function _recovered() internal returns (AppLedger l) {
        l = new AppLedger(vault, id);
        AppChannelVault.Channel memory c = vault.channel(id);
        for (uint256 i; i < published.length; ++i) {
            l.applyDiff(published[i], cursors[i][0], cursors[i][1]);
        }
        assertEq(l.root(true), c.exitRoot, "recovered exit root");
        assertEq(l.root(false), c.creditRoot, "recovered credit root");
    }

    /// Claims every right: credits (delta), exits, refunds. Then the vault must hold nothing.
    function _drainAll() internal {
        _drainWith(app);
    }

    function _drainWith(AppLedger l) internal {
        (address[] memory rs, address[] memory ts) = l.keys();
        for (uint256 i; i < rs.length; ++i) {
            if (l.credit(keccak256(abi.encode(rs[i], ts[i]))) > vault.paidCredit(id, rs[i], ts[i])) {
                (uint256 idx, bytes32[] memory sib, uint256 v) = l.proof(false, rs[i], ts[i]);
                vault.claimCredit(id, rs[i], ts[i], v, idx, sib);
            }
            if (l.balance(keccak256(abi.encode(rs[i], ts[i]))) > 0) {
                (uint256 idx, bytes32[] memory sib, uint256 v) = l.proof(true, rs[i], ts[i]);
                vault.claimExit(id, rs[i], ts[i], v, idx, sib);
            }
        }
        AppChannelVault.Channel memory c = vault.channel(id);
        for (uint256 i = c.depositCursor; i < vault.depositCount(id); ++i) {
            vault.refundDeposit(id, i);
        }
        assertEq(address(vault).balance, 0, "ETH left in vault");
        assertEq(usd.balanceOf(address(vault)), 0, "USD left in vault");
    }

    // ---- experiment 1: the operator disappears ------------------------------------------

    function test_exp1a_operatorDiesBeforeFirstProof_everyDepositRefunded() public {
        _depositEth(alice, 1 ether);
        _depositUsd(bob, 300e6);
        _depositEth(carol, 2 ether);
        vm.prank(alice);
        vault.forceExit(id, address(0));
        vm.expectRevert(AppChannelVault.NotYet.selector);
        vault.freeze(id);
        vm.warp(block.timestamp + 1 days);
        vm.prank(makeAddr("anyone"));
        vault.freeze(id);
        for (uint256 i; i < 3; ++i) {
            vault.refundDeposit(id, i);
        }
        assertEq(alice.balance, 100 ether);
        assertEq(usd.balanceOf(bob), 1_000e6);
        assertEq(carol.balance, 100 ether);
        assertEq(address(vault).balance, 0);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "refunded"));
        vault.refundDeposit(id, 0);
    }

    function test_exp1b_exitFromLastAcceptedCheckpoint() public {
        _depositEth(alice, 3 ether);
        _depositUsd(bob, 500e6);
        _depositEth(carol, 1 ether);
        _checkpoint();
        // Interactions, a withdrawal, another checkpoint.
        assertTrue(app.transfer(alice, bob, address(0), 1 ether));
        assertTrue(app.transfer(bob, carol, address(usd), 200e6));
        assertTrue(app.withdraw(carol, address(usd), 50e6));
        _checkpoint();
        // carol claims her withdrawal right away (no delay for credits).
        (uint256 i0, bytes32[] memory s0, uint256 v0) = app.proof(false, carol, address(usd));
        vault.claimCredit(id, carol, address(usd), v0, i0, s0);
        assertEq(usd.balanceOf(carol), 1_000e6 + 50e6);
        // A later deposit the operator never consumes, then the operator vanishes.
        _depositEth(bob, 4 ether);
        vm.prank(bob);
        vault.forceExit(id, address(usd));
        vm.warp(block.timestamp + 1 days);
        vault.freeze(id);
        // Exits wait for the payout delay; credits don't.
        (uint256 i1, bytes32[] memory s1, uint256 v1) = app.proof(true, alice, address(0));
        vm.expectRevert(AppChannelVault.NotYet.selector);
        vault.claimExit(id, alice, address(0), v1, i1, s1);
        vm.warp(block.timestamp + 2 days);
        _drainAll();
        assertEq(alice.balance, 100 ether - 1 ether); // gave 1 ETH to bob
        assertEq(bob.balance, 100 ether + 1 ether); // got 1 ETH; 4 ETH deposit refunded
        assertEq(usd.balanceOf(bob), 1_000e6 - 200e6);
        assertEq(usd.balanceOf(carol), 1_000e6 + 200e6);
    }

    // ---- experiment 4: the one-day fence ----------------------------------------------------

    function test_exp4_lateCheckpointCannotRaceFreeze() public {
        _depositEth(alice, 1 ether);
        _checkpoint();
        vm.prank(alice);
        vault.forceExit(id, address(0));
        uint256 t0 = block.timestamp;
        // One second before the deadline the operator may still serve it ...
        vm.warp(t0 + 1 days - 1);
        assertFalse(vault.overdue(id));
        // ... but at the deadline, even a checkpoint that serves it is refused.
        vm.warp(t0 + 1 days);
        app.consumeForced(1);
        AppChannelVault.Claim memory c = app.claim(false);
        bytes memory d = app.data();
        bytes memory p = app.mockProof(c, d);
        vm.expectRevert(AppChannelVault.Overdue.selector);
        vault.submitCheckpoint(id, c, d, p);
        vault.freeze(id);
        AppChannelVault.Channel memory snap = vault.channel(id);
        // Nothing moves the snapshot afterwards.
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.WrongStatus.selector, AppChannelVault.Status.Frozen));
        vault.submitCheckpoint(id, c, d, p);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.WrongStatus.selector, AppChannelVault.Status.Frozen));
        vault.freeze(id);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.WrongStatus.selector, AppChannelVault.Status.Frozen));
        _depositEth(bob, 1 ether);
        assertEq(vault.channel(id).checkpointHash, snap.checkpointHash);
        // Alice exits from the frozen root (her forced request was never served).
        vm.warp(block.timestamp + 2 days);
        _drainWith(_recovered());
        assertEq(alice.balance, 100 ether);
    }

    function test_exp4_servedInTimeKeepsChannelLive() public {
        _depositEth(alice, 1 ether);
        _checkpoint();
        vm.prank(alice);
        vault.forceExit(id, address(0));
        vm.warp(block.timestamp + 1 days - 1);
        _checkpoint(); // serves it: alice's balance becomes a credit
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert(AppChannelVault.NotYet.selector);
        vault.freeze(id);
        (uint256 i, bytes32[] memory s, uint256 v) = app.proof(false, alice, address(0));
        vault.claimCredit(id, alice, address(0), v, i, s);
        assertEq(alice.balance, 100 ether);
    }

    function test_expiryFreezesAnUnclosedChannel() public {
        _depositEth(alice, 1 ether);
        _checkpoint();
        vm.warp(deadline);
        app.consumeDeposits(1);
        AppChannelVault.Claim memory c = app.claim(false);
        bytes memory d = app.data();
        bytes memory p = app.mockProof(c, d);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "deadline"));
        vault.submitCheckpoint(id, c, d, p);
        vault.freeze(id);
        vm.warp(block.timestamp + 2 days);
        _drainAll();
    }

    function test_terminalCheckpointClosesWithImmediateExits() public {
        _depositEth(alice, 1 ether);
        _depositUsd(bob, 10e6);
        app.consumeDeposits(2);
        app.transfer(bob, alice, address(usd), 4e6);
        _submit(true);
        assertEq(uint8(vault.channel(id).status), uint8(AppChannelVault.Status.Closed));
        _drainAll();
        assertEq(usd.balanceOf(alice), 1_000e6 + 4e6);
    }

    // ---- experiment 2: adversarial accounting -------------------------------------------

    function test_exp2_creditsPayOnlyTheIncrease() public {
        _depositEth(alice, 5 ether);
        app.consumeDeposits(1);
        app.withdraw(alice, address(0), 1 ether);
        app.submit(false);
        (uint256 i, bytes32[] memory s, uint256 v) = app.proof(false, alice, address(0));
        vault.claimCredit(id, alice, address(0), v, i, s);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "nothing owed"));
        vault.claimCredit(id, alice, address(0), v, i, s);
        app.withdraw(alice, address(0), 2 ether);
        app.submit(false);
        // The old leaf no longer proves against the new root.
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "credit proof"));
        vault.claimCredit(id, alice, address(0), v, i, s);
        (i, s, v) = app.proof(false, alice, address(0));
        vault.claimCredit(id, alice, address(0), v, i, s);
        assertEq(alice.balance, 100 ether - 5 ether + 3 ether);
    }

    function test_exp2_exitAndRefundAreOnceOnly() public {
        _depositEth(alice, 1 ether);
        _checkpoint();
        _depositEth(bob, 1 ether); // never consumed
        _submit(true);
        (uint256 i, bytes32[] memory s, uint256 v) = app.proof(true, alice, address(0));
        vault.claimExit(id, alice, address(0), v, i, s);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "claimed"));
        vault.claimExit(id, alice, address(0), v, i, s);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "consumed"));
        vault.refundDeposit(id, 0);
        vault.refundDeposit(id, 1);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "refunded"));
        vault.refundDeposit(id, 1);
        assertEq(address(vault).balance, 0);
    }

    function test_exp2_forgedLeavesAndWrongTreesRejected() public {
        _depositEth(alice, 1 ether);
        app.consumeDeposits(1);
        app.submit(true);
        (uint256 i, bytes32[] memory s,) = app.proof(true, alice, address(0));
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "exit proof"));
        vault.claimExit(id, alice, address(0), 2 ether, i, s); // inflated amount
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "exit proof"));
        vault.claimExit(id, bob, address(0), 1 ether, i, s); // someone else's leaf
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "credit proof"));
        vault.claimCredit(id, alice, address(0), 1 ether, i, s); // exit leaf as a credit
        bytes32[] memory deep = new bytes32[](33);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "exit proof"));
        vault.claimExit(id, alice, address(0), 1 ether, 0, deep);
    }

    function test_exp2_publicInputsAreBound() public {
        _depositEth(alice, 1 ether);
        _depositEth(bob, 1 ether);
        app.consumeDeposits(2);
        AppChannelVault.Claim memory c = app.claim(false);
        bytes memory d = app.data();
        bytes memory p = app.mockProof(c, d);
        // Another deposit cursor, other data, another channel: the proof no longer matches.
        AppChannelVault.Claim memory c2 = app.claim(false);
        c2.depositCursor = 1;
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "proof"));
        vault.submitCheckpoint(id, c2, d, p);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "proof"));
        vault.submitCheckpoint(id, c, bytes.concat(d, hex"00"), p);
        // Another channel: the same claim (at a cursor both share) hashes differently.
        bytes32 other = _open(mock, 2 days);
        AppChannelVault.Claim memory c0 = app.claim(false);
        c0.depositCursor = 0;
        assertTrue(vault.inputsHash(id, c0, keccak256(d)) != vault.inputsHash(other, c0, keccak256(d)));
        bytes memory p0 = app.mockProof(c0, d); // a valid proof for channel `id`
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "proof"));
        vault.submitCheckpoint(other, c0, d, p0);
        // Cursors can't exceed the queues or move back.
        c2.depositCursor = 3;
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "deposit cursor"));
        vault.submitCheckpoint(id, c2, d, p);
        vault.submitCheckpoint(id, c, d, p);
        // Replay: the predecessor and nonce moved on.
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "proof"));
        vault.submitCheckpoint(id, c, d, p);
        c2.depositCursor = 0;
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "deposit cursor"));
        vault.submitCheckpoint(id, c2, d, p);
    }

    function test_exp2_forkedHistoryCannotContinue() public {
        _depositEth(alice, 1 ether);
        _depositEth(bob, 1 ether);
        app.consumeDeposits(2);
        uint256 snap = vm.snapshotState();
        // History B: alice pays bob, then B2 is proven on top of B1.
        app.transfer(alice, bob, address(0), 1 ether);
        _submit(false);
        app.transfer(bob, carol, address(0), 2 ether);
        AppChannelVault.Claim memory b2 = app.claim(false);
        bytes memory db2 = app.data();
        bytes memory pb2 = app.mockProof(b2, db2);
        vm.revertToState(snap);
        // History A is what L1 accepts instead (same nonce 1, other roots).
        app.transfer(alice, carol, address(0), 0.5 ether);
        _submit(false);
        // B2 has the right nonce (2) but extends B1, not A1: rejected.
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "proof"));
        vault.submitCheckpoint(id, b2, db2, pb2);
    }

    function test_exp2_backingCapsAnOverAllocation() public {
        // The MOCK accepts any roots; L1's per-token cap still bounds the damage. (A real proof
        // system is what prevents the over-allocation itself: experiment 3.)
        _depositEth(alice, 1 ether);
        app.consumeDeposits(1);
        app.transfer(alice, alice, address(0), 0);
        // Forge a ledger where both alice and bob hold 1 ETH out of a single 1 ETH deposit.
        AppLedger forged = new AppLedger(vault, id);
        forged.consumeDeposits(1);
        forged.forgeBalance(bob, address(0), 1 ether);
        forged.submit(true);
        (uint256 i, bytes32[] memory s,) = forged.proof(true, alice, address(0));
        vault.claimExit(id, alice, address(0), 1 ether, i, s);
        (i, s,) = forged.proof(true, bob, address(0));
        vm.expectRevert(AppChannelVault.InsufficientBacking.selector);
        vault.claimExit(id, bob, address(0), 1 ether, i, s);
    }

    function test_tokenRules() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "value"));
        vault.deposit{value: 1}(id, address(0), 2);
        TestToken other = new TestToken();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "token"));
        vault.deposit(id, address(other), 1);
        usd.setFee(100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AppChannelVault.Invalid.selector, "received amount"));
        vault.deposit(id, address(usd), 100e6);
    }

    function test_payoutDelayIsClamped() public {
        bytes32 tiny = _open(mock, 0);
        bytes32 huge = _open(mock, type(uint32).max);
        assertEq(vault.channel(tiny).payoutDelay, 1 hours);
        assertEq(vault.channel(huge).payoutDelay, 30 days);
    }

    // ---- experiment 2, fuzzed: whole sessions drain exactly ---------------------------------

    function testFuzz_exp2_randomSessionDrainsExactly(uint256 seed, bool closeNormally) public {
        uint256 r = seed;
        for (uint256 step; step < 24; ++step) {
            r = uint256(keccak256(abi.encode(r)));
            address u = users[r % 3];
            address v = users[(r >> 8) % 3];
            address t = (r >> 16) & 1 == 0 ? address(0) : address(usd);
            uint256 amt = ((r >> 24) % 5 + 1) * (t == address(0) ? 0.1 ether : 10e6);
            uint256 op = (r >> 40) % 6;
            if (op == 0 || op == 1) {
                t == address(0) ? _depositEth(u, amt) : _depositUsd(u, amt);
            } else if (op == 2) {
                app.transfer(u, v, t, amt / 2);
            } else if (op == 3) {
                app.withdraw(u, t, amt / 3);
            } else if (op == 4) {
                _checkpoint();
                (address[] memory rs, address[] memory ts) = app.keys();
                if (rs.length > 0) {
                    uint256 j = (r >> 48) % rs.length;
                    if (app.credit(keccak256(abi.encode(rs[j], ts[j]))) > vault.paidCredit(id, rs[j], ts[j])) {
                        (uint256 i, bytes32[] memory s, uint256 val) = app.proof(false, rs[j], ts[j]);
                        vault.claimCredit(id, rs[j], ts[j], val, i, s);
                    }
                }
            } else {
                vm.prank(u);
                vault.forceExit(id, t);
                _checkpoint(); // served in time
            }
        }
        if (closeNormally) {
            _checkpoint();
            _submit(true);
            _drainAll();
        } else {
            // The operator vanishes with whatever is unconsumed.
            vm.prank(alice);
            vault.forceExit(id, address(0));
            vm.warp(block.timestamp + 1 days);
            vault.freeze(id);
            vm.warp(block.timestamp + 2 days);
            // Claims come from the last ACCEPTED checkpoint, rebuilt from its published data;
            // anything the operator did after it was provisional.
            _drainWith(_recovered());
        }
        // Every unit that came in went out: totals match per token.
        assertEq(vault.totalIn(id, address(0)), vault.totalOut(id, address(0)));
        assertEq(vault.totalIn(id, address(usd)), vault.totalOut(id, address(usd)));
    }
}

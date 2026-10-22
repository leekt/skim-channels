// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {ChannelTypes} from "../src/libraries/ChannelTypes.sol";
import {WitnessLib} from "../src/libraries/WitnessLib.sol";
import {IAcceptedBlockRegistry} from "../src/interfaces/IAcceptedBlockRegistry.sol";
import {MockAcceptedBlockRegistry} from "../src/mocks/MockAcceptedBlockRegistry.sol";
import {AnchorRegistry} from "../src/AnchorRegistry.sol";
import {ChannelSettlement} from "../src/ChannelSettlement.sol";
import {ChannelExecutor} from "../src/ChannelExecutor.sol";
import {L2AnchorInbox} from "../src/L2AnchorInbox.sol";
import {SplitModule} from "../src/examples/SplitModule.sol";
import {RLPEncode} from "./helpers/RLPEncode.sol";
import {CanonicalBlockRegistry} from "../src/CanonicalBlockRegistry.sol";
import {MockTransitionVerifier} from "../src/mocks/MockTransitionVerifier.sol";

/// Tries to write state from compute(). Approved by code hash, so only STATICCALL stops it.
contract WritingModule {
    uint256 public calls;

    function compute(bytes calldata, WitnessLib.Read[] calldata, uint256) external returns (bytes memory) {
        calls++;
        uint256[] memory p = new uint256[](2);
        p[0] = 2 ether;
        return abi.encode(p);
    }
}

/// Approved, but pays out more than the escrow: only settlement's conservation check stops it.
contract GreedyModule {
    function compute(bytes calldata, WitnessLib.Read[] calldata, uint256) external pure returns (bytes memory) {
        uint256[] memory p = new uint256[](2);
        p[0] = 3 ether;
        return abi.encode(p);
    }
}

/// Never approved.
contract RogueModule {
    function compute(bytes calldata, WitnessLib.Read[] calldata, uint256) external pure returns (bytes memory) {
        uint256[] memory p = new uint256[](2);
        p[0] = 2 ether;
        return abi.encode(p);
    }
}

/// Emits a ChannelOutcome-shaped log from the wrong contract.
contract Impostor {
    event ChannelOutcome(
        bytes32 indexed channelId,
        bytes32 indexed requestHash,
        bytes32 anchorId,
        bytes32 policyHash,
        bytes32 outcomeHash
    );

    function emitOutcome(bytes32 c, bytes32 r, bytes32 a, bytes32 p, bytes32 o) external {
        emit ChannelOutcome(c, r, a, p, o);
    }
}

/// The Read-and-Split MVP (PROJECT.md §9) and the settlement security tests (§12), with L1 and
/// L2 contracts in one EVM. Block acceptance is the labeled MOCK registry.
contract ChannelTest is Test {
    uint256 constant L1 = 11155111;
    bytes32 constant ROLLUP = keccak256("rollup");
    uint256 constant DEADLINE = 1_800_000_000;

    string wjson;
    address fixture;
    bytes32 shareSlot;

    MockAcceptedBlockRegistry registry;
    AnchorRegistry anchors;
    ChannelSettlement settlement;
    L2AnchorInbox inbox;
    ChannelExecutor executor;
    SplitModule split;
    WritingModule writer;
    RogueModule rogue;
    GreedyModule greedy;

    bytes32 profileHash;
    ChannelTypes.ChannelPolicy policy;

    uint256 aliceKey = 0xA11CE;
    uint256 bobKey = 0xB0B;
    address alice;
    address bob;
    address[] participants;
    uint256[] keys;

    function setUp() public {
        vm.chainId(L1);
        vm.warp(1_700_000_000);
        wjson = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/read-and-split.json"));
        fixture = vm.parseJsonAddress(wjson, ".fixture");
        shareSlot = vm.parseJsonBytes32(wjson, ".shareSlot");

        alice = vm.addr(aliceKey);
        bob = vm.addr(bobKey);
        (participants, keys) =
            alice < bob ? (_pair(alice, bob), _pairU(aliceKey, bobKey)) : (_pair(bob, alice), _pairU(bobKey, aliceKey));

        registry = new MockAcceptedBlockRegistry(address(this));
        anchors = new AnchorRegistry();
        inbox = new L2AnchorInbox(address(this), L1);
        split = new SplitModule();
        writer = new WritingModule();
        rogue = new RogueModule();
        greedy = new GreedyModule();
        profileHash = ChannelTypes.profileHash(
            ChannelTypes.ExecutionProfile({
                rollupId: ROLLUP,
                kind: ChannelTypes.PROFILE_MOCK_LOCAL,
                genesisHash: keccak256("genesis"),
                programHash: keccak256("program"),
                forkSchemaHash: keccak256("fork"),
                daSchemaHash: keccak256("da"),
                executorCodeHash: keccak256("executor")
            })
        );
        address[] memory mods = new address[](3);
        mods[0] = address(split);
        mods[1] = address(writer);
        mods[2] = address(greedy);
        executor = new ChannelExecutor(profileHash, L1, inbox, mods);
        settlement = new ChannelSettlement(ROLLUP, profileHash, ChannelTypes.PROFILE_MOCK_LOCAL, registry, anchors);
        policy = ChannelTypes.ChannelPolicy({anchorConfirmation: 2, maxAnchorLag: 64});

        // L1 anchors H0 (100) and H1 (101): posted to L2, authenticated on L1 by blockhash.
        bytes memory raw0 = vm.parseJsonBytes(wjson, ".h0.rawHeader");
        bytes memory raw1 = vm.parseJsonBytes(wjson, ".h1.rawHeader");
        inbox.post(raw0);
        inbox.post(raw1);
        vm.roll(200);
        vm.setBlockhash(100, keccak256(raw0));
        vm.setBlockhash(101, keccak256(raw1));
        anchors.record(raw1);
    }

    function _pair(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    function _pairU(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (a, b);
    }

    // ---- channel setup ----------------------------------------------------------------

    function _terms(bytes32 salt, address module) internal view returns (ChannelTypes.ChannelTerms memory) {
        return ChannelTypes.ChannelTerms({
            channelId: ChannelTypes.channelId(L1, address(settlement), alice, salt),
            rollupId: ROLLUP,
            settlementContract: address(settlement),
            executor: address(executor),
            moduleCodeHash: module.codehash,
            participantRoot: ChannelTypes.participantRoot(participants),
            policyHash: ChannelTypes.policyHash(policy),
            closeDeadline: uint64(DEADLINE)
        });
    }

    function _openAndFund(bytes32 salt, address module) internal returns (ChannelTypes.ChannelTerms memory t) {
        t = _terms(salt, module);
        uint256[] memory deposits = new uint256[](2);
        deposits[0] = 1 ether;
        deposits[1] = 1 ether;
        vm.prank(alice);
        settlement.open(abi.encode(t), participants, deposits, salt);
        for (uint256 i; i < 2; ++i) {
            vm.deal(participants[i], 1 ether);
            vm.prank(participants[i]);
            settlement.fund{value: 1 ether}(t.channelId);
        }
    }

    function _input() internal view returns (bytes memory) {
        return abi.encode(fixture, shareSlot, 2 ether);
    }

    function _call(ChannelTypes.ChannelTerms memory t, string memory h, bytes memory input)
        internal
        view
        returns (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r)
    {
        r = ChannelTypes.FinalRequest({
            channelId: t.channelId,
            termsHash: ChannelTypes.termsHash(t),
            anchorId: vm.parseJsonBytes32(wjson, string.concat(h, ".anchor.id")),
            policyHash: t.policyHash,
            executionProfileHash: profileHash,
            inputHash: keccak256(input),
            nonce: 1
        });
        c = ChannelExecutor.Call({
            terms: abi.encode(t),
            policy: abi.encode(policy),
            request: abi.encode(r),
            input: input,
            witness: vm.parseJsonBytes(wjson, string.concat(h, ".package")),
            participants: participants,
            signatures: _sign(r, keys)
        });
    }

    function _sign(ChannelTypes.FinalRequest memory r, uint256[] memory ks)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 digest = ChannelTypes.requestSigningHash(r, L1, address(settlement));
        sigs = new bytes[](ks.length);
        for (uint256 i; i < ks.length; ++i) {
            (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(ks[i], digest);
            sigs[i] = abi.encodePacked(rr, ss, v);
        }
    }

    // ---- L2 block / evidence -------------------------------------------------------------

    /// Executes on "L2", wraps the emitted log in an EIP-1559 receipt at index 0 of a one-leaf
    /// receipt trie, builds the L2 header, and (if `accept`) mock-accepts the block on L1.
    function _executeAndProve(ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r, bool accept)
        internal
        returns (bytes memory evidence)
    {
        vm.recordLogs();
        bytes memory outcome = executor.execute(c);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        return _prove(logs, c.request, outcome, r.anchorId, accept);
    }

    function _prove(Vm.Log[] memory logs, bytes memory request, bytes memory outcome, bytes32 anchorId, bool accept)
        internal
        returns (bytes memory)
    {
        return _prove(logs, request, outcome, anchorId, accept, 1);
    }

    function _prove(
        Vm.Log[] memory logs,
        bytes memory request,
        bytes memory outcome,
        bytes32 anchorId,
        bool accept,
        uint256 status
    ) internal returns (bytes memory) {
        bytes[] memory encLogs = new bytes[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            bytes[] memory topics = new bytes[](logs[i].topics.length);
            for (uint256 j; j < topics.length; ++j) {
                topics[j] = RLPEncode.str(abi.encodePacked(logs[i].topics[j]));
            }
            bytes[] memory f = new bytes[](3);
            f[0] = RLPEncode.str(abi.encodePacked(logs[i].emitter));
            f[1] = RLPEncode.list(topics);
            f[2] = RLPEncode.str(logs[i].data);
            encLogs[i] = RLPEncode.list(f);
        }
        bytes[] memory rf = new bytes[](4);
        rf[0] = RLPEncode.num(status);
        rf[1] = RLPEncode.num(100_000);
        rf[2] = RLPEncode.str(new bytes(256));
        rf[3] = RLPEncode.list(encLogs);
        bytes memory receipt = bytes.concat(hex"02", RLPEncode.list(rf));

        // One-leaf trie: key RLP(0) = 0x80, even-length leaf path → compact 0x20 0x80.
        bytes[] memory leafF = new bytes[](2);
        leafF[0] = RLPEncode.str(hex"2080");
        leafF[1] = RLPEncode.str(receipt);
        bytes memory leaf = RLPEncode.list(leafF);
        bytes32 receiptsRoot = keccak256(leaf);
        bytes[] memory proof = new bytes[](1);
        proof[0] = leaf;

        bytes memory header = _l2Header(receiptsRoot);
        bytes32 blockHash = keccak256(header);
        if (accept) {
            registry.mockAccept(
                ROLLUP,
                blockHash,
                IAcceptedBlockRegistry.AcceptedBlock({
                    parentHash: keccak256("l2-parent"),
                    stateRoot: keccak256("l2-state"),
                    receiptsRoot: receiptsRoot,
                    l1AnchorId: anchorId,
                    executionProfileHash: profileHash,
                    blockNumber: 1,
                    accepted: true
                })
            );
        }
        return abi.encode(
            ChannelSettlement.Evidence({
                l2BlockHash: blockHash,
                l2Header: header,
                txIndex: 0,
                receipt: receipt,
                receiptProof: proof,
                logIndex: 0,
                request: request,
                outcome: outcome
            })
        );
    }

    uint256 headerSalt;
    bytes32 l2Parent = keccak256("l2-parent");
    uint256 l2Number = 1;

    function _l2Header(bytes32 receiptsRoot) internal returns (bytes memory) {
        bytes[] memory f = new bytes[](15);
        f[0] = RLPEncode.str(abi.encodePacked(l2Parent));
        f[1] = RLPEncode.str(abi.encodePacked(bytes32(0)));
        f[2] = RLPEncode.str(abi.encodePacked(address(0)));
        f[3] = RLPEncode.str(abi.encodePacked(keccak256("l2-state")));
        f[4] = RLPEncode.str(abi.encodePacked(bytes32(0)));
        f[5] = RLPEncode.str(abi.encodePacked(receiptsRoot));
        f[6] = RLPEncode.str(new bytes(256));
        f[7] = RLPEncode.num(0);
        f[8] = RLPEncode.num(l2Number);
        f[9] = RLPEncode.num(30_000_000);
        f[10] = RLPEncode.num(100_000);
        f[11] = RLPEncode.num(1_700_000_000 + headerSalt++);
        f[12] = RLPEncode.str("");
        f[13] = RLPEncode.str(abi.encodePacked(bytes32(0)));
        f[14] = RLPEncode.str(new bytes(8));
        return RLPEncode.list(f);
    }

    function _payouts(bytes memory outcome) internal pure returns (uint256[] memory) {
        return abi.decode(outcome, (uint256[]));
    }

    function _aliceShare(uint256[] memory p) internal view returns (uint256) {
        return participants[0] == alice ? p[0] : p[1];
    }

    // ---- the MVP ---------------------------------------------------------------------------

    function test_readAndSplit_previewH0_settleH1_once() public {
        ChannelTypes.ChannelTerms memory t = _openAndFund("s1", address(split));
        assertEq(uint8(settlement.channel(t.channelId).status), uint8(ChannelSettlement.Status.Open));
        // Payout order follows participant order; the split module pays participant 0 the share.
        (ChannelExecutor.Call memory c0,) = _call(t, ".h0", _input());
        uint256[] memory p0 = _payouts(executor.preview(c0));
        assertEq(p0[0], 1.2 ether);
        assertEq(p0[1], 0.8 ether);

        // Same open channel, newer anchor: no reopen.
        (ChannelExecutor.Call memory c1, ChannelTypes.FinalRequest memory r1) = _call(t, ".h1", _input());
        vm.record();
        bytes memory evidence = _executeAndProve(c1, r1, true);
        (, bytes32[] memory writes) = vm.accesses(address(executor));
        assertEq(writes.length, 0, "executor wrote storage");

        settlement.settle(t.channelId, evidence);
        assertEq(uint8(settlement.channel(t.channelId).status), uint8(ChannelSettlement.Status.Settled));
        assertEq(settlement.withdrawable(participants[0]), 1.4 ether);
        assertEq(settlement.withdrawable(participants[1]), 0.6 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ChannelSettlement.WrongStatus.selector, ChannelSettlement.Status.Settled)
        );
        settlement.settle(t.channelId, evidence);
        vm.expectRevert(
            abi.encodeWithSelector(ChannelSettlement.WrongStatus.selector, ChannelSettlement.Status.Settled)
        );
        vm.warp(DEADLINE);
        settlement.refund(t.channelId);

        uint256 before = participants[0].balance;
        vm.prank(participants[0]);
        settlement.withdraw();
        assertEq(participants[0].balance - before, 1.4 ether);
        assertEq(settlement.withdrawable(participants[0]), 0);
    }

    // ---- L2 execution policy -------------------------------------------------------------

    function test_persistentWriteRejectedByStaticcall() public {
        ChannelTypes.ChannelTerms memory t = _openAndFund("w", address(writer));
        (ChannelExecutor.Call memory c,) = _call(t, ".h1", _input());
        vm.expectRevert();
        executor.execute(c);
        assertEq(writer.calls(), 0);
    }

    function test_unapprovedModuleRejected() public {
        ChannelTypes.ChannelTerms memory t = _openAndFund("r", address(rogue));
        (ChannelExecutor.Call memory c,) = _call(t, ".h1", _input());
        vm.expectRevert(abi.encodeWithSelector(ChannelExecutor.UnapprovedModule.selector, address(rogue).codehash));
        executor.execute(c);
    }

    function test_signaturesAndBindingsEnforcedOnL2() public {
        ChannelTypes.ChannelTerms memory t = _openAndFund("b", address(split));
        // (Memory structs alias in Solidity: every case builds a fresh call.)
        // Missing one signer.
        (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r) = _call(t, ".h1", _input());
        c.signatures = _sign(r, _pairU(keys[0], 0xBAD));
        vm.expectRevert(abi.encodeWithSelector(ChannelExecutor.BadSignature.selector, 1));
        executor.preview(c);
        // Request modified after signing.
        (c, r) = _call(t, ".h1", _input());
        r.nonce = 2;
        c.request = abi.encode(r);
        vm.expectRevert(abi.encodeWithSelector(ChannelExecutor.BadSignature.selector, 0));
        executor.preview(c);
        // Input other than the signed one.
        (c, r) = _call(t, ".h1", _input());
        c.input = abi.encode(fixture, shareSlot, 3 ether);
        vm.expectRevert(abi.encodeWithSelector(ChannelExecutor.Mismatch.selector, "input"));
        executor.preview(c);
        // H0's witness under a request for H1.
        (c, r) = _call(t, ".h1", _input());
        c.witness = vm.parseJsonBytes(wjson, ".h0.package");
        vm.expectRevert(abi.encodeWithSelector(ChannelExecutor.Mismatch.selector, "anchor"));
        executor.preview(c);
        // Mixed-root witness relabeled as H1.
        (c, r) = _call(t, ".h1", _input());
        c.witness = vm.parseJsonBytes(wjson, ".bad.mixedRoots");
        vm.expectRevert();
        executor.preview(c);
        // Terms of another channel.
        (c, r) = _call(t, ".h1", _input());
        ChannelTypes.ChannelTerms memory t2 = _terms("other", address(split));
        c.terms = abi.encode(t2);
        vm.expectRevert(abi.encodeWithSelector(ChannelExecutor.Mismatch.selector, "channel"));
        executor.preview(c);
        // Unmodified, it runs.
        (c, r) = _call(t, ".h1", _input());
        executor.preview(c);
    }

    function test_anchorUnknownToInboxRejected() public {
        L2AnchorInbox empty = new L2AnchorInbox(address(this), L1);
        address[] memory mods = new address[](1);
        mods[0] = address(split);
        ChannelExecutor ex2 = new ChannelExecutor(profileHash, L1, empty, mods);
        ChannelTypes.ChannelTerms memory t = _terms("x", address(split));
        t.executor = address(ex2);
        (ChannelExecutor.Call memory c,) = _call(t, ".h1", _input());
        vm.expectRevert();
        ex2.preview(c);
    }

    // ---- L1 settlement verification ---------------------------------------------------

    function test_unacceptedBlockRejected() public {
        ChannelTypes.ChannelTerms memory t = _openAndFund("u", address(split));
        (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r) = _call(t, ".h1", _input());
        bytes memory evidence = _executeAndProve(c, r, false);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "block not accepted"));
        settlement.settle(t.channelId, evidence);
    }

    function test_mockRegistryRejectedUnderNativeProfile() public {
        ChannelSettlement native = new ChannelSettlement(
            ROLLUP, profileHash, ChannelTypes.PROFILE_NATIVE_PROOF_DEPENDENCIES, registry, anchors
        );
        ChannelTypes.ChannelTerms memory t = _terms("n", address(split));
        t.settlementContract = address(native);
        t.channelId = ChannelTypes.channelId(L1, address(native), alice, "n");
        uint256[] memory deposits = _pairU(1 ether, 1 ether);
        vm.prank(alice);
        native.open(abi.encode(t), participants, deposits, "n");
        for (uint256 i; i < 2; ++i) {
            vm.deal(participants[i], 1 ether);
            vm.prank(participants[i]);
            native.fund{value: 1 ether}(t.channelId);
        }
        (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r) = _call(t, ".h1", _input());
        // Signatures are domain-bound to `native`; re-sign for it.
        bytes32 digest = ChannelTypes.requestSigningHash(r, L1, address(native));
        for (uint256 i; i < 2; ++i) {
            (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(keys[i], digest);
            c.signatures[i] = abi.encodePacked(rr, ss, v);
        }
        bytes memory evidence = _executeAndProve(c, r, true);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "registry profile kind"));
        native.settle(t.channelId, evidence);
    }

    function test_forgedEmitterRejected() public {
        ChannelTypes.ChannelTerms memory t = _openAndFund("f", address(split));
        (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r) = _call(t, ".h1", _input());
        bytes memory outcome = executor.preview(c);
        Impostor imp = new Impostor();
        vm.recordLogs();
        imp.emitOutcome(
            t.channelId,
            ChannelTypes.requestSigningHash(r, L1, address(settlement)),
            r.anchorId,
            r.policyHash,
            keccak256(outcome)
        );
        bytes memory evidence = _prove(vm.getRecordedLogs(), c.request, outcome, r.anchorId, true);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "emitter"));
        settlement.settle(t.channelId, evidence);
    }

    function test_modifiedOutcomeOrRequestRejected() public {
        ChannelTypes.ChannelTerms memory t = _openAndFund("m", address(split));
        (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r) = _call(t, ".h1", _input());
        bytes memory evidence = _executeAndProve(c, r, true);
        ChannelSettlement.Evidence memory e = abi.decode(evidence, (ChannelSettlement.Evidence));
        // Payouts swapped (still conserving).
        ChannelSettlement.Evidence memory bad = e;
        uint256[] memory p = _payouts(e.outcome);
        (p[0], p[1]) = (p[1], p[0]);
        bad.outcome = abi.encode(p);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "log data"));
        settlement.settle(t.channelId, abi.encode(bad));
        // Request swapped for one with another nonce.
        bad = abi.decode(evidence, (ChannelSettlement.Evidence));
        ChannelTypes.FinalRequest memory r2 = r;
        r2.nonce = 9;
        bad.request = abi.encode(r2);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "log binding"));
        settlement.settle(t.channelId, abi.encode(bad));
        // Receipt bytes tampered (status byte) without a matching proof.
        bad = abi.decode(evidence, (ChannelSettlement.Evidence));
        bad.receipt[3] = 0x80; // status 1 → 0
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "receipt proof"));
        settlement.settle(t.channelId, abi.encode(bad));
        // Header of another block.
        bad = abi.decode(evidence, (ChannelSettlement.Evidence));
        bad.l2Header = _l2Header(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "header"));
        settlement.settle(t.channelId, abi.encode(bad));
        // The honest evidence still settles.
        settlement.settle(t.channelId, evidence);
    }

    function test_nonConservingOutcomeRejected() public {
        ChannelTypes.ChannelTerms memory t = _openAndFund("g", address(greedy));
        (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r) = _call(t, ".h1", _input());
        bytes memory evidence = _executeAndProve(c, r, true);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "conservation"));
        settlement.settle(t.channelId, evidence);
    }

    function test_failedReceiptRejected() public {
        // An accepted block whose receipt carries the outcome log but status 0.
        ChannelTypes.ChannelTerms memory t = _openAndFund("fr", address(split));
        (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r) = _call(t, ".h1", _input());
        vm.recordLogs();
        bytes memory outcome = executor.execute(c);
        bytes memory evidence = _prove(vm.getRecordedLogs(), c.request, outcome, r.anchorId, true, 0);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "receipt status"));
        settlement.settle(t.channelId, evidence);
    }

    CanonicalBlockRegistry canon;
    MockTransitionVerifier mockVerifier;

    function _canonicalSettlement() internal returns (ChannelSettlement s2) {
        mockVerifier = new MockTransitionVerifier();
        uint256 n = l2Number;
        (l2Parent, l2Number) = (bytes32(0), 0);
        bytes memory genesis = _l2Header(bytes32(0));
        // Blocks built from here on extend this genesis.
        (l2Parent, l2Number) = (keccak256(genesis), n);
        canon = new CanonicalBlockRegistry(ROLLUP, profileHash, mockVerifier, anchors, genesis);
        s2 = new ChannelSettlement(ROLLUP, profileHash, ChannelTypes.PROFILE_MOCK_LOCAL, canon, anchors);
    }

    function test_settlesThroughCanonicalRegistry() public {
        // Same flow, but the L2 block is accepted by lineage + L1 anchor + blob DA + verifier
        // (here the labeled MOCK verifier) instead of an operator assertion.
        settlement = _canonicalSettlement(); // _terms/_call/_sign bind to `settlement`
        ChannelTypes.ChannelTerms memory t = _openAndFund("canon", address(split));
        (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r) = _call(t, ".h1", _input());
        bytes memory evidence = _executeAndProve(c, r, false);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "block not accepted"));
        settlement.settle(t.channelId, evidence);
        _submitCanonical(evidence, r.anchorId);
        settlement.settle(t.channelId, evidence);
        assertEq(settlement.withdrawable(participants[0]), 1.4 ether);
    }

    function _submitCanonical(bytes memory evidence, bytes32 anchorId) internal {
        ChannelSettlement.Evidence memory e = abi.decode(evidence, (ChannelSettlement.Evidence));
        bytes32[] memory blobs = new bytes32[](1);
        blobs[0] = bytes32(uint256(0x01) << 248 | 0x1);
        vm.blobhashes(blobs);
        assertEq(canon.submit(e.l2Header, anchorId, abi.encodePacked(mockVerifier.MOCK_PROOF())), e.l2BlockHash);
    }

    function test_crossChannelReuseRejected() public {
        ChannelTypes.ChannelTerms memory ta = _openAndFund("A", address(split));
        ChannelTypes.ChannelTerms memory tb = _openAndFund("B", address(split));
        (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r) = _call(ta, ".h1", _input());
        bytes memory evidence = _executeAndProve(c, r, true);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "log binding"));
        settlement.settle(tb.channelId, evidence);
        settlement.settle(ta.channelId, evidence);
    }

    function test_anchorNotOnL1Rejected() public {
        // H0 was posted to the L2 inbox but never recorded on L1.
        ChannelTypes.ChannelTerms memory t = _openAndFund("h0", address(split));
        (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r) = _call(t, ".h0", _input());
        bytes memory evidence = _executeAndProve(c, r, true);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "anchor not recorded on L1"));
        settlement.settle(t.channelId, evidence);
        // Recording needs L1's own block hash at that height.
        bytes memory raw0 = vm.parseJsonBytes(wjson, ".h0.rawHeader");
        vm.setBlockhash(100, keccak256("other block"));
        vm.expectRevert();
        anchors.record(raw0);
        vm.setBlockhash(100, keccak256(raw0));
        anchors.record(raw0);
        settlement.settle(t.channelId, evidence);
    }

    // ---- terminal transitions ------------------------------------------------------------

    function test_deadlineBoundaryExactlyOneTransition() public {
        ChannelTypes.ChannelTerms memory t = _openAndFund("d", address(split));
        (ChannelExecutor.Call memory c, ChannelTypes.FinalRequest memory r) = _call(t, ".h1", _input());
        bytes memory evidence = _executeAndProve(c, r, true);
        vm.warp(DEADLINE - 1);
        vm.expectRevert(ChannelSettlement.Deadline.selector);
        settlement.refund(t.channelId);
        vm.warp(DEADLINE);
        vm.expectRevert(ChannelSettlement.Deadline.selector);
        settlement.settle(t.channelId, evidence);
        settlement.refund(t.channelId);
        vm.expectRevert(
            abi.encodeWithSelector(ChannelSettlement.WrongStatus.selector, ChannelSettlement.Status.Refunded)
        );
        settlement.settle(t.channelId, evidence);
    }

    function test_refundWithoutSequencerExactlyOnce() public {
        ChannelTypes.ChannelTerms memory t = _openAndFund("rf", address(split));
        vm.warp(DEADLINE);
        vm.prank(address(0xdead)); // anyone
        settlement.refund(t.channelId);
        assertEq(settlement.withdrawable(alice), 1 ether);
        assertEq(settlement.withdrawable(bob), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ChannelSettlement.WrongStatus.selector, ChannelSettlement.Status.Refunded)
        );
        settlement.refund(t.channelId);
        vm.prank(bob);
        settlement.withdraw();
        assertEq(bob.balance, 1 ether);
    }

    function test_fundingTimeoutRefundsOnlyFunded() public {
        ChannelTypes.ChannelTerms memory t = _terms("ft", address(split));
        vm.prank(alice);
        settlement.open(abi.encode(t), participants, _pairU(1 ether, 1 ether), "ft");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        settlement.fund{value: 1 ether}(t.channelId);
        vm.warp(DEADLINE);
        settlement.refund(t.channelId);
        assertEq(settlement.withdrawable(alice), 1 ether);
        assertEq(settlement.withdrawable(bob), 0);
    }

    function test_openValidation() public {
        ChannelTypes.ChannelTerms memory t = _terms("ov", address(split));
        uint256[] memory d = _pairU(1 ether, 1 ether);
        vm.prank(bob); // channel id is bound to the opener
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "channel id"));
        settlement.open(abi.encode(t), participants, d, "ov");
        vm.prank(alice);
        settlement.open(abi.encode(t), participants, d, "ov");
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ChannelSettlement.WrongStatus.selector, ChannelSettlement.Status.Funding)
        );
        settlement.open(abi.encode(t), participants, d, "ov");
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ChannelSettlement.Invalid.selector, "amount"));
        settlement.fund{value: 2 ether}(t.channelId);
    }

    // ---- properties -------------------------------------------------------------------------

    function testFuzz_splitConserves(uint16 bps, uint128 total) public view {
        bps = uint16(bound(bps, 0, 10_000));
        WitnessLib.Read[] memory reads = new WitnessLib.Read[](1);
        reads[0] = WitnessLib.Read(fixture, shareSlot, bps);
        uint256[] memory p =
            abi.decode(split.compute(abi.encode(fixture, shareSlot, uint256(total)), reads, 2), (uint256[]));
        assertEq(p[0] + p[1], total);
        assertEq(p[0], uint256(total) * bps / 10_000);
    }
}

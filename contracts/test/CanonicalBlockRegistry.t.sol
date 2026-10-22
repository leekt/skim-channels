// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CanonicalBlockRegistry} from "../src/CanonicalBlockRegistry.sol";
import {MockTransitionVerifier} from "../src/mocks/MockTransitionVerifier.sol";
import {IStateTransitionVerifier} from "../src/interfaces/IStateTransitionVerifier.sol";
import {AnchorRegistry} from "../src/AnchorRegistry.sol";
import {ChannelTypes} from "../src/libraries/ChannelTypes.sol";
import {RLPEncode} from "./helpers/RLPEncode.sol";
import {RollupGovernance} from "../src/RollupGovernance.sol";
import {ForcedInclusionQueue} from "../src/queues/ForcedInclusionQueue.sol";
import {IL1MessageQueue} from "../src/interfaces/IL1MessageQueue.sol";

contract RejectingVerifier is IStateTransitionVerifier {
    function profileKind() external pure returns (uint8) {
        return ChannelTypes.PROFILE_NATIVE_REEXECUTION_DEVNET;
    }

    function verify(Transition calldata, bytes calldata) external pure returns (bool) {
        return false;
    }
}

/// Accepts only if the proof commits to the forced-transaction accumulator it was given.
contract AccCheckingVerifier is IStateTransitionVerifier {
    function profileKind() external pure returns (uint8) {
        return ChannelTypes.PROFILE_MOCK_LOCAL;
    }

    function verify(Transition calldata t, bytes calldata proof) external pure returns (bool) {
        return keccak256(proof) == keccak256(abi.encode(t.l1MessagesRoot));
    }
}

contract CanonicalBlockRegistryTest is Test {
    bytes32 constant ROLLUP = keccak256("rollup");
    bytes32 constant PROFILE = keccak256("profile");
    AnchorRegistry anchors;
    MockTransitionVerifier mockV;
    CanonicalBlockRegistry reg;
    bytes genesis;
    bytes32 anchorId;
    bytes proof;
    RollupGovernance gov;
    ForcedInclusionQueue queue;

    function _registry(IStateTransitionVerifier v, bool blobDA) internal returns (CanonicalBlockRegistry) {
        return new CanonicalBlockRegistry(
            CanonicalBlockRegistry.Config(ROLLUP, PROFILE, v, anchors, queue, address(gov), blobDA), genesis
        );
    }
    address constant COUNCIL = address(0xC0C);

    function _header(bytes32 parent, uint256 number, bytes32 salt) internal pure returns (bytes memory) {
        bytes[] memory f = new bytes[](15);
        f[0] = RLPEncode.str(abi.encodePacked(parent));
        f[1] = RLPEncode.str(abi.encodePacked(bytes32(0)));
        f[2] = RLPEncode.str(abi.encodePacked(address(0)));
        f[3] = RLPEncode.str(abi.encodePacked(keccak256(abi.encode("state", number, salt))));
        f[4] = RLPEncode.str(abi.encodePacked(bytes32(0)));
        f[5] = RLPEncode.str(abi.encodePacked(keccak256(abi.encode("receipts", number, salt))));
        f[6] = RLPEncode.str(new bytes(256));
        f[7] = RLPEncode.num(0);
        f[8] = RLPEncode.num(number);
        f[9] = RLPEncode.num(30_000_000);
        f[10] = RLPEncode.num(0);
        f[11] = RLPEncode.num(1_700_000_000 + number);
        f[12] = RLPEncode.str("");
        f[13] = RLPEncode.str(abi.encodePacked(bytes32(0)));
        f[14] = RLPEncode.str(new bytes(8));
        return RLPEncode.list(f);
    }

    function setUp() public {
        anchors = new AnchorRegistry();
        mockV = new MockTransitionVerifier();
        genesis = _header(bytes32(0), 0, "g");
        gov = new RollupGovernance(address(this), COUNCIL);
        queue = new ForcedInclusionQueue();
        reg = _registry(mockV, true);
        gov.bind(reg);
        // A real L1 anchor: an L1 header whose hash this chain reports at its height.
        bytes memory l1 = _header(keccak256("l1-parent"), 5, "l1");
        vm.roll(10);
        vm.setBlockhash(5, keccak256(l1));
        anchorId = anchors.record(l1);
        proof = abi.encodePacked(mockV.MOCK_PROOF());
        bytes32[] memory blobs = new bytes32[](1);
        blobs[0] = bytes32(uint256(0x01) << 248 | 0xda);
        vm.blobhashes(blobs);
    }

    function test_extendsCanonicalChain() public {
        bytes memory b1 = _header(keccak256(genesis), 1, "a");
        bytes32 h1 = reg.submit(b1, anchorId, 0, proof);
        assertEq(reg.head(), h1);
        assertTrue(reg.isAcceptedBlock(ROLLUP, h1));
        assertFalse(reg.isAcceptedBlock(keccak256("other rollup"), h1));
        assertEq(
            reg.acceptedBlock(ROLLUP, h1).receiptsRoot, keccak256(abi.encode("receipts", uint256(1), bytes32("a")))
        );
        assertEq(reg.acceptedBlock(ROLLUP, h1).executionProfileHash, PROFILE);
        assertEq(reg.profileKind(), ChannelTypes.PROFILE_MOCK_LOCAL);
        // Permissionless: anyone extends it.
        vm.prank(address(0xbeef));
        reg.submit(_header(h1, 2, "b"), anchorId, 0, proof);
    }

    function test_competingForkRejected() public {
        reg.submit(_header(keccak256(genesis), 1, "a"), anchorId, 0, proof);
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "not on the canonical tip"));
        reg.submit(_header(keccak256(genesis), 1, "competitor"), anchorId, 0, proof);
    }

    function test_wrongParentOrNumberRejected() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "not on the canonical tip"));
        reg.submit(_header(keccak256("unknown"), 1, "a"), anchorId, 0, proof);
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "number"));
        reg.submit(_header(keccak256(genesis), 2, "a"), anchorId, 0, proof);
    }

    function test_unrecordedAnchorRejected() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "L1 anchor not recorded"));
        reg.submit(_header(keccak256(genesis), 1, "a"), keccak256("fake anchor"), 0, proof);
    }

    function test_missingBlobRejected() public {
        vm.blobhashes(new bytes32[](0));
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "no blob: data not on L1"));
        reg.submit(_header(keccak256(genesis), 1, "a"), anchorId, 0, proof);
    }

    function test_unverifiedTransitionRejected() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "transition not verified"));
        reg.submit(_header(keccak256(genesis), 1, "a"), anchorId, 0, hex"00");
        CanonicalBlockRegistry strict = _registry(new RejectingVerifier(), true);
        assertEq(strict.profileKind(), ChannelTypes.PROFILE_NATIVE_REEXECUTION_DEVNET);
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "transition not verified"));
        strict.submit(_header(keccak256(genesis), 1, "a"), anchorId, 0, proof);
    }

    function test_genesisMustBeBlockZero() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "genesis number"));
        new CanonicalBlockRegistry(
            CanonicalBlockRegistry.Config(ROLLUP, PROFILE, mockV, anchors, queue, address(gov), true),
            _header(bytes32(0), 1, "g")
        );
    }

    // ---- forced inclusion ---------------------------------------------------------------

    function test_overdueForcedTransactionMustBeIncluded() public {
        queue.forceInclude(hex"02f8aa01");
        assertEq(queue.count(), 1);
        bytes32 g = keccak256(genesis);
        // Not overdue yet: a block may skip it.
        bytes32 h1 = reg.submit(_header(g, 1, "a"), anchorId, 0, proof);
        vm.warp(block.timestamp + reg.FORCE_DELAY());
        vm.expectRevert(
            abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "overdue L1 message not included")
        );
        reg.submit(_header(h1, 2, "b"), anchorId, 0, proof);
        vm.expectRevert(); // past the end of the queue
        reg.submit(_header(h1, 2, "b"), anchorId, 2, proof);
        bytes32 h2 = reg.submit(_header(h1, 2, "b"), anchorId, 1, proof);
        assertEq(reg.messageCursor(), 1);
        // The cursor never moves back.
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "message cursor"));
        reg.submit(_header(h2, 3, "c"), anchorId, 0, proof);
    }

    function test_verifierSeesForcedAccumulator() public {
        AccCheckingVerifier v = new AccCheckingVerifier();
        CanonicalBlockRegistry r = _registry(v, true);
        queue.forceInclude(hex"aa");
        bytes32 acc1 = keccak256(hex"aa"); // a one-message root is the message hash itself
        assertEq(queue.messagesRoot(0, 1), acc1);
        bytes32 g = keccak256(genesis);
        // Claiming inclusion with a proof for the empty accumulator fails.
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "transition not verified"));
        r.submit(_header(g, 1, "a"), anchorId, 1, abi.encode(bytes32(0)));
        r.submit(_header(g, 1, "a"), anchorId, 1, abi.encode(acc1));
    }

    // ---- faults and governance -----------------------------------------------------------

    function _transition(bytes memory header) internal view returns (IStateTransitionVerifier.Transition memory) {
        return IStateTransitionVerifier.Transition({
            profileHash: PROFILE,
            parentStateRoot: keccak256("parent-state"),
            daCommitment: keccak256("da"),
            l1AnchorId: anchorId,
            l1MessagesRoot: 0,
            rawHeader: header
        });
    }

    function test_provenConflictFreezesAndOnlyThenCouncilActs() public {
        bytes32 g = keccak256(genesis);
        bytes32 h1 = reg.submit(_header(g, 1, "a"), anchorId, 0, proof);
        MockTransitionVerifier repaired = new MockTransitionVerifier();
        // No fault yet: the council can't act.
        vm.prank(COUNCIL);
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "no proven fault"));
        gov.emergencyReplace(repaired);
        // Same inputs, same result: not a conflict.
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "same result"));
        reg.proveConflict(_transition(_header(h1, 2, "x")), proof, _header(h1, 2, "x"), proof);
        // One side unverified: not a conflict.
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "not both verified"));
        reg.proveConflict(_transition(_header(h1, 2, "x")), proof, _header(h1, 2, "y"), hex"00");
        // The mock accepts anything: two results for identical inputs. Anyone proves it.
        vm.prank(address(0xbeef));
        reg.proveConflict(_transition(_header(h1, 2, "x")), proof, _header(h1, 2, "y"), proof);
        assertTrue(reg.frozen());
        assertFalse(reg.isAcceptedBlock(ROLLUP, h1), "frozen: nothing reported accepted");
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "frozen"));
        reg.submit(_header(h1, 2, "b"), anchorId, 0, proof);
        // Only the council, only now, without delay.
        vm.expectRevert(RollupGovernance.Unauthorized.selector);
        gov.emergencyReplace(repaired);
        vm.prank(COUNCIL);
        gov.emergencyReplace(repaired);
        assertFalse(reg.frozen());
        assertEq(address(reg.verifier()), address(repaired));
        assertTrue(reg.isAcceptedBlock(ROLLUP, h1));
    }

    function test_ordinaryUpgradeWaitsThirtyDays() public {
        MockTransitionVerifier next = new MockTransitionVerifier();
        vm.prank(address(0xbad));
        vm.expectRevert(RollupGovernance.Unauthorized.selector);
        gov.schedule(next);
        gov.schedule(next);
        (, uint64 eta) = gov.pending();
        assertEq(eta, block.timestamp + 30 days);
        vm.warp(block.timestamp + 30 days - 1);
        vm.expectRevert(abi.encodeWithSelector(RollupGovernance.TooEarly.selector, eta));
        gov.execute();
        vm.warp(block.timestamp + 1);
        vm.prank(address(0xbeef)); // anyone executes a matured upgrade
        gov.execute();
        assertEq(address(reg.verifier()), address(next));
        vm.expectRevert(RollupGovernance.NothingScheduled.selector);
        gov.execute();
        // Nobody but governance touches the registry directly.
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "not governance"));
        reg.replaceVerifier(mockV, false);
    }

    function test_governanceBindsOnce() public {
        vm.expectRevert(RollupGovernance.AlreadyBound.selector);
        gov.bind(reg);
    }

    function test_calldataDAModeCommitsToTheProof() public {
        AccCheckingVerifier v = new AccCheckingVerifier();
        CanonicalBlockRegistry r = _registry(v, false);
        vm.blobhashes(new bytes32[](0)); // no blob needed: the data is the calldata proof
        r.submit(_header(keccak256(genesis), 1, "a"), 0, 0, abi.encode(bytes32(0)));
    }

    function test_anchorClaimIsOptionalButCheckedWhenMade() public {
        bytes32 g = keccak256(genesis);
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "L1 anchor not recorded"));
        reg.submit(_header(g, 1, "a"), keccak256("fake"), 0, proof);
        reg.submit(_header(g, 1, "a"), 0, 0, proof);
    }

    function test_messageRootMatchesEthrexAlgorithm() public {
        // Three messages: padded to four with the last; sorted-pair keccak.
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");
        bytes32 c = keccak256("c");
        queue.forceInclude("a");
        queue.forceInclude("b");
        queue.forceInclude("c");
        bytes32 ab = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        bytes32 cc = keccak256(abi.encodePacked(c, c));
        bytes32 root = ab < cc ? keccak256(abi.encodePacked(ab, cc)) : keccak256(abi.encodePacked(cc, ab));
        assertEq(queue.messagesRoot(0, 3), root);
        assertEq(queue.messagesRoot(0, 0), bytes32(0));
    }
}

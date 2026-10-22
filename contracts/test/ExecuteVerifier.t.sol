// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExecuteVerifier} from "../src/verifiers/ExecuteVerifier.sol";
import {IStateTransitionVerifier} from "../src/interfaces/IStateTransitionVerifier.sol";
import {L2AnchorInbox} from "../src/L2AnchorInbox.sol";
import {NativeRollupMessageQueue, INativeRollupMessages} from "../src/queues/NativeRollupMessageQueue.sol";
import {ForcedInclusionQueue} from "../src/queues/ForcedInclusionQueue.sol";

/// TEST STUB at 0x0101: forge's EVM has no EXECUTE precompile, so this returns a configured
/// StatelessValidationResult. It tests ExecuteVerifier's binding of the payload to the block;
/// the precompile itself is exercised for real by ts/e2e-native.ts on ethrex.
contract ExecuteStub {
    bytes public result;
    bool public fail;

    function set(bytes calldata r, bool f) external {
        result = r;
        fail = f;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if (fail) revert();
        return result;
    }
}

/// TEST STUB for the EIP-4788 beacon-roots contract: returns `root` for any timestamp.
contract BeaconRootsStub {
    bytes32 public root;

    function set(bytes32 r) external {
        root = r;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(root);
    }
}

contract NativeMessages is INativeRollupMessages {
    bytes32[] public msgs;

    function push(bytes32 h) external {
        msgs.push(h);
    }

    function pendingL1Messages(uint256 i) external view returns (bytes32) {
        return msgs[i];
    }
}

/// Against fixtures/native/execute-input.json: a real SSZ StatelessInput captured from ethrex.
contract ExecuteVerifierTest is Test {
    address constant EXECUTE = address(0x0101);
    address constant BEACON_ROOTS = 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02;
    string json;
    ExecuteVerifier v;
    bytes ssz;
    bytes header;
    bytes32 msgRoot;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/native/execute-input.json"));
        v = new ExecuteVerifier(
            uint64(vm.parseJsonUint(json, ".l2ChainId")), uint64(vm.parseJsonUint(json, ".l2GasLimit"))
        );
        ssz = vm.parseJsonBytes(json, ".ssz");
        header = vm.parseJsonBytes(json, ".rawHeader");
        bytes32[] memory hs = vm.parseJsonBytes32Array(json, ".messageHashes");
        NativeMessages nm = new NativeMessages();
        for (uint256 i; i < hs.length; ++i) {
            nm.push(hs[i]);
        }
        msgRoot = new NativeRollupMessageQueue(nm).messagesRoot(0, hs.length);
        vm.etch(EXECUTE, type(ExecuteStub).runtimeCode);
        ExecuteStub(payable(EXECUTE)).set(_result(1, uint64(vm.parseJsonUint(json, ".l2ChainId")), 0x1501), false);
    }

    function _result(uint8 ok, uint64 chainId, uint16 schema) internal pure returns (bytes memory r) {
        r = new bytes(43);
        r[32] = bytes1(ok);
        for (uint256 i; i < 8; ++i) {
            r[33 + i] = bytes1(uint8(chainId >> (8 * i)));
        }
        r[41] = bytes1(uint8(schema));
        r[42] = bytes1(uint8(schema >> 8));
    }

    function _t(bytes memory h, bytes32 da, bytes32 root)
        internal
        pure
        returns (IStateTransitionVerifier.Transition memory)
    {
        return IStateTransitionVerifier.Transition(bytes32(0), bytes32(0), da, bytes32(0), root, h);
    }

    function test_realInputBindsToItsBlock() public view {
        assertTrue(v.verify(_t(header, keccak256(ssz), msgRoot), ssz));
        assertEq(v.profileKind(), 1);
    }

    function test_bindingFailures() public {
        // DA commitment is not this calldata.
        assertFalse(v.verify(_t(header, keccak256("other"), msgRoot), ssz));
        // L1 messages other than the ones the block consumed.
        assertFalse(v.verify(_t(header, keccak256(ssz), bytes32(0)), ssz));
        // Another block's header.
        bytes memory other = vm.parseJsonBytes(json, ".anchor.rawHeader");
        assertFalse(v.verify(_t(other, keccak256(ssz), msgRoot), ssz));
        // Another rollup's gas limit / chain id.
        ExecuteVerifier wrongGas = new ExecuteVerifier(uint64(vm.parseJsonUint(json, ".l2ChainId")), 30_000_000);
        assertFalse(wrongGas.verify(_t(header, keccak256(ssz), msgRoot), ssz));
        ExecuteVerifier wrongChain = new ExecuteVerifier(999, uint64(vm.parseJsonUint(json, ".l2GasLimit")));
        assertFalse(wrongChain.verify(_t(header, keccak256(ssz), msgRoot), ssz));
    }

    function test_precompileVerdictIsRequired() public {
        uint64 cid = uint64(vm.parseJsonUint(json, ".l2ChainId"));
        ExecuteStub(payable(EXECUTE)).set(_result(0, cid, 0x1501), false);
        assertFalse(v.verify(_t(header, keccak256(ssz), msgRoot), ssz), "validation failed");
        ExecuteStub(payable(EXECUTE)).set(_result(1, cid, 0x1500), false);
        assertFalse(v.verify(_t(header, keccak256(ssz), msgRoot), ssz), "other schema");
        ExecuteStub(payable(EXECUTE)).set(_result(1, cid, 0x1501), true);
        assertFalse(v.verify(_t(header, keccak256(ssz), msgRoot), ssz), "precompile reverted");
        ExecuteStub(payable(EXECUTE)).set(new bytes(42), false);
        assertFalse(v.verify(_t(header, keccak256(ssz), msgRoot), ssz), "short result");
    }

    function test_tamperedInputRejected() public {
        bytes memory bad = bytes.concat(ssz);
        bad[0] = 0x14; // schema prefix
        vm.expectRevert();
        v.verify(_t(header, keccak256(bad), msgRoot), bad);
    }

    // ---- the trustless anchor path -------------------------------------------------------

    function test_anchorPostedOnlyByProvenL1Message() public {
        address sender = makeAddr("AnchorSender");
        L2AnchorInbox inbox = new L2AnchorInbox(address(0), sender, vm.parseJsonUint(json, ".anchor.l1ChainId"));
        bytes memory raw = vm.parseJsonBytes(json, ".anchor.rawHeader");
        uint256 gasLimit = 300_000;
        bytes32 mine = keccak256(
            abi.encodePacked(
                sender,
                address(inbox),
                uint256(0),
                gasLimit,
                keccak256(abi.encodeCall(inbox.l1Message, (raw))),
                uint256(7)
            )
        );
        bytes32 otherLeaf = keccak256("another message");
        bytes32 root = mine < otherLeaf
            ? keccak256(abi.encodePacked(mine, otherLeaf))
            : keccak256(abi.encodePacked(otherLeaf, mine));
        vm.etch(BEACON_ROOTS, type(BeaconRootsStub).runtimeCode);
        BeaconRootsStub(payable(BEACON_ROOTS)).set(root);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = otherLeaf;
        // The mock path is off without a system key.
        vm.expectRevert(L2AnchorInbox.NotSystem.selector);
        inbox.post(raw);
        // Wrong nonce / gas / proof: not the message L1 committed to.
        vm.expectRevert(L2AnchorInbox.NotProven.selector);
        inbox.postFromL1(raw, gasLimit, 8, 123, proof);
        vm.expectRevert(L2AnchorInbox.NotProven.selector);
        inbox.postFromL1(raw, gasLimit + 1, 7, 123, proof);
        vm.expectRevert(L2AnchorInbox.NotProven.selector);
        inbox.postFromL1(raw, gasLimit, 7, 123, new bytes32[](0));
        // From another L1 sender: the inbox computes the hash with its configured sender.
        L2AnchorInbox other = new L2AnchorInbox(address(0), makeAddr("someone else"), 1);
        vm.expectRevert(L2AnchorInbox.NotProven.selector);
        other.postFromL1(raw, gasLimit, 7, 123, proof);
        bytes32 id = inbox.postFromL1(raw, gasLimit, 7, 123, proof);
        assertTrue(inbox.stateRootOf(id) != 0);
        // No beacon root at that timestamp.
        BeaconRootsStub(payable(BEACON_ROOTS)).set(0);
        vm.expectRevert(L2AnchorInbox.NotProven.selector);
        inbox.postFromL1(raw, gasLimit, 7, 124, proof);
    }

    // ---- the native message queue ----------------------------------------------------------

    function test_nativeQueueDeadlinesStartWhenPoked() public {
        NativeMessages nm = new NativeMessages();
        NativeRollupMessageQueue q = new NativeRollupMessageQueue(nm);
        ForcedInclusionQueue ref = new ForcedInclusionQueue();
        nm.push(keccak256("m0"));
        nm.push(keccak256("m1"));
        ref.forceInclude("m0");
        ref.forceInclude("m1");
        assertEq(q.messagesRoot(0, 2), ref.messagesRoot(0, 2), "same root algorithm");
        assertFalse(q.overdue(0, 1 days), "un-poked is never overdue");
        q.poke(2);
        vm.expectRevert();
        q.poke(3); // doesn't exist
        assertFalse(q.overdue(0, 1 days));
        vm.warp(block.timestamp + 1 days);
        assertTrue(q.overdue(0, 1 days));
        assertTrue(q.overdue(1, 1 days));
        assertFalse(q.overdue(2, 1 days));
    }
}

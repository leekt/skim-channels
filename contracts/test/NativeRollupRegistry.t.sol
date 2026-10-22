// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {NativeRollupRegistry, INativeRollup} from "../src/NativeRollupRegistry.sol";
import {ChannelTypes} from "../src/libraries/ChannelTypes.sol";

/// Holds what ethrex's NativeRollup.sol holds after EXECUTE-verified advances (the values come
/// from fixtures/witnesses/l2-history.json). The registry's logic is under test, not this.
contract NativeRollupState is INativeRollup {
    bytes32 public blockHash;
    mapping(uint256 => bytes32) public stateRootHistory;
    mapping(uint256 => uint256) public stateRootTimestamps;
    uint256 public FINALITY_DELAY;

    function set(uint256 n, bytes32 root, bytes32 tipHash, uint256 delay) external {
        stateRootHistory[n] = root;
        stateRootTimestamps[n] = block.timestamp;
        blockHash = tipHash;
        FINALITY_DELAY = delay;
    }
}

contract NativeRollupRegistryTest is Test {
    string json;
    NativeRollupState native;
    NativeRollupRegistry reg;
    bytes header;
    bytes32 hash;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/l2-history.json"));
        native = new NativeRollupState();
        reg = new NativeRollupRegistry(keccak256("rollup"), keccak256("profile"), native);
        header = vm.parseJsonBytes(json, ".header");
        hash = vm.parseJsonBytes32(json, ".blockHash");
        native.set(50, vm.parseJsonBytes32(json, ".stateRoot"), bytes32(0), 1 hours);
        native.set(60, vm.parseJsonBytes32(json, ".laterStateRoot"), bytes32(0), 1 hours);
    }

    function _historical() internal returns (bytes32) {
        return reg.acceptHistorical(
            header, 60, vm.parseJsonBytesArray(json, ".accountProof"), vm.parseJsonBytesArray(json, ".storageProof")
        );
    }

    function test_reportsNativeProfile() public view {
        assertEq(reg.profileKind(), ChannelTypes.PROFILE_NATIVE_REEXECUTION_DEVNET);
    }

    function test_historicalBlockAcceptedFromVerifiedLaterState() public {
        vm.expectRevert(abi.encodeWithSelector(NativeRollupRegistry.Rejected.selector, "not final"));
        _historical();
        vm.warp(block.timestamp + 1 hours);
        assertEq(_historical(), hash);
        assertTrue(reg.isAcceptedBlock(keccak256("rollup"), hash));
        assertEq(reg.acceptedBlock(keccak256("rollup"), hash).stateRoot, vm.parseJsonBytes32(json, ".stateRoot"));
        assertEq(reg.acceptedBlock(keccak256("rollup"), hash).executionProfileHash, keccak256("profile"));
    }

    function test_unverifiedOrForgedRejected() public {
        vm.warp(block.timestamp + 1 hours);
        // No verified state at the claimed later height.
        vm.expectRevert(
            abi.encodeWithSelector(NativeRollupRegistry.Rejected.selector, "no verified state at that height")
        );
        reg.acceptHistorical(header, 61, new bytes[](0), new bytes[](0));
        // Proofs against a root L1 didn't verify.
        native.set(60, keccak256("other root"), bytes32(0), 0);
        vm.expectRevert();
        _historical();
        native.set(60, vm.parseJsonBytes32(json, ".laterStateRoot"), bytes32(0), 0);
        // A header whose own state root wasn't verified at its height.
        native.set(50, keccak256("other"), bytes32(0), 0);
        vm.expectRevert(abi.encodeWithSelector(NativeRollupRegistry.Rejected.selector, "state root not verified"));
        _historical();
        native.set(50, vm.parseJsonBytes32(json, ".stateRoot"), bytes32(0), 0);
        // A different header (e.g. a forged receipts root) at the same height.
        bytes memory other = vm.parseJsonBytes(json, ".laterHeader");
        vm.expectRevert();
        reg.acceptHistorical(
            other, 60, vm.parseJsonBytesArray(json, ".accountProof"), vm.parseJsonBytesArray(json, ".storageProof")
        );
        // A height whose history slot exists but holds a different hash.
        native.set(7, vm.parseJsonBytes32(json, ".stateRoot7"), bytes32(0), 0);
        vm.expectRevert(abi.encodeWithSelector(NativeRollupRegistry.Rejected.selector, "hash not in history"));
        reg.acceptHistorical(
            vm.parseJsonBytes(json, ".header7"),
            60,
            vm.parseJsonBytesArray(json, ".accountProof"),
            vm.parseJsonBytesArray(json, ".storageProof7")
        );
        // Outside the history window / not later.
        vm.expectRevert(abi.encodeWithSelector(NativeRollupRegistry.Rejected.selector, "history window"));
        reg.acceptHistorical(header, 50, new bytes[](0), new bytes[](0));
        assertEq(_historical(), hash);
    }

    function test_tipAccepted() public {
        vm.expectRevert(abi.encodeWithSelector(NativeRollupRegistry.Rejected.selector, "not the verified tip"));
        reg.acceptTip(header);
        native.set(50, vm.parseJsonBytes32(json, ".stateRoot"), hash, 0);
        assertEq(reg.acceptTip(header), hash);
    }
}

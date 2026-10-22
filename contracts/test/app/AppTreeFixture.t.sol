// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AppChannelVault} from "../../src/app/AppChannelVault.sol";
import {AppLeaves} from "../../src/app/AppLeaves.sol";
import {AppLedger} from "./AppLedger.sol";

contract LeafHarness {
    function contains(bytes32 root, bytes32 leaf, uint256 index, bytes32[] calldata siblings)
        external
        pure
        returns (bool)
    {
        return AppLeaves.contains(root, leaf, index, siblings);
    }
}

/// Rust (crates/channel-app) and Solidity agree on leaves, trees, net diffs and the state root:
/// fixtures/app/tree.json.
contract AppTreeFixtureTest is Test {
    function test_rustDiffsReplayToRustRoots() public {
        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/app/tree.json"));
        bytes[] memory diffs = vm.parseJsonBytesArray(j, ".diffs");
        AppLedger l = new AppLedger(AppChannelVault(payable(address(0))), bytes32(0));
        l.applyDiff(diffs[0], 3, 0);
        l.applyDiff(diffs[1], 3, 0);
        assertEq(l.root(true), vm.parseJsonBytes32(j, ".exitRoot"));
        assertEq(l.root(false), vm.parseJsonBytes32(j, ".creditRoot"));
        assertEq(l.claim(false).stateRoot, vm.parseJsonBytes32(j, ".stateRoot"));
        bytes32 leaf = AppLeaves.exitLeaf(
            vm.parseJsonAddress(j, ".proof.recipient"),
            vm.parseJsonAddress(j, ".proof.token"),
            uint256(vm.parseJsonBytes32(j, ".proof.value"))
        );
        assertTrue(
            new LeafHarness()
                .contains(
                    vm.parseJsonBytes32(j, ".exitRoot"),
                    leaf,
                    vm.parseJsonUint(j, ".proof.index"),
                    vm.parseJsonBytes32Array(j, ".proof.siblings")
                )
        );
    }
}

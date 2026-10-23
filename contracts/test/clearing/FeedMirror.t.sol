// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FeedMirror} from "../../src/clearing/FeedMirror.sol";

/// @notice FeedMirror against a real witness: Sepolia's Chainlink ETH/USD aggregator, proven
///         at a skim node's safe block (fixtures/witnesses/sepolia-eth-usd.json).
contract FeedMirrorTest is Test {
    uint256 constant SEPOLIA = 11155111;
    address relayer = address(0xBEEF);
    address agg;
    bytes header;
    bytes pkg;
    uint256 answer;
    uint64 number;
    FeedMirror m;

    function setUp() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/sepolia-eth-usd.json"));
        agg = vm.parseJsonAddress(json, ".aggregator");
        header = vm.parseJsonBytes(json, ".rawHeader");
        pkg = vm.parseJsonBytes(json, ".package");
        answer = vm.parseJsonUint(json, ".answer");
        number = uint64(vm.parseJsonUint(json, ".blockNumber"));
        m = new FeedMirror(SEPOLIA, agg, relayer);
    }

    function test_mirrorsTheProvenAnswer() public {
        vm.prank(relayer);
        m.update(header, pkg);
        assertEq(m.price(), answer / 100);
        assertEq(m.sourceBlock(), number);
        assertEq(m.sourceBlockHash(), keccak256(header));
        assertGt(m.round(), 0);
        assertEq(uint256(vm.load(address(m), bytes32(0))), answer / 100, "price is slot 0");
    }

    function test_onlyTheRelayer() public {
        vm.expectRevert(FeedMirror.NotRelayer.selector);
        m.update(header, pkg);
    }

    function test_blocksOnlyMoveForward() public {
        vm.startPrank(relayer);
        m.update(header, pkg);
        vm.expectRevert(FeedMirror.NotNewer.selector);
        m.update(header, pkg);
    }

    function test_wrongSourceChain() public {
        FeedMirror other = new FeedMirror(1, agg, relayer);
        vm.prank(relayer);
        vm.expectRevert(FeedMirror.WrongChain.selector);
        other.update(header, pkg);
    }

    function test_headerMustBeTheAnchor() public {
        bytes memory h = bytes.concat(header);
        h[h.length - 1] = h[h.length - 1] ^ 0x01;
        vm.prank(relayer);
        vm.expectRevert(FeedMirror.HeaderMismatch.selector);
        m.update(h, pkg);
    }

    function test_anotherContractsSlotsDontCount() public {
        FeedMirror other = new FeedMirror(SEPOLIA, address(0x1234), relayer);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(FeedMirror.MissingRead.selector, bytes32(uint256(0x2b))));
        other.update(header, pkg);
    }

    function test_tamperedProofIsRefused() public {
        // Flip one bit at positions spread over the proofs: every one must revert.
        for (uint256 i = 200; i < pkg.length; i += 997) {
            bytes memory p = bytes.concat(pkg);
            p[i] = p[i] ^ 0x01;
            vm.prank(relayer);
            try m.update(header, p) {
                revert("tampered package accepted");
            } catch {}
        }
    }
}

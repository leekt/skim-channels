// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AnchorRegistry} from "../../src/AnchorRegistry.sol";
import {ChainlinkAdapter} from "../../src/clearing/ChainlinkAdapter.sol";

/// ChainlinkAdapter against a real witness: Sepolia's ETH/USD proxy and aggregator, proven at
/// a skim node's safe block (fixtures/witnesses/sepolia-chainlink.json).
contract ChainlinkAdapterTest is Test {
    AnchorRegistry anchors;
    address proxy;
    address agg;
    bytes32 proxyHash;
    bytes32 aggHash;
    bytes pkg;
    uint256 number;
    uint256 stamp;
    uint256 answer;

    function setUp() public {
        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/sepolia-chainlink.json"));
        proxy = vm.parseJsonAddress(j, ".proxy");
        agg = vm.parseJsonAddress(j, ".aggregator");
        proxyHash = vm.parseJsonBytes32(j, ".proxyCodeHash");
        aggHash = vm.parseJsonBytes32(j, ".aggregatorCodeHash");
        pkg = vm.parseJsonBytes(j, ".package");
        number = vm.parseJsonUint(j, ".blockNumber");
        stamp = vm.parseJsonUint(j, ".timestamp");
        answer = vm.parseJsonUint(j, ".answer");
        bytes memory raw = vm.parseJsonBytes(j, ".rawHeader");
        vm.chainId(11155111);
        vm.roll(number + 10);
        vm.setBlockhash(number, keccak256(raw));
        anchors = new AnchorRegistry();
        anchors.record(raw);
    }

    function _adapter(address a, bytes32 ah, bytes32 ph, uint256 stale) internal returns (ChainlinkAdapter) {
        return new ChainlinkAdapter(proxy, ph, a, ah, 8, stale);
    }

    function test_thePriceTheProxyReturnsAtTheAnchor() public {
        ChainlinkAdapter ad = _adapter(agg, aggHash, proxyHash, 3 hours);
        uint256 g = gasleft();
        (uint256 p, uint64 at,, uint256 round) = ad.price(pkg, anchors, 256);
        emit log_named_uint("adapter.price gas (execution)", g - gasleft());
        emit log_named_uint("witness bytes", pkg.length);
        assertEq(p, answer / 100, "8 decimals to 6");
        assertEq(at, number);
        // The round a challenger proves at a head: the same latest round, at any age.
        vm.roll(block.number + 10_000);
        (uint64 at2, uint256 round2) = ad.roundAt(pkg, anchors);
        assertEq(at2, number);
        assertEq(round2, round, "roundAt reads the same latest round");
        assertGt(round, 0);
    }

    /// Configured for an aggregator the proxy doesn't point at (and the witness doesn't cover):
    /// refused. A proxy that switched aggregators is refused the same way (e2e-clearing).
    function test_anotherAggregatorIsRefused() public {
        ChainlinkAdapter ad = _adapter(address(0xA66), aggHash, proxyHash, 3 hours);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.UnsupportedFeed.selector, "aggregator code"));
        ad.price(pkg, anchors, 256);
    }

    function test_unpinnedCodeIsRefused() public {
        ChainlinkAdapter a1 = _adapter(agg, keccak256("other"), proxyHash, 3 hours);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.UnsupportedFeed.selector, "aggregator code"));
        a1.price(pkg, anchors, 256);
        ChainlinkAdapter a2 = _adapter(agg, aggHash, keccak256("other"), 3 hours);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.UnsupportedFeed.selector, "proxy code"));
        a2.price(pkg, anchors, 256);
    }

    function test_freshnessIsJudgedAtTheAnchor() public {
        uint256 age = stamp
            - vm.parseJsonUint(
                vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/sepolia-chainlink.json")),
                ".updatedAt"
            );
        ChainlinkAdapter tight = _adapter(agg, aggHash, proxyHash, age - 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.StalePrice.selector, stamp - age, stamp));
        tight.price(pkg, anchors, 256);
        ChainlinkAdapter ok = _adapter(agg, aggHash, proxyHash, age);
        vm.warp(stamp + 30 days); // proposal time doesn't matter, only the anchor's
        ok.price(pkg, anchors, 256);
    }

    function test_anchorMustBeRecordedAndRecent() public {
        ChainlinkAdapter ad = _adapter(agg, aggHash, proxyHash, 3 hours);
        vm.roll(number + 257);
        vm.expectRevert(ChainlinkAdapter.BadAnchor.selector);
        ad.price(pkg, anchors, 256);
        AnchorRegistry empty = new AnchorRegistry();
        vm.roll(number + 10);
        vm.expectRevert(ChainlinkAdapter.BadAnchor.selector);
        ad.price(pkg, empty, 256);
    }

    function test_tamperedWitnessIsRefused() public {
        ChainlinkAdapter ad = _adapter(agg, aggHash, proxyHash, 3 hours);
        for (uint256 i = 300; i < pkg.length; i += 1499) {
            bytes memory p = bytes.concat(pkg);
            p[i] = p[i] ^ 0x01;
            try ad.price(p, anchors, 256) returns (uint256 v, uint64, uint64, uint256) {
                assertEq(v, answer / 100, "a flip that verifies must not change the price");
                revert("tampered witness accepted");
            } catch {}
        }
    }
}

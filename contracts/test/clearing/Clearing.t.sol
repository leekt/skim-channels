// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {AnchorRegistry} from "../../src/AnchorRegistry.sol";
import {ChannelTypes} from "../../src/libraries/ChannelTypes.sol";
import {WitnessLib} from "../../src/libraries/WitnessLib.sol";
import {ChainlinkAdapter, IPriceAdapter} from "../../src/clearing/ChainlinkAdapter.sol";

/// A plain 6-decimal test token (no fee), used by forge and ts/e2e-clearing.ts.
contract TestUSD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        balanceOf[to] += a;
        return true;
    }
}

/// Channel tests' price source: one slot of a fixture contract, with the same anchor checks as
/// ChainlinkAdapter (recorded on this chain, at most `maxAge` old). Channel logic doesn't
/// depend on where the price comes from; ChainlinkAdapter has its own tests.
contract SlotPriceAdapter is IPriceAdapter {
    address public immutable feed;
    bytes32 public immutable slot;

    constructor(address feed_, bytes32 slot_) {
        feed = feed_;
        slot = slot_;
    }

    function price(bytes calldata witness, AnchorRegistry anchors, uint256 maxAge)
        external
        view
        returns (uint256 value, uint64 anchorBlock)
    {
        WitnessLib.WitnessPackage memory p = WitnessLib.decode(witness);
        WitnessLib.Read[] memory reads = WitnessLib.verify(p);
        ChannelTypes.L1Anchor memory a = p.anchor;
        if (
            a.chainId != block.chainid || a.stateRoot == 0
                || anchors.stateRootOf(ChannelTypes.anchorId(a)) != a.stateRoot || block.number > a.blockNumber + maxAge
        ) revert ChainlinkAdapter.BadAnchor();
        return (WitnessLib.find(reads, feed, slot), a.blockNumber);
    }
}

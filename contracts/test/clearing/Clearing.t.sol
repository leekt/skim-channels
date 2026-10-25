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
        returns (uint256 value, uint64 anchorBlock, uint64 updatedAt, uint256 round)
    {
        (WitnessLib.Read[] memory reads, ChannelTypes.L1Anchor memory a) = _verified(witness, anchors);
        if (block.number > a.blockNumber + maxAge) revert ChainlinkAdapter.BadAnchor();
        // The fixture slot has no answer time or round: the anchor's own time, a set round.
        return (
            WitnessLib.find(reads, feed, slot),
            a.blockNumber,
            uint64(anchors.timestampOf(ChannelTypes.anchorId(a))),
            roundOf[a.blockNumber]
        );
    }

    function roundAt(bytes calldata witness, AnchorRegistry anchors)
        external
        view
        returns (uint64 anchorBlock, uint256 round)
    {
        (, ChannelTypes.L1Anchor memory a) = _verified(witness, anchors);
        return (a.blockNumber, roundOf[a.blockNumber]);
    }

    function _verified(bytes calldata witness, AnchorRegistry anchors)
        internal
        view
        returns (WitnessLib.Read[] memory reads, ChannelTypes.L1Anchor memory a)
    {
        WitnessLib.WitnessPackage memory p = WitnessLib.decode(witness);
        reads = WitnessLib.verify(p);
        a = p.anchor;
        if (
            a.chainId != block.chainid || a.stateRoot == 0
                || anchors.stateRootOf(ChannelTypes.anchorId(a)) != a.stateRoot
        ) {
            revert ChainlinkAdapter.BadAnchor();
        }
    }

    /// The feed round at each block (tests set it).
    mapping(uint256 => uint256) public roundOf;

    function setRound(uint256 blockNumber, uint256 round) external {
        roundOf[blockNumber] = round;
    }

    uint256 public maxStaleness = 3650 days;

    function setMaxStaleness(uint256 s) external {
        maxStaleness = s;
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IChannelModule} from "../interfaces/IChannelModule.sol";
import {WitnessLib} from "../libraries/WitnessLib.sol";

/// @notice Read-and-Split (PROJECT.md §9): divides `total` between two participants by an L1
///         `shareBps` value. input = abi.encode(address fixture, bytes32 slot, uint256 total).
contract SplitModule is IChannelModule {
    error BadInput();

    function compute(bytes calldata input, WitnessLib.Read[] calldata reads, uint256 participants)
        external
        pure
        returns (bytes memory)
    {
        if (participants != 2 || input.length != 96) revert BadInput();
        (address fixture, bytes32 slot, uint256 total) = abi.decode(input, (address, bytes32, uint256));
        uint256 bps = WitnessLib.find(reads, fixture, slot);
        if (bps > 10_000) revert BadInput();
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = total * bps / 10_000;
        payouts[1] = total - payouts[0];
        return abi.encode(payouts);
    }
}

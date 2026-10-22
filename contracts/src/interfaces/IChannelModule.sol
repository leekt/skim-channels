// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {WitnessLib} from "../libraries/WitnessLib.sol";

/// @notice An approved, immutable computation module. Called with STATICCALL: it cannot
///         write state. `reads` are verified L1 storage values at the request's anchor.
interface IChannelModule {
    /// @return outcome abi.encode(uint256[] payouts), one per participant, in participant order.
    function compute(bytes calldata input, WitnessLib.Read[] calldata reads, uint256 participants)
        external
        view
        returns (bytes memory outcome);
}

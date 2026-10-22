// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ChannelSettlement} from "./ChannelSettlement.sol";

/// @notice Settles many channels in one L1 transaction (M4 batching). Stateless and
///         permissionless: `settle` is open to anyone, so this only amortizes the transaction
///         overhead. Best effort: one bad evidence doesn't block the others.
contract BatchSettler {
    event SettleFailed(bytes32 indexed channelId, bytes reason);

    /// @return settled bit i set if channelIds[i] settled
    function settleAll(ChannelSettlement s, bytes32[] calldata channelIds, bytes[] calldata evidences)
        external
        returns (uint256 settled)
    {
        require(channelIds.length == evidences.length && channelIds.length <= 256, "lengths");
        for (uint256 i; i < channelIds.length; ++i) {
            try s.settle(channelIds[i], evidences[i]) {
                settled |= 1 << i;
            } catch (bytes memory reason) {
                emit SettleFailed(channelIds[i], reason);
            }
        }
    }
}

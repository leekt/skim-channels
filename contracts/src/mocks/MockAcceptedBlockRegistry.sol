// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IAcceptedBlockRegistry} from "../interfaces/IAcceptedBlockRegistry.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

/// @notice MOCK — LOCAL DEVELOPMENT ONLY. Acceptance here is an operator assertion: nothing is
///         verified (no execution proof, no ancestry, no DA). It is NOT Native Rollup security
///         and reports profileKind() == PROFILE_MOCK_LOCAL so settlement under a native profile
///         rejects it.
contract MockAcceptedBlockRegistry is IAcceptedBlockRegistry {
    string public constant SECURITY_LABEL = "MOCK: operator-asserted block acceptance, no execution verification";

    address public immutable operator;
    mapping(bytes32 => mapping(bytes32 => AcceptedBlock)) internal blocks;

    event MockBlockAccepted(bytes32 indexed rollupId, bytes32 indexed blockHash);

    error NotOperator();

    constructor(address operator_) {
        operator = operator_;
    }

    function profileKind() external pure returns (uint8) {
        return ChannelTypes.PROFILE_MOCK_LOCAL;
    }

    function mockAccept(bytes32 rollupId, bytes32 blockHash, AcceptedBlock calldata b) external {
        if (msg.sender != operator) revert NotOperator();
        AcceptedBlock memory stored = b;
        stored.accepted = true;
        blocks[rollupId][blockHash] = stored;
        emit MockBlockAccepted(rollupId, blockHash);
    }

    function isAcceptedBlock(bytes32 rollupId, bytes32 blockHash) external view returns (bool) {
        return blocks[rollupId][blockHash].accepted;
    }

    function acceptedBlock(bytes32 rollupId, bytes32 blockHash) external view returns (AcceptedBlock memory) {
        return blocks[rollupId][blockHash];
    }
}

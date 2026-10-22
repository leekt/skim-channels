// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IStateTransitionVerifier} from "../interfaces/IStateTransitionVerifier.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

/// @notice MOCK — LOCAL DEVELOPMENT ONLY. Accepts any transition whose proof is the literal
///         MOCK_PROOF: nothing about execution is verified. Reports PROFILE_MOCK_LOCAL, so a
///         settlement deployed for a native profile rejects any registry built on it.
contract MockTransitionVerifier is IStateTransitionVerifier {
    string public constant SECURITY_LABEL = "MOCK: transitions are NOT verified";
    bytes32 public constant MOCK_PROOF = keccak256("skim-channels/mock-transition-proof");

    function profileKind() external pure returns (uint8) {
        return ChannelTypes.PROFILE_MOCK_LOCAL;
    }

    function verify(bytes32, bytes32, bytes calldata, bytes32, bytes32, bytes calldata proof)
        external
        pure
        returns (bool)
    {
        return proof.length == 32 && bytes32(proof) == MOCK_PROOF;
    }
}

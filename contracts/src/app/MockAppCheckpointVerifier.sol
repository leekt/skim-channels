// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IAppCheckpointVerifier} from "./IAppCheckpointVerifier.sol";

/// @notice MOCK — LOCAL DEVELOPMENT ONLY. A "proof" is keccak256(MOCK_TAG, inputsHash): it binds
///         the checkpoint's public inputs (so L1-side bookkeeping is exercised for real) but
///         checks NOTHING about execution. Anyone who knows the inputs can produce one.
contract MockAppCheckpointVerifier is IAppCheckpointVerifier {
    string public constant SECURITY_LABEL = "MOCK: app checkpoints are NOT proven";
    bytes32 public constant MOCK_TAG = keccak256("skim-app-channels/mock-proof/v0");

    function kind() external pure returns (uint8) {
        return 0;
    }

    function verify(bytes32 inputsHash, bytes calldata proof) external pure returns (bool) {
        return proof.length == 32 && bytes32(proof) == keccak256(abi.encode(MOCK_TAG, inputsHash));
    }
}

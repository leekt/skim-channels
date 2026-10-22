// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice Verifies a validity proof that an app-channel checkpoint follows from the previous
///         accepted one (docs/guide/app-channels.md §3). `inputsHash` commits to every public
///         input; AppChannelVault computes it from its own records and the claimed roots.
interface IAppCheckpointVerifier {
    /// @notice 0 = mock (no execution checked). Anything else names a real proof system.
    function kind() external view returns (uint8);

    function verify(bytes32 inputsHash, bytes calldata proof) external view returns (bool);
}

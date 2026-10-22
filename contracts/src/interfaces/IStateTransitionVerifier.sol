// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice Verifies one L2 block as a valid state transition (PROJECT.md §6.3). This is the
///         only part of block acceptance not implemented in this repo: a real implementation
///         wraps a Native Rollup verification mechanism (EIP-8079 re-execution, or EIP-8288 /
///         EIP-8357 proof verification) once a compatible network provides one.
interface IStateTransitionVerifier {
    /// @notice The ExecutionProfile kind this verifier provides (ChannelTypes.PROFILE_*).
    function profileKind() external view returns (uint8);

    /// @param profileHash  the execution profile (program, fork schema, DA schema) to verify under
    /// @param parentStateRoot  the accepted parent's post-state root
    /// @param rawHeader  the block's RLP header; its hash is the block hash
    /// @param daCommitment  versioned hash of the blob carrying the block's transactions
    /// @param l1AnchorId  the L1 anchor the block makes available to L2
    function verify(
        bytes32 profileHash,
        bytes32 parentStateRoot,
        bytes calldata rawHeader,
        bytes32 daCommitment,
        bytes32 l1AnchorId,
        bytes calldata proof
    ) external view returns (bool);
}

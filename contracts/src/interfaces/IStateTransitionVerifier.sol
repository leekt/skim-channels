// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice Verifies one L2 block as a valid state transition (PROJECT.md §6.3). This is the
///         only part of block acceptance not implemented in this repo: a real implementation
///         wraps a Native Rollup verification mechanism (EIP-8079 re-execution, or EIP-8288 /
///         EIP-8357 proof verification) once a compatible network provides one.
interface IStateTransitionVerifier {
    /// @notice Everything a transition is a deterministic function of, plus its claimed result.
    struct Transition {
        bytes32 profileHash; // program, fork schema, DA schema
        bytes32 parentStateRoot; // accepted parent's post-state
        bytes32 daCommitment; // versioned hash of the blob carrying the block's transactions
        bytes32 l1AnchorId; // the L1 anchor the block makes available to L2
        bytes32 forcedTxsAcc; // accumulator of the forced-inclusion entries the block must contain
        bytes rawHeader; // the block (its hash, state root and receipts root are the result)
    }

    /// @notice The ExecutionProfile kind this verifier provides (ChannelTypes.PROFILE_*).
    function profileKind() external view returns (uint8);

    function verify(Transition calldata t, bytes calldata proof) external view returns (bool);
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice Project-owned view of L2 block acceptance (PROJECT.md §6.2). Implementations must
///         only report blocks that extend the rollup's canonical history under a verified
///         execution transition with required data availability (§6.4).
interface IAcceptedBlockRegistry {
    struct AcceptedBlock {
        bytes32 parentHash;
        bytes32 stateRoot;
        bytes32 receiptsRoot;
        bytes32 l1AnchorId;
        bytes32 executionProfileHash;
        uint64 blockNumber;
        bool accepted;
    }

    /// @notice The ExecutionProfile kind this registry enforces. Settlement contracts must
    ///         compare this against the kind their channel's profile commits to.
    function profileKind() external view returns (uint8);

    function isAcceptedBlock(bytes32 rollupId, bytes32 blockHash) external view returns (bool);

    function acceptedBlock(bytes32 rollupId, bytes32 blockHash) external view returns (AcceptedBlock memory);
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice The L1→L2 message queue a block registry enforces: blocks commit to the messages
///         they consume (a root over a contiguous range), and must consume overdue ones
///         (forced inclusion).
interface IL1MessageQueue {
    /// @notice Root over entries [start, start + count); reverts if any is missing.
    ///         Algorithm (ethrex NativeRollup's): 0 for none; else a sorted-pair keccak Merkle
    ///         tree over the entry hashes, padded to a power of two with the last entry.
    function messagesRoot(uint256 start, uint256 count) external view returns (bytes32);

    /// @notice Whether entry `index` exists and has been queued for at least `delay` seconds.
    function overdue(uint256 index, uint256 delay) external view returns (bool);
}

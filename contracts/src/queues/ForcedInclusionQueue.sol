// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IL1MessageQueue} from "../interfaces/IL1MessageQueue.sol";
import {MessageRoot} from "./MessageRoot.sol";

/// @notice A standalone forced-inclusion queue: anyone queues a signed L2 transaction; block
///         producers must include it once it is overdue (enforced by the block registry).
contract ForcedInclusionQueue is IL1MessageQueue {
    uint256 public constant MAX_TX_BYTES = 128 * 1024;

    bytes32[] public entries;
    uint64[] public queuedAt;

    event Queued(uint256 indexed index, bytes32 txHash);

    error TxSize();

    function forceInclude(bytes calldata signedTx) external returns (uint256 index) {
        if (signedTx.length == 0 || signedTx.length > MAX_TX_BYTES) revert TxSize();
        index = entries.length;
        entries.push(keccak256(signedTx));
        queuedAt.push(uint64(block.timestamp));
        emit Queued(index, keccak256(signedTx));
    }

    function count() external view returns (uint256) {
        return entries.length;
    }

    function messagesRoot(uint256 start, uint256 n) external view returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = entries[start + i];
        }
        return MessageRoot.root(leaves);
    }

    function overdue(uint256 index, uint256 delay) external view returns (bool) {
        return index < entries.length && block.timestamp >= uint256(queuedAt[index]) + delay;
    }
}

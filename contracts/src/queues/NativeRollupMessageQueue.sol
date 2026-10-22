// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IL1MessageQueue} from "../interfaces/IL1MessageQueue.sol";
import {MessageRoot} from "./MessageRoot.sol";

interface INativeRollupMessages {
    function pendingL1Messages(uint256 index) external view returns (bytes32);
}

/// @notice ethrex NativeRollup's L1→L2 message queue (`sendL1Message`), as an IL1MessageQueue.
///         ethrex records no per-message time, so deadlines start when anyone `poke`s a
///         message (permissionless; a sender pokes right after sending). Un-poked messages
///         are never overdue: a sender who wants forced inclusion pokes.
contract NativeRollupMessageQueue is IL1MessageQueue {
    INativeRollupMessages public immutable native;
    uint64[] public seenAt;

    constructor(INativeRollupMessages native_) {
        native = native_;
    }

    /// @notice Records the first-seen time of every existing message below `upTo`.
    function poke(uint256 upTo) external {
        for (uint256 i = seenAt.length; i < upTo; ++i) {
            native.pendingL1Messages(i); // reverts if it doesn't exist
            seenAt.push(uint64(block.timestamp));
        }
    }

    function messagesRoot(uint256 start, uint256 n) external view returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = native.pendingL1Messages(start + i);
        }
        return MessageRoot.root(leaves);
    }

    function overdue(uint256 index, uint256 delay) external view returns (bool) {
        return index < seenAt.length && block.timestamp >= uint256(seenAt[index]) + delay;
    }
}

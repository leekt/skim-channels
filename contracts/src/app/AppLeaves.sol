// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice Leaves and the bounded binary tree of app-channel checkpoints
///         (docs/guide/app-channels.md). Must match crates/channel-app (cross-checked by
///         fixtures/app/tree.json).
///
///         Exit leaf:   keccak256(abi.encode(EXIT_TAG,   recipient, token, amount))
///         Credit leaf: keccak256(abi.encode(CREDIT_TAG, recipient, token, cumulative))
///         Tree: leaves sorted by key = keccak256(abi.encode(recipient, token)) ascending,
///         zero-valued entries omitted, padded with bytes32(0) to 2^depth (depth >= 1),
///         node = keccak256(abi.encodePacked(left, right)). The empty tree's root is 0.
library AppLeaves {
    bytes32 internal constant EXIT_TAG = keccak256("skim-app-channels/exit-leaf/v0");
    bytes32 internal constant CREDIT_TAG = keccak256("skim-app-channels/credit-leaf/v0");
    uint256 internal constant MAX_DEPTH = 32;

    function exitLeaf(address recipient, address token, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(EXIT_TAG, recipient, token, amount));
    }

    function creditLeaf(address recipient, address token, uint256 cumulative) internal pure returns (bytes32) {
        return keccak256(abi.encode(CREDIT_TAG, recipient, token, cumulative));
    }

    /// @notice Whether `leaf` sits at `index` under `root`. `siblings.length` is the depth.
    function contains(bytes32 root, bytes32 leaf, uint256 index, bytes32[] calldata siblings)
        internal
        pure
        returns (bool)
    {
        uint256 depth = siblings.length;
        if (root == 0 || leaf == 0 || depth == 0 || depth > MAX_DEPTH || index >> depth != 0) return false;
        bytes32 h = leaf;
        for (uint256 i; i < depth; ++i) {
            h = (index >> i) & 1 == 0
                ? keccak256(abi.encodePacked(h, siblings[i]))
                : keccak256(abi.encodePacked(siblings[i], h));
        }
        return h == root;
    }
}

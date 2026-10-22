// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice A sparse Merkle tree of depth 16 indexed by user index (0 .. 65535). Empty leaves
///         are bytes32(0); zero[i+1] = keccak256(zero[i], zero[i]); node = keccak256(left, right).
///         Every root used by PredictionChannel is computed by this library on L1 from
///         published leaves, never asserted (docs/guide/app-enforcement.md, gap 3).
library SparseTree16 {
    uint256 internal constant DEPTH = 16;

    error BadProof();
    error NotSorted();

    function zero(uint256 level) internal pure returns (bytes32 z) {
        for (uint256 i; i < level; ++i) {
            z = keccak256(abi.encodePacked(z, z));
        }
    }

    function emptyRoot() internal pure returns (bytes32) {
        return zero(DEPTH);
    }

    function rootFrom(bytes32 leaf, uint256 index, bytes32[DEPTH] memory siblings) internal pure returns (bytes32 h) {
        if (index >= 1 << DEPTH) revert BadProof();
        h = leaf;
        for (uint256 i; i < DEPTH; ++i) {
            h = (index >> i) & 1 == 0
                ? keccak256(abi.encodePacked(h, siblings[i]))
                : keccak256(abi.encodePacked(siblings[i], h));
        }
    }

    /// @notice Root of a tree holding exactly `leaves` at `indices` (strictly ascending),
    ///         every other leaf empty. O(k · depth) hashing.
    function build(uint256[] memory indices, bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 n = indices.length;
        if (n == 0) return emptyRoot();
        for (uint256 i = 1; i < n; ++i) {
            if (indices[i] <= indices[i - 1]) revert NotSorted();
        }
        if (indices[n - 1] >= 1 << DEPTH) revert NotSorted();
        bytes32 z;
        for (uint256 level; level < DEPTH; ++level) {
            uint256 m;
            for (uint256 i; i < n;) {
                uint256 idx = indices[i];
                bytes32 left;
                bytes32 right;
                if (idx & 1 == 0) {
                    left = leaves[i];
                    if (i + 1 < n && indices[i + 1] == idx + 1) {
                        right = leaves[i + 1];
                        i += 2;
                    } else {
                        right = z;
                        i += 1;
                    }
                } else {
                    left = z;
                    right = leaves[i];
                    i += 1;
                }
                indices[m] = idx >> 1;
                leaves[m] = keccak256(abi.encodePacked(left, right));
                m++;
            }
            n = m;
            z = keccak256(abi.encodePacked(z, z));
        }
        return leaves[0];
    }

    /// @notice Old and new roots of one transition: leaves at `indices` (strictly ascending)
    ///         change from `oldLeaves` to `newLeaves`; every other subtree is unchanged and
    ///         supplied once in `proof`, in the order this walk consumes it (level by level,
    ///         left to right). A multiproof: dense updates need almost no siblings.
    function transition(
        uint256[] memory indices,
        bytes32[] memory oldLeaves,
        bytes32[] memory newLeaves,
        bytes32[] calldata proof
    ) internal pure returns (bytes32, bytes32) {
        uint256 n = indices.length;
        for (uint256 i = 1; i < n; ++i) {
            if (indices[i] <= indices[i - 1]) revert NotSorted();
        }
        if (n == 0 || indices[n - 1] >= 1 << DEPTH) revert NotSorted();
        uint256 p;
        for (uint256 level; level < DEPTH; ++level) {
            uint256 m;
            for (uint256 i; i < n;) {
                uint256 idx = indices[i];
                indices[m] = idx >> 1;
                if (idx & 1 == 0 && i + 1 < n && indices[i + 1] == idx + 1) {
                    oldLeaves[m] = keccak256(abi.encodePacked(oldLeaves[i], oldLeaves[i + 1]));
                    newLeaves[m] = keccak256(abi.encodePacked(newLeaves[i], newLeaves[i + 1]));
                    i += 2;
                } else {
                    bytes32 sib = proof[p++];
                    (oldLeaves[m], newLeaves[m]) = idx & 1 == 0
                        ? (
                            keccak256(abi.encodePacked(oldLeaves[i], sib)),
                            keccak256(abi.encodePacked(newLeaves[i], sib))
                        )
                        : (
                            keccak256(abi.encodePacked(sib, oldLeaves[i])),
                            keccak256(abi.encodePacked(sib, newLeaves[i]))
                        );
                    i += 1;
                }
                m++;
            }
            n = m;
        }
        if (p != proof.length) revert BadProof();
        return (oldLeaves[0], newLeaves[0]);
    }
}

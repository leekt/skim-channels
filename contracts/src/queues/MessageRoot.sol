// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice ethrex's L1-messages Merkle root (NativeRollup._computeL1MessagesRoot) and the
///         matching proof check (OpenZeppelin MerkleProof, sorted pairs).
library MessageRoot {
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 count = leaves.length;
        if (count == 0) return bytes32(0);
        uint256 len = 1;
        while (len < count) len <<= 1;
        bytes32[] memory layer = new bytes32[](len);
        for (uint256 i; i < len; ++i) {
            layer[i] = leaves[i < count ? i : count - 1];
        }
        while (len > 1) {
            len /= 2;
            for (uint256 i; i < len; ++i) {
                layer[i] = _pair(layer[2 * i], layer[2 * i + 1]);
            }
        }
        return layer[0];
    }

    function verify(bytes32[] memory proof, bytes32 r, bytes32 leaf) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i; i < proof.length; ++i) {
            h = _pair(h, proof[i]);
        }
        return h == r;
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {RLP} from "./RLP.sol";

/// @notice Merkle-Patricia proof verification (EIP-1186 style ordered paths).
///         `get` returns (true, value) for a proven key, (false, "") for a proven absence, and
///         reverts when the proof does not settle the key: a missing or wrong node is never
///         read as absence. Proofs must be exact: no unused trailing nodes.
library MerklePatricia {
    using RLP for RLP.Item;

    error InvalidProof();

    bytes32 internal constant EMPTY_ROOT = 0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421;
    uint256 internal constant MAX_NODES = 64;
    uint256 internal constant MAX_NODE_BYTES = 600;

    function _nibble(bytes memory key, uint256 i) private pure returns (uint256) {
        uint256 b = uint8(key[i / 2]);
        return i % 2 == 0 ? b >> 4 : b & 0x0f;
    }

    function get(bytes32 root, bytes memory key, bytes[] memory proof) internal pure returns (bool, bytes memory) {
        if (root == EMPTY_ROOT) {
            if (proof.length != 0) revert InvalidProof();
            return (false, "");
        }
        if (proof.length == 0 || proof.length > MAX_NODES) revert InvalidProof();
        uint256 keyNibbles = key.length * 2;
        uint256 pos;
        uint256 used;
        bytes32 want = root;
        RLP.Item memory node;
        bool hashed = true;
        while (true) {
            if (hashed) {
                if (used >= proof.length) revert InvalidProof();
                bytes memory raw = proof[used++];
                if (raw.length > MAX_NODE_BYTES || keccak256(raw) != want) revert InvalidProof();
                node = RLP.toItem(raw);
            }
            RLP.Item[] memory items = node.readList();
            RLP.Item memory next;
            if (items.length == 17) {
                if (pos >= keyNibbles) revert InvalidProof(); // our keys never end at a branch
                next = items[_nibble(key, pos)];
                pos++;
                if (next.isEmptyString()) return _absent(used, proof.length);
            } else if (items.length == 2) {
                bytes memory path = items[0].toBytes();
                if (path.length == 0) revert InvalidProof();
                uint256 flag = uint8(path[0]) >> 4;
                if (flag > 3) revert InvalidProof();
                bool odd = flag & 1 == 1;
                if (!odd && uint8(path[0]) & 0x0f != 0) revert InvalidProof();
                uint256 start = odd ? 1 : 2;
                uint256 plen = path.length * 2 - start;
                if (flag < 2 && plen == 0) revert InvalidProof(); // empty extension
                for (uint256 j; j < plen; ++j) {
                    if (pos + j >= keyNibbles || _nibble(path, start + j) != _nibble(key, pos + j)) {
                        return _absent(used, proof.length);
                    }
                }
                pos += plen;
                if (flag >= 2) {
                    if (pos != keyNibbles) return _absent(used, proof.length);
                    if (used != proof.length) revert InvalidProof();
                    return (true, items[1].toBytes());
                }
                next = items[1];
                if (next.isEmptyString()) revert InvalidProof();
            } else {
                revert InvalidProof();
            }
            if (next.isList()) {
                if (next.len >= 32) revert InvalidProof(); // only short nodes are inlined
                node = next;
                hashed = false;
            } else {
                want = next.toBytes32();
                hashed = true;
            }
        }
        revert InvalidProof(); // unreachable
    }

    function _absent(uint256 used, uint256 n) private pure returns (bool, bytes memory) {
        if (used != n) revert InvalidProof();
        return (false, "");
    }

    /// @notice The trie key for a transaction index: RLP(index).
    function indexKey(uint256 index) internal pure returns (bytes memory) {
        if (index == 0) return hex"80";
        if (index < 0x80) return abi.encodePacked(uint8(index));
        uint256 n;
        for (uint256 v = index; v > 0; v >>= 8) {
            n++;
        }
        bytes memory out = new bytes(1 + n);
        out[0] = bytes1(uint8(0x80 + n));
        for (uint256 i; i < n; ++i) {
            out[n - i] = bytes1(uint8(index >> (8 * i)));
        }
        return out;
    }
}

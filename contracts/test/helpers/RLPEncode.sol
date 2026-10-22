// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// Test-only RLP encoder, for building L2 receipts, headers and one-leaf receipt tries.
library RLPEncode {
    function str(bytes memory b) internal pure returns (bytes memory) {
        if (b.length == 1 && uint8(b[0]) < 0x80) return b;
        return bytes.concat(_prefix(0x80, b.length), b);
    }

    function num(uint256 v) internal pure returns (bytes memory) {
        if (v == 0) return hex"80";
        uint256 n;
        for (uint256 x = v; x > 0; x >>= 8) n++;
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) b[n - 1 - i] = bytes1(uint8(v >> (8 * i)));
        return str(b);
    }

    function list(bytes[] memory items) internal pure returns (bytes memory) {
        bytes memory body;
        for (uint256 i; i < items.length; ++i) body = bytes.concat(body, items[i]);
        return bytes.concat(_prefix(0xc0, body.length), body);
    }

    function _prefix(uint8 offset, uint256 len) private pure returns (bytes memory) {
        if (len < 56) return abi.encodePacked(uint8(offset + len));
        uint256 n;
        for (uint256 x = len; x > 0; x >>= 8) n++;
        bytes memory b = new bytes(1 + n);
        b[0] = bytes1(uint8(offset + 55 + n));
        for (uint256 i; i < n; ++i) b[n - i] = bytes1(uint8(len >> (8 * i)));
        return b;
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice Strict, bounded RLP reader over memory. Items are (ptr, len) views; nothing is
///         copied until a value is extracted. Non-canonical encodings are rejected: a single
///         byte < 0x80 wrapped as a string, long forms for short payloads, leading zeros in
///         lengths or integers.
library RLP {
    struct Item {
        uint256 ptr; // first byte of the encoding (prefix included)
        uint256 len; // whole encoding length
    }

    error RLPMalformed();

    uint256 internal constant MAX_LIST_ITEMS = 32;

    function toItem(bytes memory b) internal pure returns (Item memory it) {
        uint256 p;
        assembly {
            p := add(b, 32)
        }
        it = Item(p, b.length);
        (,, uint256 total) = _header(it);
        if (total != it.len) revert RLPMalformed();
    }

    /// @notice A view of `b[offset:]` as one item; must span it exactly.
    function toItemAt(bytes memory b, uint256 offset) internal pure returns (Item memory it) {
        if (offset > b.length) revert RLPMalformed();
        uint256 p;
        assembly {
            p := add(add(b, 32), offset)
        }
        it = Item(p, b.length - offset);
        (,, uint256 total) = _header(it);
        if (total != it.len) revert RLPMalformed();
    }

    function _byteAt(uint256 p) private pure returns (uint256 v) {
        assembly {
            v := byte(0, mload(p))
        }
    }

    /// (isList, payload offset from it.ptr, total encoded length)
    function _header(Item memory it) private pure returns (bool list, uint256 off, uint256 total) {
        if (it.len == 0) revert RLPMalformed();
        uint256 b0 = _byteAt(it.ptr);
        uint256 plen;
        if (b0 < 0x80) {
            return (false, 0, 1);
        } else if (b0 < 0xb8) {
            plen = b0 - 0x80;
            if (plen == 1) {
                if (it.len < 2 || _byteAt(it.ptr + 1) < 0x80) revert RLPMalformed();
            }
            off = 1;
        } else if (b0 < 0xc0) {
            (off, plen) = _longLen(it, b0 - 0xb7);
        } else if (b0 < 0xf8) {
            list = true;
            plen = b0 - 0xc0;
            off = 1;
        } else {
            list = true;
            (off, plen) = _longLen(it, b0 - 0xf7);
        }
        total = off + plen;
        if (total > it.len || total < off) revert RLPMalformed();
    }

    function _longLen(Item memory it, uint256 n) private pure returns (uint256 off, uint256 plen) {
        if (n > 4 || it.len < 1 + n) revert RLPMalformed(); // payloads beyond 4 GiB are not ours
        if (_byteAt(it.ptr + 1) == 0) revert RLPMalformed();
        for (uint256 i; i < n; ++i) {
            plen = (plen << 8) | _byteAt(it.ptr + 1 + i);
        }
        if (plen < 56) revert RLPMalformed();
        off = 1 + n;
    }

    function isList(Item memory it) internal pure returns (bool l) {
        (l,,) = _header(it);
    }

    function payload(Item memory it) internal pure returns (uint256 ptr, uint256 len) {
        (, uint256 off, uint256 total) = _header(it);
        return (it.ptr + off, total - off);
    }

    /// @notice The list's items (at most MAX_LIST_ITEMS); they must exactly fill it.
    function readList(Item memory it) internal pure returns (Item[] memory items) {
        (bool l, uint256 off, uint256 total) = _header(it);
        if (!l || total != it.len) revert RLPMalformed();
        items = new Item[](MAX_LIST_ITEMS);
        uint256 p = it.ptr + off;
        uint256 end = it.ptr + total;
        uint256 n;
        while (p < end) {
            if (n == MAX_LIST_ITEMS) revert RLPMalformed();
            Item memory sub = Item(p, end - p);
            (,, uint256 t) = _header(sub);
            sub.len = t;
            items[n++] = sub;
            p += t;
        }
        assembly {
            mstore(items, n)
        }
    }

    /// @notice An unbounded list (logs, topics); `max` caps the count.
    function readListMax(Item memory it, uint256 max) internal pure returns (Item[] memory items) {
        (bool l, uint256 off, uint256 total) = _header(it);
        if (!l || total != it.len) revert RLPMalformed();
        items = new Item[](max);
        uint256 p = it.ptr + off;
        uint256 end = it.ptr + total;
        uint256 n;
        while (p < end) {
            if (n == max) revert RLPMalformed();
            Item memory sub = Item(p, end - p);
            (,, uint256 t) = _header(sub);
            sub.len = t;
            items[n++] = sub;
            p += t;
        }
        assembly {
            mstore(items, n)
        }
    }

    function toBytes(Item memory it) internal pure returns (bytes memory out) {
        (bool l, uint256 off, uint256 total) = _header(it);
        if (l || total != it.len) revert RLPMalformed();
        uint256 n = total - off;
        out = new bytes(n);
        uint256 src = it.ptr + off;
        assembly {
            mcopy(add(out, 32), src, n)
        }
    }

    /// @notice The raw encoding of the item (for hashing an inline node).
    function raw(Item memory it) internal pure returns (bytes memory out) {
        uint256 n = it.len;
        out = new bytes(n);
        uint256 src = it.ptr;
        assembly {
            mcopy(add(out, 32), src, n)
        }
    }

    function isEmptyString(Item memory it) internal pure returns (bool) {
        return it.len == 1 && _byteAt(it.ptr) == 0x80;
    }

    function toUint(Item memory it) internal pure returns (uint256 v) {
        (bool l, uint256 off, uint256 total) = _header(it);
        if (l || total != it.len) revert RLPMalformed();
        uint256 n = total - off;
        if (n > 32) revert RLPMalformed();
        if (n > 0 && _byteAt(it.ptr + off) == 0) revert RLPMalformed(); // leading zero
        uint256 p = it.ptr + off;
        for (uint256 i; i < n; ++i) {
            v = (v << 8) | _byteAt(p + i);
        }
    }

    function toBytes32(Item memory it) internal pure returns (bytes32 v) {
        (bool l, uint256 off, uint256 total) = _header(it);
        if (l || total != it.len || total - off != 32) revert RLPMalformed();
        uint256 p = it.ptr + off;
        assembly {
            v := mload(p)
        }
    }

    function toAddress(Item memory it) internal pure returns (address a) {
        (bool l, uint256 off, uint256 total) = _header(it);
        if (l || total != it.len || total - off != 20) revert RLPMalformed();
        uint256 p = it.ptr + off;
        assembly {
            a := shr(96, mload(p))
        }
    }

    /// @notice keccak256 of the item's payload bytes (string items only).
    function payloadHash(Item memory it) internal pure returns (bytes32 h) {
        (uint256 p, uint256 n) = payload(it);
        assembly {
            h := keccak256(p, n)
        }
    }

    function hash(Item memory it) internal pure returns (bytes32 h) {
        uint256 p = it.ptr;
        uint256 n = it.len;
        assembly {
            h := keccak256(p, n)
        }
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {RLP} from "./RLP.sol";

/// @notice Strict decoding of Ethereum headers, receipts and trie accounts.
library EthTypes {
    using RLP for RLP.Item;

    error BadHeader();
    error BadReceipt();
    error BadAccount();

    uint256 internal constant MAX_LOGS = 256;
    uint256 internal constant MAX_TOPICS = 4;

    struct HeaderFields {
        bytes32 hash;
        bytes32 parentHash;
        bytes32 stateRoot;
        bytes32 receiptsRoot;
        uint256 number;
        uint256 timestamp;
    }

    /// @notice keccak256(raw) plus the fields channels use. Any header shape with at least
    ///         the 15 London-era fields is accepted; later forks append fields.
    function decodeHeader(bytes memory raw) internal pure returns (HeaderFields memory h) {
        RLP.Item[] memory f = RLP.toItem(raw).readList();
        if (f.length < 15) revert BadHeader();
        h.hash = keccak256(raw);
        h.parentHash = f[0].toBytes32();
        h.stateRoot = f[3].toBytes32();
        h.receiptsRoot = f[5].toBytes32();
        h.number = f[8].toUint();
        h.timestamp = f[11].toUint();
    }

    struct Log {
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    /// @notice (type, success, logs) of a consensus-encoded receipt. Typed receipts keep
    ///         their EIP-2718 type byte; only types 1..4 are known. Pre-Byzantium state roots
    ///         are rejected.
    function decodeReceipt(bytes memory enc) internal pure returns (uint8 txType, bool success, RLP.Item[] memory logs) {
        if (enc.length == 0) revert BadReceipt();
        uint8 b0 = uint8(enc[0]);
        RLP.Item memory body;
        if (b0 >= 0xc0) {
            body = RLP.toItem(enc);
        } else {
            if (b0 < 1 || b0 > 4) revert BadReceipt();
            txType = b0;
            body = RLP.toItemAt(enc, 1);
        }
        RLP.Item[] memory f = body.readList();
        if (f.length != 4) revert BadReceipt();
        uint256 status = f[0].toUint();
        if (status > 1) revert BadReceipt();
        success = status == 1;
        f[1].toUint(); // cumulative gas: must be a canonical integer
        (, uint256 bloomLen) = f[2].payload();
        if (f[2].isList() || bloomLen != 256) revert BadReceipt();
        logs = f[3].readListMax(MAX_LOGS);
    }

    function decodeLog(RLP.Item memory item) internal pure returns (Log memory l) {
        RLP.Item[] memory f = item.readList();
        if (f.length != 3) revert BadReceipt();
        l.emitter = f[0].toAddress();
        RLP.Item[] memory t = f[1].readListMax(MAX_TOPICS);
        l.topics = new bytes32[](t.length);
        for (uint256 i; i < t.length; ++i) {
            l.topics[i] = t[i].toBytes32();
        }
        l.data = f[2].toBytes();
    }

    struct Account {
        uint256 nonce;
        uint256 balance;
        bytes32 storageRoot;
        bytes32 codeHash;
    }

    function decodeAccount(bytes memory leaf) internal pure returns (Account memory a) {
        RLP.Item[] memory f = RLP.toItem(leaf).readList();
        if (f.length != 4) revert BadAccount();
        a.nonce = f[0].toUint();
        a.balance = f[1].toUint();
        a.storageRoot = f[2].toBytes32();
        a.codeHash = f[3].toBytes32();
    }

    /// @notice A storage leaf: RLP of a nonzero integer.
    function decodeSlotValue(bytes memory leaf) internal pure returns (uint256 v) {
        v = RLP.toItem(leaf).toUint();
        if (v == 0) revert BadAccount(); // zero slots are absent from the trie
    }
}

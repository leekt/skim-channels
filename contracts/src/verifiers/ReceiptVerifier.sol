// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {RLP} from "../libraries/RLP.sol";
import {MerklePatricia} from "../libraries/MerklePatricia.sol";
import {EthTypes} from "../libraries/EthTypes.sol";

/// @notice Stateless, shared receipt verifier: header → receiptsRoot → receipt inclusion
///         (key RLP(txIndex)) → typed receipt → one log. A separate contract for the same
///         deployability reason as WitnessVerifier.
contract ReceiptVerifier {
    struct Result {
        bool included; // the receipt is the leaf at txIndex under receiptsRoot
        bool success; // EIP-658 status
        bool hasLog; // logIndex < number of logs
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    /// @return blockHash keccak256(header)
    /// @return receiptsRoot the header's receipts root
    function headerRoots(bytes calldata header) external pure returns (bytes32 blockHash, bytes32 receiptsRoot) {
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(header);
        return (h.hash, h.receiptsRoot);
    }

    /// @notice Reverts on a malformed proof; `included` is false for a well-formed proof of
    ///         another leaf. Callers check `receiptsRoot` against an accepted header first.
    function verify(
        bytes32 receiptsRoot,
        uint256 txIndex,
        bytes calldata receipt,
        bytes[] calldata proof,
        uint256 logIndex
    ) external pure returns (Result memory r) {
        (bool found, bytes memory leaf) = MerklePatricia.get(receiptsRoot, MerklePatricia.indexKey(txIndex), proof);
        r.included = found && keccak256(leaf) == keccak256(receipt);
        if (!r.included) return r;
        RLP.Item[] memory logs;
        (, r.success, logs) = EthTypes.decodeReceipt(receipt);
        r.hasLog = logIndex < logs.length;
        if (!r.hasLog) return r;
        EthTypes.Log memory l = EthTypes.decodeLog(logs[logIndex]);
        (r.emitter, r.topics, r.data) = (l.emitter, l.topics, l.data);
    }
}

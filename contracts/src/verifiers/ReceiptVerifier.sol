// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {RLP} from "../libraries/RLP.sol";
import {MerklePatricia} from "../libraries/MerklePatricia.sol";
import {EthTypes} from "../libraries/EthTypes.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

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

    bytes32 internal constant OUTCOME_TOPIC = keccak256("ChannelOutcome(bytes32,bytes32,bytes32,bytes32,bytes32)");

    // Same signature as ChannelSettlement.Invalid, so callers see one error type.
    error Invalid(string what);

    /// @notice The stateless part of settling one channel: the receipt is included under `rr`
    ///         and succeeded; log `logIndex` is `executor`'s ChannelOutcome for `channelId` and
    ///         the EIP-712 digest of `request` under (this chain, `settlement`); it commits to
    ///         the request's anchor and policy and to keccak256(outcome).
    /// @return r the decoded request (the caller checks it against the channel's state)
    /// @return requestHash its signing digest
    function outcome(
        bytes32 rr,
        uint256 txIndex,
        bytes calldata receipt,
        bytes[] calldata proof,
        uint256 logIndex,
        bytes calldata request,
        bytes calldata outcomeBytes,
        address executor,
        bytes32 channelId,
        address settlement
    ) external view returns (ChannelTypes.FinalRequest memory r, bytes32 requestHash) {
        Result memory log = this.verify(rr, txIndex, receipt, proof, logIndex);
        if (!log.included) revert Invalid("receipt proof");
        if (!log.success) revert Invalid("receipt status");
        if (!log.hasLog) revert Invalid("log index");
        r = ChannelTypes.decodeFinalRequest(request);
        requestHash = ChannelTypes.requestSigningHash(r, block.chainid, settlement);
        if (log.emitter != executor) revert Invalid("emitter");
        if (log.topics.length != 3 || log.topics[0] != OUTCOME_TOPIC) revert Invalid("event");
        if (log.topics[1] != channelId || log.topics[2] != requestHash) revert Invalid("log binding");
        if (keccak256(log.data) != keccak256(abi.encode(r.anchorId, r.policyHash, keccak256(outcomeBytes)))) {
            revert Invalid("log data");
        }
    }
}

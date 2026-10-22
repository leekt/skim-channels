// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ChannelTypes} from "./libraries/ChannelTypes.sol";
import {EthTypes} from "./libraries/EthTypes.sol";

/// @notice L1: anchors authenticated by L1 itself. A raw header is recorded only if its hash
///         is the canonical block hash at its height, from BLOCKHASH (last 256 blocks) or the
///         EIP-2935 history contract (last 8191). Settlement only accepts recorded anchors,
///         and because recording happens on L1's canonical chain, an anchor from a block that
///         L1 later reorgs away can't be recorded on the chain where settlement happens.
contract AnchorRegistry {
    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;

    mapping(bytes32 anchorId => bool) public recorded;
    /// The state root of each recorded anchor (for verifying witnesses on L1).
    mapping(bytes32 anchorId => bytes32) public stateRootOf;

    event AnchorRecorded(bytes32 indexed anchorId, uint64 blockNumber, bytes32 blockHash, bytes32 stateRoot);

    error NotCanonical(uint256 number, bytes32 hash);

    function record(bytes calldata rawHeader) external returns (bytes32 anchorId) {
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(rawHeader);
        if (h.number >= block.number || canonicalHash(h.number) != h.hash) revert NotCanonical(h.number, h.hash);
        anchorId = ChannelTypes.anchorId(ChannelTypes.L1Anchor(block.chainid, uint64(h.number), h.hash, h.stateRoot));
        recorded[anchorId] = true;
        stateRootOf[anchorId] = h.stateRoot;
        emit AnchorRecorded(anchorId, uint64(h.number), h.hash, h.stateRoot);
    }

    function canonicalHash(uint256 number) public view returns (bytes32 h) {
        h = blockhash(number);
        if (h != 0 || HISTORY.code.length == 0) return h;
        (bool ok, bytes memory out) = HISTORY.staticcall(abi.encode(number));
        if (ok && out.length == 32) h = abi.decode(out, (bytes32));
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {L2AnchorInbox} from "./L2AnchorInbox.sol";
import {MerklePatricia} from "./libraries/MerklePatricia.sol";
import {EthTypes} from "./libraries/EthTypes.sol";

/// @notice L2: explicit L1 storage reads (PROJECT.md §3.5). SLOAD keeps its native meaning;
///         this verifies EIP-1186 proofs against an anchor the inbox holds. Absent accounts,
///         empty tries and absent slots read zero only when proven so.
contract L1StateReader {
    L2AnchorInbox public immutable inbox;

    error UnknownAnchor(bytes32 anchorId);
    error BadProof();

    constructor(L2AnchorInbox inbox_) {
        inbox = inbox_;
    }

    function readStorage(
        bytes32 anchorId,
        address account,
        bytes32 slot,
        bytes[] calldata accountProof,
        bytes[] calldata storageProof
    ) external view returns (bytes32) {
        bytes32 root = inbox.stateRootOf(anchorId);
        if (root == 0) revert UnknownAnchor(anchorId);
        (bool found, bytes memory leaf) =
            MerklePatricia.get(root, abi.encodePacked(keccak256(abi.encodePacked(account))), accountProof);
        if (!found) {
            if (storageProof.length != 0) revert BadProof();
            return 0;
        }
        bytes32 sroot = EthTypes.decodeAccount(leaf).storageRoot;
        (bool sfound, bytes memory sleaf) =
            MerklePatricia.get(sroot, abi.encodePacked(keccak256(abi.encodePacked(slot))), storageProof);
        return sfound ? bytes32(EthTypes.decodeSlotValue(sleaf)) : bytes32(0);
    }
}

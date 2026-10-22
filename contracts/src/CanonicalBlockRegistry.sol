// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IAcceptedBlockRegistry} from "./interfaces/IAcceptedBlockRegistry.sol";
import {IStateTransitionVerifier} from "./interfaces/IStateTransitionVerifier.sol";
import {AnchorRegistry} from "./AnchorRegistry.sol";
import {EthTypes} from "./libraries/EthTypes.sol";

/// @notice L1: canonical L2 block acceptance (PROJECT.md §6.4), permissionless (docs/STAGE2.md).
///         A block is accepted only if, together:
///         - it extends the current canonical tip (parent hash and number), from a fixed genesis:
///           one chain, no competing forks;
///         - the L1 anchor it carries was recorded on L1 (AnchorRegistry);
///         - its data was published in this L1 transaction: `daCommitment` is BLOBHASH(0)
///           (EIP-4844), so anyone can rebuild the L2 from L1;
///         - the verifier accepts the transition from the parent's state root under the
///           deployment's execution profile.
///         Anyone may submit. Acceptance is exactly as strong as the verifier: with
///         MockTransitionVerifier it is NOT execution security, and profileKind() says so.
contract CanonicalBlockRegistry is IAcceptedBlockRegistry {
    bytes32 public immutable rollupId;
    bytes32 public immutable profileHash;
    bytes32 public immutable genesisHash;
    IStateTransitionVerifier public immutable verifier;
    AnchorRegistry public immutable anchors;

    bytes32 public head;
    mapping(bytes32 blockHash => AcceptedBlock) internal blocks;

    event BlockAccepted(bytes32 indexed blockHash, uint64 number, bytes32 daCommitment, address submitter);

    error Rejected(string why);

    constructor(
        bytes32 rollupId_,
        bytes32 profileHash_,
        IStateTransitionVerifier verifier_,
        AnchorRegistry anchors_,
        bytes memory genesisHeader
    ) {
        rollupId = rollupId_;
        profileHash = profileHash_;
        verifier = verifier_;
        anchors = anchors_;
        EthTypes.HeaderFields memory g = EthTypes.decodeHeader(genesisHeader);
        if (g.number != 0) revert Rejected("genesis number");
        genesisHash = g.hash;
        head = g.hash;
        blocks[g.hash] = AcceptedBlock(g.parentHash, g.stateRoot, g.receiptsRoot, 0, profileHash_, 0, true);
    }

    function profileKind() external view returns (uint8) {
        return verifier.profileKind();
    }

    function submit(bytes calldata rawHeader, bytes32 l1AnchorId, bytes calldata proof) external returns (bytes32) {
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(rawHeader);
        AcceptedBlock memory parent = blocks[h.parentHash];
        if (h.parentHash != head) revert Rejected("not on the canonical tip");
        if (h.number != uint256(parent.blockNumber) + 1) revert Rejected("number");
        if (!anchors.recorded(l1AnchorId)) revert Rejected("L1 anchor not recorded");
        bytes32 da = blobhash(0);
        if (da == 0) revert Rejected("no blob: data not on L1");
        if (!verifier.verify(profileHash, parent.stateRoot, rawHeader, da, l1AnchorId, proof)) {
            revert Rejected("transition not verified");
        }
        blocks[h.hash] =
            AcceptedBlock(h.parentHash, h.stateRoot, h.receiptsRoot, l1AnchorId, profileHash, uint64(h.number), true);
        head = h.hash;
        emit BlockAccepted(h.hash, uint64(h.number), da, msg.sender);
        return h.hash;
    }

    function isAcceptedBlock(bytes32 rollupId_, bytes32 blockHash) external view returns (bool) {
        return rollupId_ == rollupId && blocks[blockHash].accepted;
    }

    function acceptedBlock(bytes32 rollupId_, bytes32 blockHash) external view returns (AcceptedBlock memory b) {
        if (rollupId_ == rollupId) b = blocks[blockHash];
    }
}

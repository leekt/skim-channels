// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IAcceptedBlockRegistry} from "./interfaces/IAcceptedBlockRegistry.sol";
import {ChannelTypes} from "./libraries/ChannelTypes.sol";
import {EthTypes} from "./libraries/EthTypes.sol";
import {MerklePatricia} from "./libraries/MerklePatricia.sol";

/// @notice The part of an EIP-8079-style native rollup contract this adapter reads: state roots
///         that L1 itself verified by re-executing each L2 block with the EXECUTE precompile.
///         (ethrex `NativeRollup.sol`, PR #6418.)
interface INativeRollup {
    function blockHash() external view returns (bytes32);
    function stateRootHistory(uint256 number) external view returns (bytes32);
    function stateRootTimestamps(uint256 number) external view returns (uint256);
    function FINALITY_DELAY() external view returns (uint256);
}

/// @notice L1: block acceptance backed by native execution verification (profile
///         `native-reexecution-devnet`, PROJECT.md §6.3). Nothing here is asserted by an
///         operator; a block is accepted (permissionlessly) only if its raw header is bound to
///         an EXECUTE-verified, final state:
///         - tip: keccak(header) is the native rollup's current verified block hash; or
///         - history: the L2's own EIP-2935 history contract holds keccak(header) at slot
///           number % 8191, proven (MPT) against a later EXECUTE-verified state root.
///         Either way the header's state root must equal the verified root at its height, and
///         the roots used must be past the rollup's finality delay. The header then
///         authenticates its receipts root for settlement.
contract NativeRollupRegistry is IAcceptedBlockRegistry {
    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    uint256 internal constant HISTORY_WINDOW = 8191;

    bytes32 public immutable rollupId;
    bytes32 public immutable profileHash;
    INativeRollup public immutable native;

    mapping(bytes32 blockHash => AcceptedBlock) internal blocks;

    event Accepted(bytes32 indexed blockHash, uint64 number);

    error Rejected(string why);

    constructor(bytes32 rollupId_, bytes32 profileHash_, INativeRollup native_) {
        rollupId = rollupId_;
        profileHash = profileHash_;
        native = native_;
    }

    function profileKind() external pure returns (uint8) {
        return ChannelTypes.PROFILE_NATIVE_REEXECUTION_DEVNET;
    }

    function _verifiedRoot(uint256 number) internal view returns (bytes32 root) {
        root = native.stateRootHistory(number);
        if (root == 0) revert Rejected("no verified state at that height");
        if (block.timestamp < native.stateRootTimestamps(number) + native.FINALITY_DELAY()) {
            revert Rejected("not final");
        }
    }

    function acceptTip(bytes calldata rawHeader) external returns (bytes32) {
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(rawHeader);
        if (h.hash != native.blockHash()) revert Rejected("not the verified tip");
        return _record(h);
    }

    function acceptHistorical(
        bytes calldata rawHeader,
        uint256 laterNumber,
        bytes[] calldata accountProof,
        bytes[] calldata storageProof
    ) external returns (bytes32) {
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(rawHeader);
        if (laterNumber <= h.number || laterNumber - h.number > HISTORY_WINDOW) revert Rejected("history window");
        bytes32 root = _verifiedRoot(laterNumber);
        (bool found, bytes memory leaf) =
            MerklePatricia.get(root, abi.encodePacked(keccak256(abi.encodePacked(HISTORY))), accountProof);
        if (!found) revert Rejected("no history contract");
        bytes32 storageRoot = EthTypes.decodeAccount(leaf).storageRoot;
        bytes32 slot = bytes32(h.number % HISTORY_WINDOW);
        (bool sfound, bytes memory sleaf) =
            MerklePatricia.get(storageRoot, abi.encodePacked(keccak256(abi.encodePacked(slot))), storageProof);
        if (!sfound || bytes32(EthTypes.decodeSlotValue(sleaf)) != h.hash) revert Rejected("hash not in history");
        return _record(h);
    }

    function _record(EthTypes.HeaderFields memory h) internal returns (bytes32) {
        if (h.stateRoot != _verifiedRoot(h.number)) revert Rejected("state root not verified");
        blocks[h.hash] =
            AcceptedBlock(h.parentHash, h.stateRoot, h.receiptsRoot, 0, profileHash, uint64(h.number), true);
        emit Accepted(h.hash, uint64(h.number));
        return h.hash;
    }

    function isAcceptedBlock(bytes32 rollupId_, bytes32 blockHash) external view returns (bool) {
        return rollupId_ == rollupId && blocks[blockHash].accepted;
    }

    function acceptedBlock(bytes32 rollupId_, bytes32 blockHash) external view returns (AcceptedBlock memory b) {
        if (rollupId_ == rollupId) b = blocks[blockHash];
    }
}

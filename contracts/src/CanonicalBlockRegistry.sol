// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IAcceptedBlockRegistry} from "./interfaces/IAcceptedBlockRegistry.sol";
import {IStateTransitionVerifier} from "./interfaces/IStateTransitionVerifier.sol";
import {AnchorRegistry} from "./AnchorRegistry.sol";
import {EthTypes} from "./libraries/EthTypes.sol";

/// @notice L1: canonical L2 block acceptance (PROJECT.md §6.4), permissionless (docs/STAGE2.md).
///
/// A block is accepted only if, together:
/// - it extends the canonical tip (parent hash and number) from a fixed genesis: one chain;
/// - the L1 anchor it carries was recorded on L1 (AnchorRegistry);
/// - its data is published in this L1 transaction: `daCommitment` = BLOBHASH(0) (EIP-4844);
/// - it consumes every forced-inclusion entry older than FORCE_DELAY (censorship resistance);
/// - the verifier accepts the transition.
/// Anyone may submit blocks and anyone may force-include transactions.
///
/// Governance (Stage 2 shape): only `governance` (a RollupGovernance timelock with a ≥ 30-day
/// delay) may replace the verifier. If anyone proves on chain that the verifier accepted two
/// different results for identical inputs (`proveConflict`), the registry freezes: no new
/// blocks, and no block is reported accepted, so receipt settlement halts while the
/// operator-free emergency exit (L1 re-execution) keeps working. Only then may the
/// governance's Security Council replace the verifier without the delay.
contract CanonicalBlockRegistry is IAcceptedBlockRegistry {
    uint256 public constant FORCE_DELAY = 1 days;
    uint256 public constant MAX_FORCED_TX_BYTES = 128 * 1024;

    bytes32 public immutable rollupId;
    bytes32 public immutable profileHash;
    bytes32 public immutable genesisHash;
    AnchorRegistry public immutable anchors;
    address public immutable governance;

    IStateTransitionVerifier public verifier;
    bool public frozen;
    bytes32 public head;
    mapping(bytes32 blockHash => AcceptedBlock) internal blocks;

    /// Forced inclusion: entry i has rolling accumulator forcedAcc[i + 1] and a timestamp.
    bytes32[] public forcedAcc;
    uint64[] public forcedAt;
    uint256 public forcedCursor;
    mapping(bytes32 blockHash => uint256) public forcedCursorAt;

    event BlockAccepted(bytes32 indexed blockHash, uint64 number, bytes32 daCommitment, address submitter);
    event ForcedTransaction(uint256 indexed index, bytes32 txHash, bytes32 acc);
    event Frozen(bytes32 parentStateRoot, bytes32 blockA, bytes32 blockB);
    event VerifierReplaced(address verifier, bool emergency);

    error Rejected(string why);

    constructor(
        bytes32 rollupId_,
        bytes32 profileHash_,
        IStateTransitionVerifier verifier_,
        AnchorRegistry anchors_,
        bytes memory genesisHeader,
        address governance_
    ) {
        rollupId = rollupId_;
        profileHash = profileHash_;
        verifier = verifier_;
        anchors = anchors_;
        governance = governance_;
        EthTypes.HeaderFields memory g = EthTypes.decodeHeader(genesisHeader);
        if (g.number != 0) revert Rejected("genesis number");
        genesisHash = g.hash;
        head = g.hash;
        blocks[g.hash] = AcceptedBlock(g.parentHash, g.stateRoot, g.receiptsRoot, 0, profileHash_, 0, true);
        forcedAcc.push(0);
    }

    function profileKind() external view returns (uint8) {
        return verifier.profileKind();
    }

    // ---- forced inclusion ------------------------------------------------------------------

    /// @notice Queues a signed L2 transaction that every block producer must include once it
    ///         is FORCE_DELAY old. Anyone may call.
    function forceInclude(bytes calldata signedTx) external returns (uint256 index) {
        if (signedTx.length == 0 || signedTx.length > MAX_FORCED_TX_BYTES) revert Rejected("forced tx size");
        index = forcedAt.length;
        bytes32 acc = keccak256(abi.encode(forcedAcc[index], keccak256(signedTx)));
        forcedAcc.push(acc);
        forcedAt.push(uint64(block.timestamp));
        emit ForcedTransaction(index, keccak256(signedTx), acc);
    }

    function forcedCount() external view returns (uint256) {
        return forcedAt.length;
    }

    // ---- blocks ----------------------------------------------------------------------------

    /// @param newForcedCursor how many queue entries (in total) this block has included.
    function submit(bytes calldata rawHeader, bytes32 l1AnchorId, uint256 newForcedCursor, bytes calldata proof)
        external
        returns (bytes32)
    {
        if (frozen) revert Rejected("frozen");
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(rawHeader);
        AcceptedBlock memory parent = blocks[h.parentHash];
        if (h.parentHash != head) revert Rejected("not on the canonical tip");
        if (h.number != uint256(parent.blockNumber) + 1) revert Rejected("number");
        if (!anchors.recorded(l1AnchorId)) revert Rejected("L1 anchor not recorded");
        bytes32 da = blobhash(0);
        if (da == 0) revert Rejected("no blob: data not on L1");
        if (newForcedCursor < forcedCursor || newForcedCursor > forcedAt.length) revert Rejected("forced cursor");
        if (newForcedCursor < forcedAt.length && block.timestamp >= uint256(forcedAt[newForcedCursor]) + FORCE_DELAY) {
            revert Rejected("overdue forced transaction not included");
        }
        IStateTransitionVerifier.Transition memory t = IStateTransitionVerifier.Transition({
            profileHash: profileHash,
            parentStateRoot: parent.stateRoot,
            daCommitment: da,
            l1AnchorId: l1AnchorId,
            forcedTxsAcc: forcedAcc[newForcedCursor],
            rawHeader: rawHeader
        });
        if (!verifier.verify(t, proof)) revert Rejected("transition not verified");
        blocks[h.hash] =
            AcceptedBlock(h.parentHash, h.stateRoot, h.receiptsRoot, l1AnchorId, profileHash, uint64(h.number), true);
        head = h.hash;
        forcedCursor = newForcedCursor;
        forcedCursorAt[h.hash] = newForcedCursor;
        emit BlockAccepted(h.hash, uint64(h.number), da, msg.sender);
        return h.hash;
    }

    // ---- faults and governance -------------------------------------------------------------

    /// @notice Anyone: two verifier-accepted transitions with identical inputs (parent state,
    ///         data, anchor, forced transactions, profile) but different results prove the
    ///         verifier unsound. Freezes the registry.
    function proveConflict(
        IStateTransitionVerifier.Transition calldata a,
        bytes calldata proofA,
        bytes calldata headerB,
        bytes calldata proofB
    ) external {
        if (a.profileHash != profileHash) revert Rejected("profile");
        EthTypes.HeaderFields memory ha = EthTypes.decodeHeader(a.rawHeader);
        EthTypes.HeaderFields memory hb = EthTypes.decodeHeader(headerB);
        if (ha.parentHash != hb.parentHash || ha.number != hb.number) revert Rejected("different positions");
        if (ha.stateRoot == hb.stateRoot && ha.receiptsRoot == hb.receiptsRoot) revert Rejected("same result");
        IStateTransitionVerifier.Transition memory b = a;
        b.rawHeader = headerB;
        if (!verifier.verify(a, proofA) || !verifier.verify(b, proofB)) revert Rejected("not both verified");
        frozen = true;
        emit Frozen(a.parentStateRoot, ha.hash, hb.hash);
    }

    /// @notice Only governance. `emergency` replacements require a proven fault (frozen) and
    ///         unfreeze; ordinary ones are delayed by the governance timelock.
    function replaceVerifier(IStateTransitionVerifier v, bool emergency) external {
        if (msg.sender != governance) revert Rejected("not governance");
        if (emergency) {
            if (!frozen) revert Rejected("no proven fault");
            frozen = false;
        }
        verifier = v;
        emit VerifierReplaced(address(v), emergency);
    }

    function isAcceptedBlock(bytes32 rollupId_, bytes32 blockHash) external view returns (bool) {
        return !frozen && rollupId_ == rollupId && blocks[blockHash].accepted;
    }

    function acceptedBlock(bytes32 rollupId_, bytes32 blockHash) external view returns (AcceptedBlock memory b) {
        if (!frozen && rollupId_ == rollupId) b = blocks[blockHash];
    }
}

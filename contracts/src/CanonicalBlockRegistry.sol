// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IAcceptedBlockRegistry} from "./interfaces/IAcceptedBlockRegistry.sol";
import {IStateTransitionVerifier} from "./interfaces/IStateTransitionVerifier.sol";
import {IL1MessageQueue} from "./interfaces/IL1MessageQueue.sol";
import {AnchorRegistry} from "./AnchorRegistry.sol";
import {EthTypes} from "./libraries/EthTypes.sol";

/// @notice L1: canonical L2 block acceptance (PROJECT.md §6.4), permissionless (docs/STAGE2.md).
///
/// A block is accepted only if, together:
/// - it extends the canonical tip (parent hash and number) from a fixed genesis: one chain;
/// - the L1 anchor it claims, if any, was recorded on L1 (AnchorRegistry);
/// - its data is on L1 in this transaction: the blob (BLOBHASH(0)) or, in calldata mode, the
///   proof itself (e.g. EXECUTE's stateless input, which carries the whole block);
/// - it consumes the L1 messages [cursor, newCursor) of `messages` — committed to by the
///   transition — including every message that is overdue (forced inclusion);
/// - the verifier accepts the transition.
/// Anyone may submit blocks.
///
/// Governance (Stage 2 shape): only `governance` (a RollupGovernance timelock with a ≥ 30-day
/// delay) may replace the verifier. If anyone proves on chain that the verifier accepted two
/// different results for identical inputs (`proveConflict`), the registry freezes: no new
/// blocks, and no block is reported accepted, so receipt settlement halts while the
/// operator-free emergency exit (L1 re-execution) keeps working. Only then may the
/// governance's Security Council replace the verifier without the delay.
contract CanonicalBlockRegistry is IAcceptedBlockRegistry {
    uint256 public constant FORCE_DELAY = 1 days;

    struct Config {
        bytes32 rollupId;
        bytes32 profileHash;
        IStateTransitionVerifier verifier;
        AnchorRegistry anchors;
        IL1MessageQueue messages;
        address governance;
        bool blobDA;
    }

    bytes32 public immutable rollupId;
    bytes32 public immutable profileHash;
    bytes32 public immutable genesisHash;
    AnchorRegistry public immutable anchors;
    IL1MessageQueue public immutable messages;
    address public immutable governance;
    bool public immutable blobDA;

    IStateTransitionVerifier public verifier;
    bool public frozen;
    bytes32 public head;
    uint256 public messageCursor;
    mapping(bytes32 blockHash => AcceptedBlock) internal blocks;

    event BlockAccepted(bytes32 indexed blockHash, uint64 number, bytes32 daCommitment, address submitter);
    event Frozen(bytes32 parentStateRoot, bytes32 blockA, bytes32 blockB);
    event VerifierReplaced(address verifier, bool emergency);

    error Rejected(string why);

    constructor(Config memory cfg, bytes memory genesisHeader) {
        rollupId = cfg.rollupId;
        profileHash = cfg.profileHash;
        verifier = cfg.verifier;
        anchors = cfg.anchors;
        messages = cfg.messages;
        governance = cfg.governance;
        blobDA = cfg.blobDA;
        EthTypes.HeaderFields memory g = EthTypes.decodeHeader(genesisHeader);
        if (g.number != 0) revert Rejected("genesis number");
        genesisHash = g.hash;
        head = g.hash;
        blocks[g.hash] = AcceptedBlock(g.parentHash, g.stateRoot, g.receiptsRoot, 0, cfg.profileHash, 0, true);
    }

    function profileKind() external view returns (uint8) {
        return verifier.profileKind();
    }

    /// @param newMessageCursor how many queue messages (in total) the chain has consumed after this block.
    function submit(bytes calldata rawHeader, bytes32 l1AnchorId, uint256 newMessageCursor, bytes calldata proof)
        external
        returns (bytes32)
    {
        if (frozen) revert Rejected("frozen");
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(rawHeader);
        AcceptedBlock memory parent = blocks[h.parentHash];
        if (h.parentHash != head) revert Rejected("not on the canonical tip");
        if (h.number != uint256(parent.blockNumber) + 1) revert Rejected("number");
        if (l1AnchorId != 0 && !anchors.recorded(l1AnchorId)) revert Rejected("L1 anchor not recorded");
        bytes32 da = blobDA ? blobhash(0) : keccak256(proof);
        if (da == 0) revert Rejected("no blob: data not on L1");
        uint256 cursor = messageCursor;
        if (newMessageCursor < cursor) revert Rejected("message cursor");
        if (messages.overdue(newMessageCursor, FORCE_DELAY)) revert Rejected("overdue L1 message not included");
        IStateTransitionVerifier.Transition memory t = IStateTransitionVerifier.Transition({
            profileHash: profileHash,
            parentStateRoot: parent.stateRoot,
            daCommitment: da,
            l1AnchorId: l1AnchorId,
            l1MessagesRoot: messages.messagesRoot(cursor, newMessageCursor - cursor), // reverts past the queue
            rawHeader: rawHeader
        });
        if (!verifier.verify(t, proof)) revert Rejected("transition not verified");
        blocks[h.hash] =
            AcceptedBlock(h.parentHash, h.stateRoot, h.receiptsRoot, l1AnchorId, profileHash, uint64(h.number), true);
        head = h.hash;
        messageCursor = newMessageCursor;
        emit BlockAccepted(h.hash, uint64(h.number), da, msg.sender);
        return h.hash;
    }

    // ---- faults and governance -------------------------------------------------------------

    /// @notice Anyone: two verifier-accepted transitions with identical inputs (parent state,
    ///         data, anchor, L1 messages, profile) but different results prove the verifier
    ///         unsound. Freezes the registry.
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

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ChannelTypes} from "./libraries/ChannelTypes.sol";
import {MerklePatricia} from "./libraries/MerklePatricia.sol";
import {EthTypes} from "./libraries/EthTypes.sol";
import {RLP} from "./libraries/RLP.sol";
import {IAcceptedBlockRegistry} from "./interfaces/IAcceptedBlockRegistry.sol";
import {AnchorRegistry} from "./AnchorRegistry.sol";
import {WitnessLib} from "./libraries/WitnessLib.sol";
import {IChannelModule} from "./interfaces/IChannelModule.sol";

/// @notice L1: escrow and settlement for cooperative execution channels (PROJECT.md §7.4, §8).
///
/// Lifecycle: open → fund (each participant, exact deposit) → Open → settle (verified L2
/// receipt, before the deadline) or refund (at/after the deadline, anyone may call). Exactly
/// one terminal transition; payouts are pulled with withdraw().
///
/// Settlement checks, in order: channel open and not expired; the registry enforces the same
/// profile kind this contract was deployed for (a mock registry can't serve a native
/// deployment); the L2 block is accepted with this execution profile; the raw header hashes
/// to it and carries the accepted receipts root; the receipt is included at its index and
/// succeeded; the log is the executor's ChannelOutcome for this channel and this exact signed
/// request; the request binds this channel's terms, policy and profile and an L1-recorded
/// anchor; the outcome hashes to the logged value and conserves the escrow.
///
/// Emergency exit (docs/STAGE2.md), when the sequencer or prover is unavailable:
/// startExit posts an all-signed request; during `challengeWindow` anyone may replace it with
/// an all-signed request of a higher nonce (stale-state protection); finalizeExit then runs
/// the approved module ON L1 with a witness verified against the request's L1-recorded anchor,
/// so the outcome's validity needs neither the operator nor the L2. A channel's outcome is a
/// pure function of (request, input, L1 state at the anchor): there is no L2 state to recover.
/// If nobody can finalize (no witness obtainable) within a further window, refund reopens.
///
/// The timeout refund alone returns deposits only: it is not a trustless exit for in-channel
/// gains.
contract ChannelSettlement {
    using RLP for RLP.Item;

    enum Status {
        None,
        Funding,
        Open,
        Exiting,
        Settled,
        Refunded
    }

    struct Channel {
        Status status;
        uint64 deadline;
        bytes32 termsHash;
        bytes32 policyHash;
        address executor;
        uint256 total;
        uint256 fundedMask;
        address[] participants;
        uint256[] deposits;
        bytes32 moduleCodeHash;
        // Emergency exit: the pending request (EIP-712 digest), its nonce, the challenge end.
        bytes32 exitRequestHash;
        uint64 exitNonce;
        uint64 exitDeadline;
    }

    struct Evidence {
        bytes32 l2BlockHash;
        bytes l2Header;
        uint256 txIndex;
        bytes receipt;
        bytes[] receiptProof;
        uint256 logIndex;
        bytes request;
        bytes outcome;
    }

    bytes32 public constant OUTCOME_TOPIC = keccak256("ChannelOutcome(bytes32,bytes32,bytes32,bytes32,bytes32)");

    bytes32 public immutable rollupId;
    bytes32 public immutable profileHash;
    uint8 public immutable profileKind;
    IAcceptedBlockRegistry public immutable blocks;
    AnchorRegistry public immutable anchors;
    uint64 public immutable challengeWindow;
    /// Approved L1 copies of channel modules, by code hash. Written only in the constructor.
    mapping(bytes32 codeHash => address module) public l1Modules;

    mapping(bytes32 channelId => Channel) internal channels;
    mapping(address => uint256) public withdrawable;

    event Opened(bytes32 indexed channelId, bytes32 termsHash);
    event Funded(bytes32 indexed channelId, address participant, uint256 amount);
    event Settled(bytes32 indexed channelId, bytes32 requestHash, bytes32 l2BlockHash);
    event Refunded(bytes32 indexed channelId);
    event ExitStarted(bytes32 indexed channelId, bytes32 requestHash, uint64 nonce, uint64 exitDeadline);
    event ExitFinalized(bytes32 indexed channelId, bytes32 requestHash);

    error Invalid(string what);
    error WrongStatus(Status status);
    error Deadline();
    error TransferFailed();

    constructor(
        bytes32 rollupId_,
        bytes32 profileHash_,
        uint8 profileKind_,
        IAcceptedBlockRegistry blocks_,
        AnchorRegistry anchors_,
        uint64 challengeWindow_,
        address[] memory l1Modules_
    ) {
        rollupId = rollupId_;
        profileHash = profileHash_;
        profileKind = profileKind_;
        blocks = blocks_;
        anchors = anchors_;
        challengeWindow = challengeWindow_;
        for (uint256 i; i < l1Modules_.length; ++i) {
            l1Modules[l1Modules_[i].codehash] = l1Modules_[i];
        }
    }

    function channel(bytes32 channelId) external view returns (Channel memory) {
        return channels[channelId];
    }

    function open(bytes calldata terms, address[] calldata participants, uint256[] calldata deposits, bytes32 salt)
        external
        returns (bytes32 channelId)
    {
        ChannelTypes.ChannelTerms memory t = ChannelTypes.decodeTerms(terms);
        channelId = ChannelTypes.channelId(block.chainid, address(this), msg.sender, salt);
        if (t.channelId != channelId) revert Invalid("channel id");
        if (channels[channelId].status != Status.None) revert WrongStatus(channels[channelId].status);
        if (t.settlementContract != address(this)) revert Invalid("settlement");
        if (t.rollupId != rollupId) revert Invalid("rollup");
        if (t.closeDeadline <= block.timestamp) revert Invalid("deadline");
        if (ChannelTypes.participantRoot(participants) != t.participantRoot) revert Invalid("participants");
        if (deposits.length != participants.length || participants.length > 16) revert Invalid("deposits");
        uint256 total;
        for (uint256 i; i < deposits.length; ++i) {
            if (deposits[i] == 0) revert Invalid("deposit");
            total += deposits[i];
        }
        Channel storage c = channels[channelId];
        c.status = Status.Funding;
        c.deadline = t.closeDeadline;
        c.termsHash = ChannelTypes.termsHash(t);
        c.policyHash = t.policyHash;
        c.executor = t.executor;
        c.total = total;
        c.participants = participants;
        c.deposits = deposits;
        c.moduleCodeHash = t.moduleCodeHash;
        emit Opened(channelId, c.termsHash);
    }

    function fund(bytes32 channelId) external payable {
        Channel storage c = channels[channelId];
        if (c.status != Status.Funding) revert WrongStatus(c.status);
        if (block.timestamp >= c.deadline) revert Deadline();
        uint256 i = _index(c, msg.sender);
        if (c.fundedMask & (1 << i) != 0) revert Invalid("already funded");
        if (msg.value != c.deposits[i]) revert Invalid("amount");
        c.fundedMask |= 1 << i;
        if (c.fundedMask == (1 << c.participants.length) - 1) c.status = Status.Open;
        emit Funded(channelId, msg.sender, msg.value);
    }

    function settle(bytes32 channelId, bytes calldata evidence) external {
        Channel storage c = channels[channelId];
        if (c.status != Status.Open && c.status != Status.Exiting) revert WrongStatus(c.status);
        if (c.status == Status.Open && block.timestamp >= c.deadline) revert Deadline();
        Evidence memory e = abi.decode(evidence, (Evidence));

        // 1. The L2 block: accepted under this deployment's profile.
        if (blocks.profileKind() != profileKind) revert Invalid("registry profile kind");
        IAcceptedBlockRegistry.AcceptedBlock memory b = blocks.acceptedBlock(rollupId, e.l2BlockHash);
        if (!b.accepted) revert Invalid("block not accepted");
        if (b.executionProfileHash != profileHash) revert Invalid("block profile");
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(e.l2Header);
        if (h.hash != e.l2BlockHash || h.receiptsRoot != b.receiptsRoot) revert Invalid("header");

        // 2. The receipt: included, successful.
        (bool found, bytes memory leaf) =
            MerklePatricia.get(h.receiptsRoot, MerklePatricia.indexKey(e.txIndex), e.receiptProof);
        if (!found || keccak256(leaf) != keccak256(e.receipt)) revert Invalid("receipt proof");
        (, bool success, RLP.Item[] memory logs) = EthTypes.decodeReceipt(e.receipt);
        if (!success) revert Invalid("receipt status");
        if (e.logIndex >= logs.length) revert Invalid("log index");
        EthTypes.Log memory log = EthTypes.decodeLog(logs[e.logIndex]);

        // 3. The log: this channel's outcome, from its executor, for this signed request.
        ChannelTypes.FinalRequest memory r = ChannelTypes.decodeFinalRequest(e.request);
        bytes32 requestHash = ChannelTypes.requestSigningHash(r, block.chainid, address(this));
        if (log.emitter != c.executor) revert Invalid("emitter");
        if (log.topics.length != 3 || log.topics[0] != OUTCOME_TOPIC) revert Invalid("event");
        if (log.topics[1] != channelId || log.topics[2] != requestHash) revert Invalid("log binding");
        if (keccak256(log.data) != keccak256(abi.encode(r.anchorId, r.policyHash, keccak256(e.outcome)))) {
            revert Invalid("log data");
        }

        // 4. The request: this channel's terms, policy and profile; an anchor L1 vouches for.
        if (r.channelId != channelId || r.termsHash != c.termsHash) revert Invalid("request");
        if (r.policyHash != c.policyHash || r.executionProfileHash != profileHash) revert Invalid("request policy");
        if (!anchors.recorded(r.anchorId)) revert Invalid("anchor not recorded on L1");
        // During an emergency exit, only the pending (highest-nonce) request may settle.
        if (c.status == Status.Exiting && requestHash != c.exitRequestHash) {
            revert Invalid("not the pending exit request");
        }

        // 5. The outcome: one payout per participant, conserving the escrow.
        _payout(c, e.outcome);
        emit Settled(channelId, requestHash, e.l2BlockHash);
    }

    // ---- emergency exit ------------------------------------------------------------------

    /// @notice Posts an all-signed request for this channel. Anyone may call (signatures carry
    ///         the authority); the challenge window starts.
    function startExit(bytes32 channelId, bytes calldata request, bytes[] calldata signatures) external {
        Channel storage c = channels[channelId];
        if (c.status != Status.Open) revert WrongStatus(c.status);
        if (block.timestamp >= c.deadline) revert Deadline();
        (bytes32 h, uint64 nonce) = _signedRequest(c, channelId, request, signatures);
        c.status = Status.Exiting;
        c.exitRequestHash = h;
        c.exitNonce = nonce;
        c.exitDeadline = uint64(block.timestamp) + challengeWindow;
        emit ExitStarted(channelId, h, nonce, c.exitDeadline);
    }

    /// @notice Replaces the pending request with a newer one (strictly higher nonce), within
    ///         the window. The window is not extended: whoever holds the newest request must
    ///         post it in time.
    function challengeExit(bytes32 channelId, bytes calldata request, bytes[] calldata signatures) external {
        Channel storage c = channels[channelId];
        if (c.status != Status.Exiting) revert WrongStatus(c.status);
        if (block.timestamp >= c.exitDeadline) revert Deadline();
        (bytes32 h, uint64 nonce) = _signedRequest(c, channelId, request, signatures);
        if (nonce <= c.exitNonce) revert Invalid("not newer");
        c.exitRequestHash = h;
        c.exitNonce = nonce;
        emit ExitStarted(channelId, h, nonce, c.exitDeadline);
    }

    /// @notice After the window: executes the pending request's module on L1 against a witness
    ///         verified at its L1-recorded anchor, and pays out. No L2 involvement.
    function finalizeExit(bytes32 channelId, bytes calldata request, bytes calldata input, bytes calldata witness)
        external
    {
        Channel storage c = channels[channelId];
        if (c.status != Status.Exiting) revert WrongStatus(c.status);
        if (block.timestamp < c.exitDeadline) revert Deadline();
        ChannelTypes.FinalRequest memory r = ChannelTypes.decodeFinalRequest(request);
        bytes32 h = ChannelTypes.requestSigningHash(r, block.chainid, address(this));
        if (h != c.exitRequestHash) revert Invalid("not the pending exit request");
        if (keccak256(input) != r.inputHash) revert Invalid("input");

        WitnessLib.WitnessPackage memory pkg = WitnessLib.decode(witness);
        bytes32 root = anchors.stateRootOf(r.anchorId);
        if (ChannelTypes.anchorId(pkg.anchor) != r.anchorId || root == 0 || pkg.anchor.stateRoot != root) {
            revert Invalid("anchor not recorded on L1");
        }
        WitnessLib.Read[] memory reads = WitnessLib.verify(pkg);
        address module = l1Modules[c.moduleCodeHash];
        if (module == address(0) || module.codehash != c.moduleCodeHash) revert Invalid("module not approved on L1");
        bytes memory outcome = IChannelModule(module).compute(input, reads, c.participants.length);
        _payout(c, outcome);
        emit ExitFinalized(channelId, h);
    }

    function _signedRequest(Channel storage c, bytes32 channelId, bytes calldata request, bytes[] calldata sigs)
        internal
        view
        returns (bytes32 h, uint64 nonce)
    {
        ChannelTypes.FinalRequest memory r = ChannelTypes.decodeFinalRequest(request);
        if (r.channelId != channelId || r.termsHash != c.termsHash) revert Invalid("request");
        if (r.policyHash != c.policyHash || r.executionProfileHash != profileHash) revert Invalid("request policy");
        h = ChannelTypes.requestSigningHash(r, block.chainid, address(this));
        if (sigs.length != c.participants.length) revert Invalid("signature count");
        for (uint256 i; i < sigs.length; ++i) {
            if (ChannelTypes.recoverSigner(h, sigs[i]) != c.participants[i]) revert Invalid("signature");
        }
        nonce = r.nonce;
    }

    /// @dev One payout per participant, conserving the escrow; the terminal transition.
    function _payout(Channel storage c, bytes memory outcome) internal {
        if (outcome.length != 64 + 32 * c.participants.length) revert Invalid("outcome encoding");
        uint256[] memory payouts = abi.decode(outcome, (uint256[]));
        if (payouts.length != c.participants.length) revert Invalid("payout count");
        uint256 sum;
        for (uint256 i; i < payouts.length; ++i) {
            sum += payouts[i];
        }
        if (sum != c.total) revert Invalid("conservation");
        c.status = Status.Settled;
        for (uint256 i; i < payouts.length; ++i) {
            withdrawable[c.participants[i]] += payouts[i];
        }
    }

    /// @notice After the deadline, anyone may return funded deposits; no operator needed.
    ///         During an emergency exit, only once finalization has been possible for a further
    ///         full window without anyone finalizing.
    function refund(bytes32 channelId) external {
        Channel storage c = channels[channelId];
        if (c.status == Status.Exiting) {
            if (block.timestamp < uint256(c.exitDeadline) + challengeWindow) revert Deadline();
        } else {
            if (c.status != Status.Funding && c.status != Status.Open) revert WrongStatus(c.status);
            if (block.timestamp < c.deadline) revert Deadline();
        }
        c.status = Status.Refunded;
        for (uint256 i; i < c.participants.length; ++i) {
            if (c.fundedMask & (1 << i) != 0) withdrawable[c.participants[i]] += c.deposits[i];
        }
        emit Refunded(channelId);
    }

    function withdraw() external {
        uint256 amount = withdrawable[msg.sender];
        withdrawable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _index(Channel storage c, address who) internal view returns (uint256) {
        for (uint256 i; i < c.participants.length; ++i) {
            if (c.participants[i] == who) return i;
        }
        revert Invalid("not a participant");
    }
}

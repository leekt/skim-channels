// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ChannelTypes} from "./libraries/ChannelTypes.sol";
import {MerklePatricia} from "./libraries/MerklePatricia.sol";
import {EthTypes} from "./libraries/EthTypes.sol";
import {RLP} from "./libraries/RLP.sol";
import {IAcceptedBlockRegistry} from "./interfaces/IAcceptedBlockRegistry.sol";
import {AnchorRegistry} from "./AnchorRegistry.sol";

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
/// The timeout refund returns deposits only: it is not a trustless exit for in-channel gains
/// (docs/STAGE2.md).
contract ChannelSettlement {
    using RLP for RLP.Item;

    enum Status {
        None,
        Funding,
        Open,
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

    bytes32 public constant OUTCOME_TOPIC =
        keccak256("ChannelOutcome(bytes32,bytes32,bytes32,bytes32,bytes32)");

    bytes32 public immutable rollupId;
    bytes32 public immutable profileHash;
    uint8 public immutable profileKind;
    IAcceptedBlockRegistry public immutable blocks;
    AnchorRegistry public immutable anchors;

    mapping(bytes32 channelId => Channel) internal channels;
    mapping(address => uint256) public withdrawable;

    event Opened(bytes32 indexed channelId, bytes32 termsHash);
    event Funded(bytes32 indexed channelId, address participant, uint256 amount);
    event Settled(bytes32 indexed channelId, bytes32 requestHash, bytes32 l2BlockHash);
    event Refunded(bytes32 indexed channelId);

    error Invalid(string what);
    error WrongStatus(Status status);
    error Deadline();
    error TransferFailed();

    constructor(
        bytes32 rollupId_,
        bytes32 profileHash_,
        uint8 profileKind_,
        IAcceptedBlockRegistry blocks_,
        AnchorRegistry anchors_
    ) {
        rollupId = rollupId_;
        profileHash = profileHash_;
        profileKind = profileKind_;
        blocks = blocks_;
        anchors = anchors_;
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
        if (c.status != Status.Open) revert WrongStatus(c.status);
        if (block.timestamp >= c.deadline) revert Deadline();
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

        // 5. The outcome: one payout per participant, conserving the escrow.
        if (e.outcome.length != 64 + 32 * c.participants.length) revert Invalid("outcome encoding");
        uint256[] memory payouts = abi.decode(e.outcome, (uint256[]));
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
        emit Settled(channelId, requestHash, e.l2BlockHash);
    }

    /// @notice After the deadline, anyone may return funded deposits; no operator needed.
    function refund(bytes32 channelId) external {
        Channel storage c = channels[channelId];
        if (c.status != Status.Funding && c.status != Status.Open) revert WrongStatus(c.status);
        if (block.timestamp < c.deadline) revert Deadline();
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

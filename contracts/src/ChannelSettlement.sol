// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ChannelTypes} from "./libraries/ChannelTypes.sol";
import {IAcceptedBlockRegistry} from "./interfaces/IAcceptedBlockRegistry.sol";
import {AnchorRegistry} from "./AnchorRegistry.sol";
import {ReceiptVerifier} from "./verifiers/ReceiptVerifier.sol";

/// @notice What settlement needs from the emergency-exit contract.
interface IEmergencyExit {
    function pendingRequest(bytes32 channelId) external view returns (bytes32);
    function refundOpen(bytes32 channelId) external view returns (bool);
}

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
/// Emergency exit (docs/guide/stage-2.md) lives in `EmergencyExit`, bound once at deployment. It may
/// only move an Open channel to Exiting (before the deadline) and pay out an Exiting channel,
/// through `beginExit` / `payoutExit`; conservation is still enforced here. While Exiting,
/// `settle` accepts only the exit's pending request, and `refund` waits until the exit
/// contract says finalization had its full window. (Split from settlement so each contract
/// stays deployable where code is expensive: ~1,600 gas per byte measured on ethrex Amsterdam.)
///
/// The timeout refund alone returns deposits only: it is not a trustless exit for in-channel
/// gains.
contract ChannelSettlement {
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

    bytes32 public immutable rollupId;
    bytes32 public immutable profileHash;
    uint8 public immutable profileKind;
    IAcceptedBlockRegistry public immutable blocks;
    AnchorRegistry public immutable anchors;
    ReceiptVerifier public immutable receiptVerifier;
    address internal immutable deployer;
    /// The emergency-exit contract; bound once, by the deployer.
    IEmergencyExit public exits;

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

    struct Config {
        bytes32 rollupId;
        bytes32 profileHash;
        uint8 profileKind;
        IAcceptedBlockRegistry blocks;
        AnchorRegistry anchors;
        ReceiptVerifier receiptVerifier;
    }

    constructor(Config memory cfg) {
        rollupId = cfg.rollupId;
        profileHash = cfg.profileHash;
        profileKind = cfg.profileKind;
        blocks = cfg.blocks;
        anchors = cfg.anchors;
        receiptVerifier = cfg.receiptVerifier;
        deployer = msg.sender;
    }

    function bindExits(IEmergencyExit e) external {
        if (msg.sender != deployer || address(exits) != address(0)) revert Invalid("bind");
        exits = e;
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
        Evidence memory e = abi.decode(evidence, (Evidence));
        bytes32 rr = _acceptedReceiptsRoot(e.l2BlockHash, e.l2Header);
        _settleOne(
            Item(channelId, e.txIndex, e.receipt, e.receiptProof, e.logIndex, e.request, e.outcome), rr, e.l2BlockHash
        );
    }

    /// @notice One receipt of an L2 block, for `settleFromBlock`.
    struct Item {
        bytes32 channelId;
        uint256 txIndex;
        bytes receipt;
        bytes[] receiptProof;
        uint256 logIndex;
        bytes request;
        bytes outcome;
    }

    /// @notice Settles several channels whose outcomes are in the same L2 block: the block's
    ///         acceptance and header are checked once, then each receipt. All or nothing.
    function settleFromBlock(bytes32 l2BlockHash, bytes calldata l2Header, Item[] calldata items) external {
        bytes32 rr = _acceptedReceiptsRoot(l2BlockHash, l2Header);
        for (uint256 i; i < items.length; ++i) {
            _settleOne(items[i], rr, l2BlockHash);
        }
    }

    /// @dev The L2 block: accepted under this deployment's profile; the header hashes to it and
    ///      carries the accepted receipts root.
    function _acceptedReceiptsRoot(bytes32 l2BlockHash, bytes memory l2Header) internal view returns (bytes32 rr) {
        if (blocks.profileKind() != profileKind) revert Invalid("registry profile kind");
        IAcceptedBlockRegistry.AcceptedBlock memory b = blocks.acceptedBlock(rollupId, l2BlockHash);
        if (!b.accepted) revert Invalid("block not accepted");
        if (b.executionProfileHash != profileHash) revert Invalid("block profile");
        bytes32 hh;
        (hh, rr) = receiptVerifier.headerRoots(l2Header);
        if (hh != l2BlockHash || rr != b.receiptsRoot) revert Invalid("header");
    }

    function _settleOne(Item memory e, bytes32 rr, bytes32 l2BlockHash) internal {
        Channel storage c = channels[e.channelId];
        if (c.status != Status.Open && c.status != Status.Exiting) revert WrongStatus(c.status);
        if (c.status == Status.Open && block.timestamp >= c.deadline) revert Deadline();

        // The receipt and its log: this channel's outcome, from its executor, for this signed
        // request (stateless checks, in ReceiptVerifier).
        (ChannelTypes.FinalRequest memory r, bytes32 requestHash) = receiptVerifier.outcome(
            rr,
            e.txIndex,
            e.receipt,
            e.receiptProof,
            e.logIndex,
            e.request,
            e.outcome,
            c.executor,
            e.channelId,
            address(this)
        );

        // The request: this channel's terms, policy and profile; an anchor L1 vouches for.
        if (r.channelId != e.channelId || r.termsHash != c.termsHash) revert Invalid("request");
        if (r.policyHash != c.policyHash || r.executionProfileHash != profileHash) revert Invalid("request policy");
        if (!anchors.recorded(r.anchorId)) revert Invalid("anchor not recorded on L1");
        // During an emergency exit, only the pending (highest-nonce) request may settle.
        if (c.status == Status.Exiting && requestHash != exits.pendingRequest(e.channelId)) {
            revert Invalid("not the pending exit request");
        }

        // The outcome: one payout per participant, conserving the escrow.
        _payout(c, e.outcome);
        emit Settled(e.channelId, requestHash, l2BlockHash);
    }

    // ---- emergency-exit hooks ---------------------------------------------------------------

    function beginExit(bytes32 channelId) external {
        if (msg.sender != address(exits)) revert Invalid("not the exit contract");
        Channel storage c = channels[channelId];
        if (c.status != Status.Open) revert WrongStatus(c.status);
        if (block.timestamp >= c.deadline) revert Deadline();
        c.status = Status.Exiting;
    }

    function payoutExit(bytes32 channelId, bytes calldata outcome) external {
        if (msg.sender != address(exits)) revert Invalid("not the exit contract");
        Channel storage c = channels[channelId];
        if (c.status != Status.Exiting) revert WrongStatus(c.status);
        _payout(c, outcome);
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
            if (!exits.refundOpen(channelId)) revert Deadline();
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

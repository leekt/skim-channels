// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ChannelTypes} from "./libraries/ChannelTypes.sol";
import {WitnessLib} from "./libraries/WitnessLib.sol";
import {WitnessVerifier} from "./verifiers/WitnessVerifier.sol";
import {IChannelModule} from "./interfaces/IChannelModule.sol";
import {AnchorRegistry} from "./AnchorRegistry.sol";
import {ChannelSettlement} from "./ChannelSettlement.sol";

/// @notice L1: the operator-free exit (docs/guide/stage-2.md), for when the sequencer or prover is
///         unavailable.
///         - startExit posts an all-signed request for an Open channel (before its deadline).
///         - During the channel's challenge window (its ChannelPolicy, clamped to
///           [MIN_WINDOW, MAX_WINDOW]), anyone may replace it with an all-signed request of a
///           strictly higher nonce (stale-state protection). The window is not extended.
///         - finalizeExit then runs the approved module ON L1, with a witness verified against
///           the request's L1-recorded anchor, and pays out through the settlement contract
///           (which enforces conservation). The outcome needs neither the operator nor the L2:
///           a channel's outcome is a pure function of (request, input, L1 state at the anchor).
///         - If nobody finalizes within a further window (e.g. no witness obtainable),
///           settlement's refund reopens.
contract EmergencyExit {
    struct Pending {
        bytes32 requestHash;
        uint64 nonce;
        uint64 deadline;
        uint64 window;
    }

    ChannelSettlement public immutable settlement;
    AnchorRegistry public immutable anchors;
    WitnessVerifier public immutable witnessVerifier;
    uint64 public constant MIN_WINDOW = 1 hours;
    uint64 public constant MAX_WINDOW = 30 days;
    bytes32 public immutable profileHash;
    /// Approved L1 copies of channel modules, by code hash. Written only in the constructor.
    mapping(bytes32 codeHash => address module) public l1Modules;
    mapping(bytes32 channelId => Pending) public pending;

    event ExitStarted(bytes32 indexed channelId, bytes32 requestHash, uint64 nonce, uint64 exitDeadline);
    event ExitFinalized(bytes32 indexed channelId, bytes32 requestHash);

    // Same signatures as ChannelSettlement's errors.
    error Invalid(string what);
    error WrongStatus(ChannelSettlement.Status status);
    error Deadline();

    constructor(ChannelSettlement settlement_, WitnessVerifier witnessVerifier_, address[] memory l1Modules_) {
        settlement = settlement_;
        anchors = settlement_.anchors();
        profileHash = settlement_.profileHash();
        witnessVerifier = witnessVerifier_;
        for (uint256 i; i < l1Modules_.length; ++i) {
            l1Modules[l1Modules_[i].codehash] = l1Modules_[i];
        }
    }

    function pendingRequest(bytes32 channelId) external view returns (bytes32) {
        return pending[channelId].requestHash;
    }

    function refundOpen(bytes32 channelId) external view returns (bool) {
        Pending memory p = pending[channelId];
        return block.timestamp >= uint256(p.deadline) + p.window;
    }

    /// @notice Anyone may call: the signatures carry the authority.
    /// @notice Anyone may call: the signatures carry the authority. `policy` is the channel's
    ///         ChannelPolicy (abi-encoded); its challenge window applies, clamped.
    function startExit(bytes32 channelId, bytes calldata request, bytes[] calldata signatures, bytes calldata policy)
        external
    {
        ChannelSettlement.Channel memory c = settlement.channel(channelId);
        if (policy.length != 96) revert Invalid("policy encoding");
        ChannelTypes.ChannelPolicy memory pol = abi.decode(policy, (ChannelTypes.ChannelPolicy));
        if (ChannelTypes.policyHash(pol) != c.policyHash) revert Invalid("policy");
        uint64 window = pol.challengeWindow < MIN_WINDOW
            ? MIN_WINDOW
            : (pol.challengeWindow > MAX_WINDOW ? MAX_WINDOW : pol.challengeWindow);
        (bytes32 h, uint64 nonce) = _signedRequest(c, channelId, request, signatures);
        settlement.beginExit(channelId); // Open and before the deadline, or reverts
        uint64 deadline = uint64(block.timestamp) + window;
        pending[channelId] = Pending(h, nonce, deadline, window);
        emit ExitStarted(channelId, h, nonce, deadline);
    }

    function challengeExit(bytes32 channelId, bytes calldata request, bytes[] calldata signatures) external {
        ChannelSettlement.Channel memory c = settlement.channel(channelId);
        if (c.status != ChannelSettlement.Status.Exiting) revert WrongStatus(c.status);
        Pending storage p = pending[channelId];
        if (block.timestamp >= p.deadline) revert Deadline();
        (bytes32 h, uint64 nonce) = _signedRequest(c, channelId, request, signatures);
        if (nonce <= p.nonce) revert Invalid("not newer");
        p.requestHash = h;
        p.nonce = nonce;
        emit ExitStarted(channelId, h, nonce, p.deadline);
    }

    function finalizeExit(bytes32 channelId, bytes calldata request, bytes calldata input, bytes calldata witness)
        external
    {
        ChannelSettlement.Channel memory c = settlement.channel(channelId);
        if (c.status != ChannelSettlement.Status.Exiting) revert WrongStatus(c.status);
        Pending memory p = pending[channelId];
        if (block.timestamp < p.deadline) revert Deadline();
        ChannelTypes.FinalRequest memory r = ChannelTypes.decodeFinalRequest(request);
        bytes32 h = ChannelTypes.requestSigningHash(r, block.chainid, address(settlement));
        if (h != p.requestHash) revert Invalid("not the pending exit request");
        if (keccak256(input) != r.inputHash) revert Invalid("input");

        (ChannelTypes.L1Anchor memory anchor, WitnessLib.Read[] memory reads) = witnessVerifier.verify(witness);
        bytes32 root = anchors.stateRootOf(r.anchorId);
        if (ChannelTypes.anchorId(anchor) != r.anchorId || root == 0 || anchor.stateRoot != root) {
            revert Invalid("anchor not recorded on L1");
        }
        address module = l1Modules[c.moduleCodeHash];
        if (module == address(0) || module.codehash != c.moduleCodeHash) revert Invalid("module not approved on L1");
        settlement.payoutExit(channelId, IChannelModule(module).compute(input, reads, c.participants.length));
        emit ExitFinalized(channelId, h);
    }

    function _signedRequest(
        ChannelSettlement.Channel memory c,
        bytes32 channelId,
        bytes calldata request,
        bytes[] calldata sigs
    ) internal view returns (bytes32 h, uint64 nonce) {
        ChannelTypes.FinalRequest memory r = ChannelTypes.decodeFinalRequest(request);
        if (r.channelId != channelId || r.termsHash != c.termsHash) revert Invalid("request");
        if (r.policyHash != c.policyHash || r.executionProfileHash != profileHash) revert Invalid("request policy");
        h = ChannelTypes.requestSigningHash(r, block.chainid, address(settlement));
        if (sigs.length != c.participants.length) revert Invalid("signature count");
        for (uint256 i; i < sigs.length; ++i) {
            if (ChannelTypes.recoverSigner(h, sigs[i]) != c.participants[i]) revert Invalid("signature");
        }
        nonce = r.nonce;
    }
}

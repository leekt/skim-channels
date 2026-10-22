// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ChannelTypes} from "./libraries/ChannelTypes.sol";
import {WitnessLib} from "./libraries/WitnessLib.sol";
import {IChannelModule} from "./interfaces/IChannelModule.sol";
import {L2AnchorInbox} from "./L2AnchorInbox.sol";

/// @notice L2: stateless channel execution (PROJECT.md §5.3, §5.4).
///         - Binds terms, policy, request, input, executor, module and execution profile.
///         - Verifies every participant's signature over the EIP-712 request digest.
///         - Verifies the L1 witness package against an anchor the inbox holds.
///         - Runs the approved immutable module with STATICCALL (no writes possible) and emits
///           the authenticated outcome. The executor has no mutable storage: everything it
///           holds is fixed at construction.
contract ChannelExecutor {
    event ChannelOutcome(
        bytes32 indexed channelId,
        bytes32 indexed requestHash,
        bytes32 anchorId,
        bytes32 policyHash,
        bytes32 outcomeHash
    );

    bytes32 public immutable profileHash;
    uint256 public immutable l1ChainId;
    L2AnchorInbox public immutable inbox;
    /// Approved modules by code hash. Written only in the constructor.
    mapping(bytes32 codeHash => address module) public modules;

    error WrongExecutor();
    error Mismatch(string what);
    error UnapprovedModule(bytes32 codeHash);
    error BadSignature(uint256 index);
    error UnknownAnchor(bytes32 anchorId);
    error AnchorTooOld(uint64 anchor, uint64 latest);

    constructor(bytes32 profileHash_, uint256 l1ChainId_, L2AnchorInbox inbox_, address[] memory modules_) {
        profileHash = profileHash_;
        l1ChainId = l1ChainId_;
        inbox = inbox_;
        for (uint256 i; i < modules_.length; ++i) {
            modules[modules_[i].codehash] = modules_[i];
        }
    }

    struct Call {
        bytes terms;
        bytes policy;
        bytes request;
        bytes input;
        bytes witness;
        address[] participants;
        bytes[] signatures;
    }

    function execute(Call calldata c) external returns (bytes memory outcome) {
        bytes32 requestHash;
        ChannelTypes.FinalRequest memory r;
        (outcome, requestHash, r) = _run(c);
        emit ChannelOutcome(r.channelId, requestHash, r.anchorId, r.policyHash, keccak256(outcome));
    }

    /// @notice The same computation without emitting: a preview (eth_call).
    function preview(Call calldata c) external view returns (bytes memory outcome) {
        (outcome,,) = _run(c);
    }

    function _run(Call calldata c)
        internal
        view
        returns (bytes memory outcome, bytes32 requestHash, ChannelTypes.FinalRequest memory r)
    {
        ChannelTypes.ChannelTerms memory t = ChannelTypes.decodeTerms(c.terms);
        r = ChannelTypes.decodeFinalRequest(c.request);
        if (c.policy.length != 64) revert Mismatch("policy encoding");
        ChannelTypes.ChannelPolicy memory p = abi.decode(c.policy, (ChannelTypes.ChannelPolicy));

        if (t.executor != address(this)) revert WrongExecutor();
        if (r.channelId != t.channelId) revert Mismatch("channel");
        if (r.termsHash != ChannelTypes.termsHash(t)) revert Mismatch("terms");
        if (ChannelTypes.policyHash(p) != t.policyHash || r.policyHash != t.policyHash) revert Mismatch("policy");
        if (r.executionProfileHash != profileHash) revert Mismatch("profile");
        if (keccak256(c.input) != r.inputHash) revert Mismatch("input");

        address module = modules[t.moduleCodeHash];
        if (module == address(0) || module.codehash != t.moduleCodeHash) revert UnapprovedModule(t.moduleCodeHash);

        if (ChannelTypes.participantRoot(c.participants) != t.participantRoot) revert Mismatch("participants");
        if (c.signatures.length != c.participants.length) revert Mismatch("signature count");
        requestHash = ChannelTypes.requestSigningHash(r, l1ChainId, t.settlementContract);
        for (uint256 i; i < c.participants.length; ++i) {
            if (_recover(requestHash, c.signatures[i]) != c.participants[i]) revert BadSignature(i);
        }

        WitnessLib.WitnessPackage memory pkg = WitnessLib.decode(c.witness);
        if (ChannelTypes.anchorId(pkg.anchor) != r.anchorId) revert Mismatch("anchor");
        if (pkg.anchor.chainId != l1ChainId) revert Mismatch("anchor chain");
        if (inbox.stateRootOf(r.anchorId) != pkg.anchor.stateRoot) revert UnknownAnchor(r.anchorId);
        uint64 latest = inbox.latestNumber();
        if (latest - pkg.anchor.blockNumber > p.maxAnchorLag) revert AnchorTooOld(pkg.anchor.blockNumber, latest);
        WitnessLib.Read[] memory reads = WitnessLib.verify(pkg);

        // `view` interface: compiled to STATICCALL, so the module cannot write anything.
        outcome = IChannelModule(module).compute(c.input, reads, c.participants.length);
    }

    /// @dev 65-byte (r, s, v) signatures, low-s only (EIP-2).
    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 rr = bytes32(sig[0:32]);
        bytes32 ss = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (uint256(ss) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, rr, ss);
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IStateTransitionVerifier} from "../interfaces/IStateTransitionVerifier.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

/// @notice Where an EIP-8288 dependency verdict comes from. Under EIP-8288 it is the protocol
///         itself: the current transaction's DEP_VERIFY frame declares (scheme, data_hash,
///         vk_hash) and the block's aggregated proof covers it; a contract reads the declared
///         triples with EIP-8141 frame introspection (FRAMEPARAM / FRAMEDATACOPY).
interface IDependencySource {
    function verified(uint8 scheme, bytes32 dataHash, bytes32 vkHash) external view returns (bool);
}

/// @notice Profile native-proof-dependencies (PROJECT.md §6.3): a transition is accepted if a
///         proof dependency with the EVM verification key from the EIP-8357 registry attests
///         to exactly this transition's public input.
///
///         NOT DEPLOYABLE TODAY, and not a security claim (docs/STAGE2.md, evidence there):
///         EIP-8288 is a draft whose reference implementation is "TBD", its STARK scheme is
///         reserved ("a frame that uses it is invalid until get_deps_hash is defined"), the
///         only devnet (L2BEAT's) registers a placeholder key for mock proofs, and the public
///         bogota devnet has no code at the registry address. This contract fixes the binding
///         (registry call convention, public input) so the profile can be wired behind
///         RollupGovernance's 30-day path once a real dependency source exists.
contract ProofDependencyVerifier is IStateTransitionVerifier {
    /// EIP-8357 registry address.
    address public constant VK_REGISTRY = 0x00005e9c1447C1A05A642ec9eB76D9C125468357;
    /// EIP-8288 reserved STARK scheme id.
    uint8 public constant LEANSTARK_SCHEME = 0x11;

    IDependencySource public immutable source;
    /// The EIP-8357 schema the rollup's program uses (part of the execution profile).
    uint16 public immutable schemaId;

    constructor(IDependencySource source_, uint16 schemaId_) {
        source = source_;
        schemaId = schemaId_;
    }

    function profileKind() external pure returns (uint8) {
        return ChannelTypes.PROFILE_NATIVE_PROOF_DEPENDENCIES;
    }

    /// @notice The public input a proof of this transition must commit to.
    function publicInput(Transition calldata t) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                t.profileHash, t.parentStateRoot, t.daCommitment, t.l1AnchorId, t.l1MessagesRoot, keccak256(t.rawHeader)
            )
        );
    }

    /// @notice The registry's current entry (EIP-8357: 32 zero bytes of calldata → 64 bytes
    ///         `vk_hash || schema_id`; reverts if none).
    function currentVk() public view returns (bytes32 vkHash, uint16 schema) {
        (bool ok, bytes memory r) = VK_REGISTRY.staticcall(new bytes(32));
        if (!ok || r.length != 64) return (0, 0);
        (vkHash, schema) = (bytes32(r), uint16(uint256(abi.decode(_slice32(r), (bytes32)))));
    }

    function verify(Transition calldata t, bytes calldata) external view returns (bool) {
        (bytes32 vk, uint16 schema) = currentVk();
        if (vk == 0 || schema != schemaId) return false;
        return source.verified(LEANSTARK_SCHEME, publicInput(t), vk);
    }

    function _slice32(bytes memory r) private pure returns (bytes memory out) {
        out = new bytes(32);
        for (uint256 i; i < 32; ++i) {
            out[i] = r[32 + i];
        }
    }
}

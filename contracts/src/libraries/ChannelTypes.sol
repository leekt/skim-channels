// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice Shared channel types and commitments. Must match crates/channel-types exactly;
///         checked against fixtures/encodings/commitments.json by test/Encodings.t.sol.
library ChannelTypes {
    struct L1Anchor {
        uint256 chainId;
        uint64 blockNumber;
        bytes32 blockHash;
        bytes32 stateRoot;
    }

    struct ChannelTerms {
        bytes32 channelId;
        bytes32 rollupId;
        address settlementContract;
        address executor;
        bytes32 moduleCodeHash;
        bytes32 participantRoot;
        bytes32 policyHash;
        uint64 closeDeadline;
    }

    struct ChannelPolicy {
        uint8 anchorConfirmation;
        uint32 maxAnchorLag;
    }

    struct FinalRequest {
        bytes32 channelId;
        bytes32 termsHash;
        bytes32 anchorId;
        bytes32 policyHash;
        bytes32 executionProfileHash;
        bytes32 inputHash;
        uint64 nonce;
    }

    struct ExecutionProfile {
        bytes32 rollupId;
        uint8 kind;
        bytes32 genesisHash;
        bytes32 programHash;
        bytes32 forkSchemaHash;
        bytes32 daSchemaHash;
        bytes32 executorCodeHash;
    }

    uint8 internal constant PROFILE_MOCK_LOCAL = 0;
    uint8 internal constant PROFILE_NATIVE_REEXECUTION_DEVNET = 1;
    uint8 internal constant PROFILE_NATIVE_PROOF_DEPENDENCIES = 2;
    uint8 internal constant CONFIRMATION_FCR = 3;

    bytes32 internal constant L1_ANCHOR_TYPEHASH =
        keccak256("L1Anchor(uint256 chainId,uint64 blockNumber,bytes32 blockHash,bytes32 stateRoot)");
    bytes32 internal constant CHANNEL_TERMS_TYPEHASH = keccak256(
        "ChannelTerms(bytes32 channelId,bytes32 rollupId,address settlementContract,address executor,bytes32 moduleCodeHash,bytes32 participantRoot,bytes32 policyHash,uint64 closeDeadline)"
    );
    bytes32 internal constant CHANNEL_POLICY_TYPEHASH =
        keccak256("ChannelPolicy(uint8 anchorConfirmation,uint32 maxAnchorLag)");
    bytes32 internal constant FINAL_REQUEST_TYPEHASH = keccak256(
        "FinalRequest(bytes32 channelId,bytes32 termsHash,bytes32 anchorId,bytes32 policyHash,bytes32 executionProfileHash,bytes32 inputHash,uint64 nonce)"
    );
    bytes32 internal constant EXECUTION_PROFILE_TYPEHASH = keccak256(
        "ExecutionProfile(bytes32 rollupId,uint8 kind,bytes32 genesisHash,bytes32 programHash,bytes32 forkSchemaHash,bytes32 daSchemaHash,bytes32 executorCodeHash)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant CHANNEL_ID_TAG = keccak256("skim-channels/channel-id/v0");

    error NonCanonicalEncoding();
    error UnknownProfileKind(uint8 kind);
    error BadParticipants();

    function anchorId(L1Anchor memory a) internal pure returns (bytes32) {
        return keccak256(abi.encode(L1_ANCHOR_TYPEHASH, a.chainId, a.blockNumber, a.blockHash, a.stateRoot));
    }

    function termsHash(ChannelTerms memory t) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CHANNEL_TERMS_TYPEHASH,
                t.channelId,
                t.rollupId,
                t.settlementContract,
                t.executor,
                t.moduleCodeHash,
                t.participantRoot,
                t.policyHash,
                t.closeDeadline
            )
        );
    }

    function policyHash(ChannelPolicy memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(CHANNEL_POLICY_TYPEHASH, p.anchorConfirmation, p.maxAnchorLag));
    }

    function profileHash(ExecutionProfile memory p) internal pure returns (bytes32) {
        if (p.kind > PROFILE_NATIVE_PROOF_DEPENDENCIES) revert UnknownProfileKind(p.kind);
        return keccak256(
            abi.encode(
                EXECUTION_PROFILE_TYPEHASH,
                p.rollupId,
                p.kind,
                p.genesisHash,
                p.programHash,
                p.forkSchemaHash,
                p.daSchemaHash,
                p.executorCodeHash
            )
        );
    }

    function requestStructHash(FinalRequest memory r) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FINAL_REQUEST_TYPEHASH,
                r.channelId,
                r.termsHash,
                r.anchorId,
                r.policyHash,
                r.executionProfileHash,
                r.inputHash,
                r.nonce
            )
        );
    }

    function domainSeparator(uint256 chainId, address settlement) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("SkimChannels"), keccak256("0"), chainId, settlement));
    }

    /// @notice The digest every participant signs.
    function requestSigningHash(FinalRequest memory r, uint256 chainId, address settlement)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(chainId, settlement), requestStructHash(r)));
    }

    function channelId(uint256 chainId, address settlement, address opener, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(CHANNEL_ID_TAG, chainId, settlement, opener, salt));
    }

    /// @notice Participants must be non-empty, nonzero and strictly ascending.
    function participantRoot(address[] memory participants) internal pure returns (bytes32) {
        if (participants.length == 0) revert BadParticipants();
        for (uint256 i; i < participants.length; ++i) {
            if (participants[i] == address(0)) revert BadParticipants();
            if (i > 0 && participants[i - 1] >= participants[i]) revert BadParticipants();
        }
        return keccak256(abi.encode(participants));
    }

    /// @notice Signer of a 65-byte (r, s, v) signature; zero for malformed or high-s (EIP-2).
    function recoverSigner(bytes32 digest, bytes memory sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }

    /// @notice Strict decoding: exact length (no trailing bytes); the ABI decoder rejects
    ///         dirty padding of narrow types.
    function decodeFinalRequest(bytes memory data) internal pure returns (FinalRequest memory r) {
        if (data.length != 7 * 32) revert NonCanonicalEncoding();
        r = abi.decode(data, (FinalRequest));
    }

    function decodeTerms(bytes memory data) internal pure returns (ChannelTerms memory t) {
        if (data.length != 8 * 32) revert NonCanonicalEncoding();
        t = abi.decode(data, (ChannelTerms));
    }
}

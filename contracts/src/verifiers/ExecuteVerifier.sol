// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IStateTransitionVerifier} from "../interfaces/IStateTransitionVerifier.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";
import {EthTypes} from "../libraries/EthTypes.sol";

/// @notice Native execution verification (profile native-reexecution-devnet): the proof is an
///         SSZ `StatelessInput` that L1 itself re-executes with the EIP-8079-style EXECUTE
///         precompile (ethrex PR #6418, address 0x0101, schema 0x1501 = Amsterdam rev 1).
///         Layout constants mirror ethrex's NativeRollup.sol and its pinned offset tests.
///
///         Accepts a transition only if EXECUTE validates the payload, and the validated payload
///         is exactly this block: block hash = keccak256(rawHeader), and the header's parent,
///         number and state root equal the payload's; the payload's gas limit and chain id are
///         this rollup's; its `parent_beacon_block_root` (ethrex's L1-messages root) equals the
///         registry's root for the messages consumed; and the DA commitment is this calldata.
///         Parent state: EXECUTE checks the witness against the parent header (whose hash is
///         the payload's parent hash, which the registry pins to its accepted tip).
contract ExecuteVerifier is IStateTransitionVerifier {
    address internal constant EXECUTE = address(0x0101);
    uint16 internal constant SCHEMA_ID = 0x1501;
    uint256 internal constant RESULT_LEN = 43;
    uint256 internal constant PREFIX = 2; // big-endian schema id before the SSZ body
    uint256 internal constant EP_PARENT_HASH = 0;
    uint256 internal constant EP_STATE_ROOT = 52;
    uint256 internal constant EP_BLOCK_NUMBER = 404;
    uint256 internal constant EP_GAS_LIMIT = 412;
    uint256 internal constant EP_BLOCK_HASH = 472;
    uint256 internal constant EP_FIXED_LEN = 540;

    uint64 public immutable l2ChainId;
    uint64 public immutable l2GasLimit;

    constructor(uint64 l2ChainId_, uint64 l2GasLimit_) {
        l2ChainId = l2ChainId_;
        l2GasLimit = l2GasLimit_;
    }

    function profileKind() external pure returns (uint8) {
        return ChannelTypes.PROFILE_NATIVE_REEXECUTION_DEVNET;
    }

    function verify(Transition calldata t, bytes calldata input) external view returns (bool) {
        if (t.daCommitment != keccak256(input)) return false;
        Payload memory p = _decode(input);
        if (p.gasLimit != l2GasLimit || p.l1MessagesRoot != t.l1MessagesRoot) return false;
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(t.rawHeader);
        if (h.hash != p.blockHash || h.parentHash != p.parentHash || h.number != p.number || h.stateRoot != p.stateRoot)
        {
            return false;
        }
        (bool ok, bytes memory r) = EXECUTE.staticcall(input);
        if (!ok || r.length != RESULT_LEN || uint8(r[32]) != 1) return false;
        return _le(r, 33, 8) == l2ChainId && _le(r, 41, 2) == SCHEMA_ID;
    }

    struct Payload {
        bytes32 parentHash;
        bytes32 stateRoot;
        bytes32 blockHash;
        bytes32 l1MessagesRoot;
        uint256 number;
        uint256 gasLimit;
    }

    function _decode(bytes calldata s) internal pure returns (Payload memory p) {
        require(s.length >= PREFIX + 16, "SSZ: short");
        require((uint16(uint8(s[0])) << 8 | uint16(uint8(s[1]))) == SCHEMA_ID, "SSZ: schema");
        uint256 npr = PREFIX + _leCd(s, PREFIX, 4);
        require(s.length >= npr + 44, "SSZ: npr");
        p.l1MessagesRoot = bytes32(s[npr + 8:npr + 40]);
        uint256 ep = npr + _leCd(s, npr, 4);
        require(s.length >= ep + EP_FIXED_LEN, "SSZ: payload");
        p.parentHash = bytes32(s[ep + EP_PARENT_HASH:ep + EP_PARENT_HASH + 32]);
        p.stateRoot = bytes32(s[ep + EP_STATE_ROOT:ep + EP_STATE_ROOT + 32]);
        p.blockHash = bytes32(s[ep + EP_BLOCK_HASH:ep + EP_BLOCK_HASH + 32]);
        p.number = _leCd(s, ep + EP_BLOCK_NUMBER, 8);
        p.gasLimit = _leCd(s, ep + EP_GAS_LIMIT, 8);
    }

    function _leCd(bytes calldata s, uint256 off, uint256 n) internal pure returns (uint256 v) {
        for (uint256 i; i < n; ++i) {
            v |= uint256(uint8(s[off + i])) << (8 * i);
        }
    }

    function _le(bytes memory s, uint256 off, uint256 n) internal pure returns (uint256 v) {
        for (uint256 i; i < n; ++i) {
            v |= uint256(uint8(s[off + i])) << (8 * i);
        }
    }
}

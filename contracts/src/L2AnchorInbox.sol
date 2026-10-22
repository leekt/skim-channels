// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ChannelTypes} from "./libraries/ChannelTypes.sol";
import {EthTypes} from "./libraries/EthTypes.sol";
import {MessageRoot} from "./queues/MessageRoot.sol";

/// @notice L2: the L1 anchors executions may use. Anchors are derived from raw L1 header bytes
///         (hash = keccak256(raw)), so a feed chooses *which* blocks, never their roots, and L1
///         settlement re-authenticates every anchor against L1 itself either way.
///
///         Two feeds:
///         - trustless (`postFromL1`): the header arrived as an L1→L2 message from `l1Sender`
///           (AnchorSender, which forwards only headers whose hash is L1's own BLOCKHASH). The
///           message is proven against the L1-messages root of an L2 block, read from the
///           EIP-4788 beacon-roots contract, where ethrex native rollups put it and EXECUTE
///           verifies it against the L1 queue;
///         - MOCK (`post`): a labeled system key, for chains without that mechanism (anvil).
///           Disabled when `system` is zero.
contract L2AnchorInbox {
    string public constant SECURITY_LABEL =
        "post(): MOCK system-key feed; postFromL1(): trustless via L1 messages. Both re-checked on L1 at settlement";
    address internal constant BEACON_ROOTS = 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02;

    address public immutable system;
    address public immutable l1Sender;
    uint256 public immutable l1ChainId;
    uint64 public latestNumber;
    mapping(bytes32 anchorId => bytes32 stateRoot) public stateRootOf;

    event AnchorPosted(bytes32 indexed anchorId, uint64 blockNumber, bytes32 blockHash, bool trustless);

    error NotSystem();
    error NotProven();

    constructor(address system_, address l1Sender_, uint256 l1ChainId_) {
        system = system_;
        l1Sender = l1Sender_;
        l1ChainId = l1ChainId_;
    }

    function post(bytes calldata rawHeader) external returns (bytes32) {
        if (msg.sender != system) revert NotSystem(); // system 0: disabled (no caller is 0)
        return _post(rawHeader, false);
    }

    /// @notice The L1 message's target call: deliberately a no-op (the bridge doesn't tell
    ///         the target who sent it); the anchor is taken only through `postFromL1`.
    function l1Message(bytes calldata) external {}

    /// @param gasLimit, nonce the L1 message's fields (from ethrex's L1MessageRecorded event)
    /// @param l2Timestamp timestamp of the L2 block that consumed the message
    /// @param proof Merkle proof of the message in that block's L1-messages root
    function postFromL1(
        bytes calldata rawHeader,
        uint256 gasLimit,
        uint256 nonce,
        uint256 l2Timestamp,
        bytes32[] calldata proof
    ) external returns (bytes32) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                l1Sender,
                address(this),
                uint256(0),
                gasLimit,
                keccak256(abi.encodeCall(this.l1Message, (rawHeader))),
                nonce
            )
        );
        (bool ok, bytes memory r) = BEACON_ROOTS.staticcall(abi.encode(l2Timestamp));
        if (!ok || r.length != 32 || bytes32(r) == 0 || !MessageRoot.verify(proof, bytes32(r), messageHash)) {
            revert NotProven();
        }
        return _post(rawHeader, true);
    }

    function _post(bytes calldata rawHeader, bool trustless) internal returns (bytes32 anchorId) {
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(rawHeader);
        ChannelTypes.L1Anchor memory a = ChannelTypes.L1Anchor(l1ChainId, uint64(h.number), h.hash, h.stateRoot);
        anchorId = ChannelTypes.anchorId(a);
        stateRootOf[anchorId] = h.stateRoot;
        if (a.blockNumber > latestNumber) latestNumber = a.blockNumber;
        emit AnchorPosted(anchorId, a.blockNumber, h.hash, trustless);
    }
}

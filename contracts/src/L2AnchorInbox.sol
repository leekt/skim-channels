// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ChannelTypes} from "./libraries/ChannelTypes.sol";
import {EthTypes} from "./libraries/EthTypes.sol";

/// @notice L2: the L1 anchors executions may use.
///         MOCK FEED: in a Native Rollup the protocol delivers L1 block hashes to L2; here a
///         labeled system key posts raw L1 headers. The anchor is derived from the header
///         bytes (hash = keccak256(raw)), so the feed chooses *which* blocks, never their
///         roots. L1 settlement re-authenticates every anchor against L1 itself
///         (AnchorRegistry), so a lying feed cannot get an outcome settled.
contract L2AnchorInbox {
    string public constant SECURITY_LABEL =
        "MOCK FEED: L1 headers posted by a system key, re-checked on L1 at settlement";

    address public immutable system;
    uint256 public immutable l1ChainId;
    uint64 public latestNumber;
    mapping(bytes32 anchorId => bytes32 stateRoot) public stateRootOf;

    event AnchorPosted(bytes32 indexed anchorId, uint64 blockNumber, bytes32 blockHash);

    error NotSystem();

    constructor(address system_, uint256 l1ChainId_) {
        system = system_;
        l1ChainId = l1ChainId_;
    }

    function post(bytes calldata rawHeader) external returns (bytes32 anchorId) {
        if (msg.sender != system) revert NotSystem();
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(rawHeader);
        ChannelTypes.L1Anchor memory a = ChannelTypes.L1Anchor(l1ChainId, uint64(h.number), h.hash, h.stateRoot);
        anchorId = ChannelTypes.anchorId(a);
        stateRootOf[anchorId] = h.stateRoot;
        if (a.blockNumber > latestNumber) latestNumber = a.blockNumber;
        emit AnchorPosted(anchorId, a.blockNumber, h.hash);
    }
}

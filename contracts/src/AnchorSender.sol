// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {AnchorRegistry} from "./AnchorRegistry.sol";

interface INativeRollupSend {
    function sendL1Message(address to, uint256 gasLimit, bytes calldata data) external payable;
}

/// @notice L1: sends an L1 header to the L2 anchor inbox as an L1→L2 message, only after
///         AnchorRegistry authenticated it against L1's own BLOCKHASH / EIP-2935 (and recorded
///         it, so settlement accepts the same anchor). Anyone may call; the message's L1
///         sender (this contract) is what the inbox trusts.
contract AnchorSender {
    INativeRollupSend public immutable native;
    AnchorRegistry public immutable anchors;

    constructor(INativeRollupSend native_, AnchorRegistry anchors_) {
        native = native_;
        anchors = anchors_;
    }

    function send(bytes calldata rawHeader, address inbox, uint256 gasLimit) external returns (bytes32 anchorId) {
        anchorId = anchors.record(rawHeader); // reverts unless canonical on L1
        native.sendL1Message(inbox, gasLimit, abi.encodeWithSignature("l1Message(bytes)", rawHeader));
    }
}

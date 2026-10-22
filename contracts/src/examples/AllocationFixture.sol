// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice L1: the value Read-and-Split reads. `shareBps` is storage slot 0.
contract AllocationFixture {
    uint256 public shareBps;
    address public immutable owner;

    error NotOwner();

    constructor(uint256 shareBps_) {
        shareBps = shareBps_;
        owner = msg.sender;
    }

    function setShareBps(uint256 v) external {
        if (msg.sender != owner) revert NotOwner();
        shareBps = v;
    }
}

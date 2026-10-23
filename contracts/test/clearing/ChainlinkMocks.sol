// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice Chainlink's AccessControlledOffchainAggregator storage layout, for local chains:
///         the latest round id as a uint32 at bit 176 of slot 0x2b, and transmissions[round]
///         at keccak(round, 0x2c) (answer int192, timestamp in the top 64 bits). The same
///         layout ChainlinkAdapter verifies on Sepolia's ETH/USD aggregator.
contract MockOffchainAggregator {
    uint256[43] private __gap; // slots 0 .. 0x2a
    uint256 internal hot; // 0x2b
    mapping(uint32 => uint256) internal transmissions; // 0x2c
    address public immutable owner;
    uint8 public constant decimals = 8;

    constructor(int192 answer) {
        owner = msg.sender;
        _transmit(answer);
    }

    function transmit(int192 answer) external {
        require(msg.sender == owner, "owner");
        _transmit(answer);
    }

    function _transmit(int192 answer) internal {
        uint32 r = uint32(hot >> 176) + 1;
        hot = uint256(r) << 176;
        transmissions[r] = uint256(uint192(answer)) | (block.timestamp << 192);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint32 r = uint32(hot >> 176);
        uint256 t = transmissions[r];
        return (r, int256(int192(uint192(t))), t >> 192, t >> 192, r);
    }
}

/// @notice Chainlink's EACAggregatorProxy layout: owner, pendingOwner, then the current phase
///         in slot 2 (uint16 id, aggregator address), as on Sepolia's ETH/USD proxy.
contract MockFeedProxy {
    struct Phase {
        uint16 id;
        MockOffchainAggregator aggregator;
    }

    address public owner; // 0
    address internal pendingOwner; // 1
    Phase internal currentPhase; // 2

    constructor(MockOffchainAggregator a) {
        owner = msg.sender;
        currentPhase = Phase(1, a);
    }

    /// An upgrade to another aggregator (a session's adapter refuses to follow it).
    function setAggregator(MockOffchainAggregator a) external {
        require(msg.sender == owner, "owner");
        currentPhase = Phase(currentPhase.id + 1, a);
    }

    function aggregator() external view returns (address) {
        return address(currentPhase.aggregator);
    }

    function decimals() external view returns (uint8) {
        return currentPhase.aggregator.decimals();
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint80 r, int256 a, uint256 s, uint256 u,) = currentPhase.aggregator.latestRoundData();
        uint80 id = uint80((uint256(currentPhase.id) << 64) | r);
        return (id, a, s, u, id);
    }
}

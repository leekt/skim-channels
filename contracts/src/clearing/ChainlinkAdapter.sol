// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {AnchorRegistry} from "../AnchorRegistry.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";
import {WitnessLib} from "../libraries/WitnessLib.sol";

/// @notice How a clearing session learns its batch price on L1: from a witness at the batch's
///         anchor, the block the app executor was pinned to.
interface IPriceAdapter {
    /// @return value USD per ETH, 6 decimals
    /// @return anchorBlock the witness's anchor (recorded, of this chain, at most `maxAge` old)
    function price(bytes calldata witness, AnchorRegistry anchors, uint256 maxAge)
        external
        view
        returns (uint256 value, uint64 anchorBlock);
}

/// @notice The price an app read with `latestRoundData()` through one Chainlink proxy, checked
///         on L1 from storage proofs at the anchor. Chainlink-specific and deliberately
///         narrow: it accepts only the implementation and layout it was configured for.
///
/// Verified at the anchor block H (all from the witness, against H's state root):
/// - the proxy's code is the pinned code (so its layout is known), and its current phase
///   (slot 2: uint16 phase id, then the aggregator address) points at the one supported
///   aggregator. An aggregator change at the proxy is refused, not followed;
/// - the aggregator's code is the pinned code (AccessControlledOffchainAggregator layout:
///   slot 0x2b holds the latest round id as a uint32 at bit 176; transmissions[round] at
///   keccak(round, 0x2c) holds the answer as an int192 and its timestamp in the top 64 bits);
/// - round selection: that latest round, which is what `latestRoundData()` returns at H;
/// - freshness, evaluated at H, not when the proposal lands: answered no later than H's
///   header time and at most `maxStaleness` before it; the answer is positive.
contract ChainlinkAdapter is IPriceAdapter {
    bytes32 internal constant PHASE_SLOT = bytes32(uint256(2));
    bytes32 internal constant HOT_SLOT = bytes32(uint256(0x2b));
    uint256 internal constant TRANSMISSIONS_SLOT = 0x2c;

    address public immutable proxy;
    bytes32 public immutable proxyCodeHash;
    address public immutable aggregator;
    bytes32 public immutable aggregatorCodeHash;
    uint8 public immutable decimals;
    uint256 public immutable maxStaleness;

    error BadAnchor();
    error UnsupportedFeed(string what);
    error StalePrice(uint256 updatedAt, uint256 anchorTime);
    error NoAnswer();

    constructor(
        address proxy_,
        bytes32 proxyCodeHash_,
        address aggregator_,
        bytes32 aggregatorCodeHash_,
        uint8 decimals_,
        uint256 maxStaleness_
    ) {
        proxy = proxy_;
        proxyCodeHash = proxyCodeHash_;
        aggregator = aggregator_;
        aggregatorCodeHash = aggregatorCodeHash_;
        decimals = decimals_;
        maxStaleness = maxStaleness_;
    }

    function transmissionSlot(uint32 round) public pure returns (bytes32) {
        return keccak256(abi.encode(uint256(round), TRANSMISSIONS_SLOT));
    }

    function price(bytes calldata witness, AnchorRegistry anchors, uint256 maxAge)
        external
        view
        returns (uint256 value, uint64 anchorBlock)
    {
        WitnessLib.WitnessPackage memory p = WitnessLib.decode(witness);
        WitnessLib.Read[] memory reads = WitnessLib.verify(p);
        ChannelTypes.L1Anchor memory a = p.anchor;
        bytes32 id = ChannelTypes.anchorId(a);
        if (
            a.chainId != block.chainid || a.stateRoot == 0 || anchors.stateRootOf(id) != a.stateRoot
                || block.number > a.blockNumber + maxAge
        ) revert BadAnchor();
        _code(p, proxy, proxyCodeHash, "proxy code");
        _code(p, aggregator, aggregatorCodeHash, "aggregator code");
        if (address(uint160(WitnessLib.find(reads, proxy, PHASE_SLOT) >> 16)) != aggregator) {
            revert UnsupportedFeed("proxy aggregator");
        }
        uint32 round = uint32(WitnessLib.find(reads, aggregator, HOT_SLOT) >> 176);
        uint256 t = WitnessLib.find(reads, aggregator, transmissionSlot(round));
        int192 answer = int192(uint192(t));
        if (answer <= 0) revert NoAnswer();
        uint256 updatedAt = t >> 192;
        uint256 at = anchors.timestampOf(id);
        if (updatedAt > at || at > updatedAt + maxStaleness) revert StalePrice(updatedAt, at);
        value = uint256(uint192(answer)) * 1e6 / 10 ** decimals;
        anchorBlock = a.blockNumber;
    }

    function _code(WitnessLib.WitnessPackage memory p, address who, bytes32 want, string memory what) internal pure {
        for (uint256 i; i < p.accounts.length; ++i) {
            if (p.accounts[i].account == who) {
                if (!p.accounts[i].exists || p.accounts[i].codeHash != want) revert UnsupportedFeed(what);
                return;
            }
        }
        revert UnsupportedFeed(what);
    }
}

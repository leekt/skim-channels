// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {WitnessLib} from "../libraries/WitnessLib.sol";
import {EthTypes} from "../libraries/EthTypes.sol";

/// @notice A Chainlink price from another chain, copied here with a storage proof. The devnet
///         uses it to give the clearing app Sepolia's ETH/USD: a relayer follows Sepolia with
///         a skim node and sends `update(rawHeader, package)`.
///
///         Verified here: the header hashes to the package's anchor and carries its state
///         root; both slots are proven against that root; the answer is the aggregator's own
///         latest round at that block; blocks only move forward.
///         Trusted: that the header is canonical on the source chain. This chain has no
///         BLOCKHASH for Sepolia, so only the relayer may submit headers.
///
///         Layout of Chainlink's AccessControlledOffchainAggregator 3.0.0 (the Sepolia ETH/USD
///         aggregator): slot 0x2b holds the hot variables, with the latest round id as a
///         uint32 at bit 176; transmissions[round] is at keccak(round, 0x2c), with the answer
///         as an int192 (8 decimals) and its timestamp as the top uint64.
contract FeedMirror {
    /// @notice USD per ETH, 6 decimals. Slot 0: the slot the clearing channel reads.
    uint256 public price;
    uint64 public sourceBlock;
    bytes32 public sourceBlockHash;
    uint32 public round;
    uint64 public answeredAt;
    uint64 public mirroredAt;

    uint256 public immutable sourceChainId;
    address public immutable aggregator;
    address public immutable relayer;

    bytes32 internal constant HOT_SLOT = bytes32(uint256(0x2b));
    uint256 internal constant TRANSMISSIONS_SLOT = 0x2c;

    event Mirrored(uint64 sourceBlock, bytes32 sourceBlockHash, uint32 round, uint256 price, uint64 answeredAt);

    error NotRelayer();
    error WrongChain();
    error HeaderMismatch();
    error NotNewer();
    error MissingRead(bytes32 slot);
    error NoAnswer();

    constructor(uint256 sourceChainId_, address aggregator_, address relayer_) {
        sourceChainId = sourceChainId_;
        aggregator = aggregator_;
        relayer = relayer_;
    }

    function transmissionSlot(uint32 r) public pure returns (bytes32) {
        return keccak256(abi.encode(uint256(r), TRANSMISSIONS_SLOT));
    }

    function update(bytes calldata rawHeader, bytes calldata package) external {
        if (msg.sender != relayer) revert NotRelayer();
        WitnessLib.WitnessPackage memory p = WitnessLib.decode(package);
        if (p.anchor.chainId != sourceChainId) revert WrongChain();
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(rawHeader);
        if (h.hash != p.anchor.blockHash || h.stateRoot != p.anchor.stateRoot || h.number != p.anchor.blockNumber) {
            revert HeaderMismatch();
        }
        if (p.anchor.blockNumber <= sourceBlock) revert NotNewer();
        WitnessLib.Read[] memory reads = WitnessLib.verify(p);

        uint32 r = uint32(_value(reads, HOT_SLOT) >> 176);
        uint256 t = _value(reads, transmissionSlot(r));
        int192 answer = int192(uint192(t));
        if (answer <= 0) revert NoAnswer();

        price = uint256(uint192(answer)) / 100; // 8 decimals -> 6
        sourceBlock = p.anchor.blockNumber;
        sourceBlockHash = p.anchor.blockHash;
        round = r;
        answeredAt = uint64(t >> 192);
        mirroredAt = uint64(block.timestamp);
        emit Mirrored(sourceBlock, sourceBlockHash, r, price, answeredAt);
    }

    function _value(WitnessLib.Read[] memory reads, bytes32 slot) internal view returns (uint256) {
        for (uint256 i; i < reads.length; ++i) {
            if (reads[i].account == aggregator && reads[i].slot == slot) return reads[i].value;
        }
        revert MissingRead(slot);
    }
}

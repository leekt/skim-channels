// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {WitnessLib} from "../libraries/WitnessLib.sol";
import {EthTypes} from "../libraries/EthTypes.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

/// @notice On the app's execution environment: the L1 state an app may read, one verified
///         snapshot per anchor. `pin` takes a raw L1 header and a witness package; the header
///         must hash to the package's anchor and carry its state root, and every proof must
///         verify against that root (mixed roots, missing proofs, wrong values: reverted).
///         `read` returns only witnessed values and reverts otherwise. Read-only: nothing
///         here can write to L1.
///
///         Trust: the executor can't check that the header is canonical on L1 (no BLOCKHASH
///         for L1 here). The runtime checks that before pinning (skim's light-client heads
///         or the confirmation policy), and L1 settlement re-checks every value it uses
///         against AnchorRegistry. Nothing on L1 trusts this contract.
contract L1View {
    struct Anchor {
        uint64 number;
        bytes32 blockHash;
        bytes32 stateRoot;
    }

    uint256 public immutable l1ChainId;
    mapping(bytes32 anchorId => Anchor) public anchors;
    mapping(bytes32 anchorId => mapping(address => mapping(bytes32 => uint256))) internal values;
    mapping(bytes32 anchorId => mapping(address => mapping(bytes32 => bool))) internal witnessed;

    event Pinned(bytes32 indexed anchorId, uint64 number, bytes32 blockHash, uint256 reads);

    error WrongChain();
    error HeaderMismatch();
    error NotWitnessed(bytes32 anchorId, address account, bytes32 slot);

    constructor(uint256 l1ChainId_) {
        l1ChainId = l1ChainId_;
    }

    function pin(bytes calldata rawHeader, bytes calldata package) external returns (bytes32 id) {
        WitnessLib.WitnessPackage memory p = WitnessLib.decode(package);
        ChannelTypes.L1Anchor memory a = p.anchor;
        if (a.chainId != l1ChainId) revert WrongChain();
        EthTypes.HeaderFields memory h = EthTypes.decodeHeader(rawHeader);
        if (h.hash != a.blockHash || h.stateRoot != a.stateRoot || h.number != a.blockNumber) revert HeaderMismatch();
        WitnessLib.Read[] memory reads = WitnessLib.verify(p);
        id = ChannelTypes.anchorId(a);
        anchors[id] = Anchor(a.blockNumber, a.blockHash, a.stateRoot);
        for (uint256 i; i < reads.length; ++i) {
            values[id][reads[i].account][reads[i].slot] = reads[i].value;
            witnessed[id][reads[i].account][reads[i].slot] = true;
        }
        emit Pinned(id, a.blockNumber, a.blockHash, reads.length);
    }

    function read(bytes32 id, address account, bytes32 slot) external view returns (uint256) {
        if (!witnessed[id][account][slot]) revert NotWitnessed(id, account, slot);
        return values[id][account][slot];
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {PredictionTypes} from "./PredictionTypes.sol";
import {SparseTree16} from "./SparseTree16.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";
import {WitnessLib} from "../libraries/WitnessLib.sol";
import {AnchorRegistry} from "../AnchorRegistry.sol";
import {WitnessVerifier} from "../verifiers/WitnessVerifier.sol";

/// @notice Stateless helper for PredictionChannel: decodes packed tickets and updates,
///         builds and checks roots, checks ticket signatures, reads the oracle. Separate so
///         the channel stays deployable under Amsterdam code pricing.
contract PredictionRules {
    bytes32 internal constant TICKET_TYPEHASH = keccak256("Ticket(uint256 round,uint256 up,uint256 down,uint64 nonce)");

    error BadTicket();
    error BadEncoding();
    error BadAnchor();
    error BadProof();

    /// @notice The bits [shift, shift + bits) of `oracle`'s `slot`, from an L1 witness whose
    ///         anchor is block `blockNumber` of this chain and is recorded in `anchors`.
    function oracleValue(
        bytes calldata witness,
        AnchorRegistry anchors,
        WitnessVerifier verifier,
        uint64 blockNumber,
        address oracle,
        bytes32 slot,
        uint8 shift,
        uint16 bits
    ) external view returns (uint256 v) {
        (ChannelTypes.L1Anchor memory a, WitnessLib.Read[] memory reads) = verifier.verify(witness);
        if (
            a.blockNumber != blockNumber || a.chainId != block.chainid || a.stateRoot == 0
                || anchors.stateRootOf(ChannelTypes.anchorId(a)) != a.stateRoot
        ) revert BadAnchor();
        v = WitnessLib.find(reads, oracle, slot) >> shift;
        if (bits < 256) v &= (uint256(1) << bits) - 1;
    }

    /// @param tickets packed committed tickets (PredictionTypes.TICKET_BYTES each), indices
    ///        strictly ascending
    /// @return root participation root
    /// @return up total UP stake
    /// @return down total DOWN stake
    /// @return lastIdx the largest user index (the caller checks it is registered)
    function participation(bytes calldata tickets)
        external
        pure
        returns (bytes32 root, uint256 up, uint256 down, uint256 lastIdx)
    {
        uint256 w = PredictionTypes.TICKET_BYTES;
        if (tickets.length % w != 0) revert BadEncoding();
        uint256 n = tickets.length / w;
        uint256[] memory idxs = new uint256[](n);
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            bytes calldata t = tickets[i * w:(i + 1) * w];
            PredictionTypes.PartLeaf memory p =
                PredictionTypes.PartLeaf(uint128(bytes16(t[4:20])), uint128(bytes16(t[20:36])), keccak256(t[36:w]));
            if (p.up + p.down == 0) revert BadTicket();
            idxs[i] = uint32(bytes4(t[0:4]));
            leaves[i] = PredictionTypes.partHash(p);
            up += p.up;
            down += p.down;
        }
        lastIdx = n == 0 ? 0 : idxs[n - 1];
        root = SparseTree16.build(idxs, leaves);
    }

    /// @param updates packed updates (PredictionTypes.UPDATE_BYTES each), indices strictly ascending
    /// @param proof unchanged subtrees, as SparseTree16.transition consumes them
    /// @return oldRoot the root the old leaves belong to (the caller checks it is finalized)
    /// @return newRoot the root after the update
    /// @return lastIdx the largest user index (the caller checks it is registered)
    function transition(bytes calldata updates, bytes32[] calldata proof)
        external
        pure
        returns (bytes32 oldRoot, bytes32 newRoot, uint256 lastIdx)
    {
        uint256 w = PredictionTypes.UPDATE_BYTES;
        if (updates.length % w != 0) revert BadEncoding();
        uint256 n = updates.length / w;
        uint256[] memory idxs = new uint256[](n);
        bytes32[] memory olds = new bytes32[](n);
        bytes32[] memory news = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            bytes calldata u = updates[i * w:(i + 1) * w];
            idxs[i] = uint32(bytes4(u[0:4]));
            olds[i] = PredictionTypes.leafHash(unpackLeaf(u[4:56]));
            news[i] = PredictionTypes.leafHash(unpackLeaf(u[56:108]));
        }
        lastIdx = n == 0 ? 0 : idxs[n - 1];
        (oldRoot, newRoot) = SparseTree16.transition(idxs, olds, news, proof);
    }

    function unpackLeaf(bytes calldata b) public pure returns (PredictionTypes.Leaf memory) {
        return PredictionTypes.Leaf(
            uint128(bytes16(b[0:16])), uint128(bytes16(b[16:32])), uint128(bytes16(b[32:48])), uint32(bytes4(b[48:52]))
        );
    }

    /// @notice Whether user `idx`'s committed ticket (proven against `partRoot`) isn't signed
    ///         by `user`, or stakes more than the user had at the commit: `leaf` (proven
    ///         against `finalized`) plus deposits not yet applied.
    function commitFault(
        bytes32 domain,
        uint256 round,
        address user,
        uint32 idx,
        bytes calldata ticket,
        bytes32[16] calldata partSiblings,
        bytes32 partRoot,
        PredictionTypes.Leaf calldata leaf,
        bytes32[16] calldata siblings,
        bytes32 finalized,
        uint256 depositsAtCommit
    ) external pure returns (bool) {
        PredictionTypes.Ticket memory t = abi.decode(ticket, (PredictionTypes.Ticket));
        PredictionTypes.PartLeaf memory p =
            PredictionTypes.PartLeaf(t.up, t.down, keccak256(abi.encodePacked(t.nonce, t.sig)));
        if (SparseTree16.rootFrom(PredictionTypes.partHash(p), idx, partSiblings) != partRoot) revert BadProof();
        if (ChannelTypes.recoverSigner(ticketDigest(domain, round, t.up, t.down, t.nonce), t.sig) != user) {
            return true;
        }
        if (SparseTree16.rootFrom(PredictionTypes.leafHash(leaf), idx, siblings) != finalized) revert BadProof();
        return t.up + t.down > leaf.balance + depositsAtCommit - leaf.depositsApplied;
    }

    /// @notice Whether user `idx`'s leaf in `pending` is wrong: it claims more deposits or
    ///         requests than L1 recorded, or isn't what PredictionTypes.next computes from the
    ///         finalized leaf, the user's round leaf and the counters it carries.
    /// @param evidence abi.encode(Leaf old, bytes32[16] oldSiblings, Leaf new,
    ///        bytes32[16] newSiblings, PartLeaf roundLeaf, bytes32[16] roundSiblings)
    function updateFault(
        uint32 idx,
        bytes calldata evidence,
        bytes32 finalized,
        bytes32 pending,
        bytes32 partRoot,
        PredictionTypes.Effect calldata e,
        uint256 deposits,
        uint256 requests
    ) external pure returns (bool) {
        (
            PredictionTypes.Leaf memory o,
            bytes32[16] memory os,
            PredictionTypes.Leaf memory n,
            bytes32[16] memory ns,
            PredictionTypes.PartLeaf memory p,
            bytes32[16] memory ps
        ) = abi.decode(
            evidence,
            (
                PredictionTypes.Leaf,
                bytes32[16],
                PredictionTypes.Leaf,
                bytes32[16],
                PredictionTypes.PartLeaf,
                bytes32[16]
            )
        );
        if (SparseTree16.rootFrom(PredictionTypes.leafHash(o), idx, os) != finalized) revert BadProof();
        if (SparseTree16.rootFrom(PredictionTypes.leafHash(n), idx, ns) != pending) revert BadProof();
        _checkRoundLeaf(idx, p, ps, partRoot, e.active);
        if (n.depositsApplied > deposits || n.requestsApplied > requests) return true;
        (PredictionTypes.Leaf memory want, bool ok) =
            PredictionTypes.next(o, p, e, n.depositsApplied, n.requestsApplied);
        return !ok || PredictionTypes.leafHash(want) != PredictionTypes.leafHash(n);
    }

    /// @notice PredictionTypes.next for user `idx`, with `p` proven against `partRoot` when
    ///         the round effect is active (and required empty otherwise).
    function next(
        uint32 idx,
        PredictionTypes.Leaf calldata old,
        PredictionTypes.PartLeaf calldata p,
        bytes32[16] calldata partSiblings,
        bytes32 partRoot,
        PredictionTypes.Effect calldata e,
        uint256 deposits,
        uint256 requests
    ) external pure returns (PredictionTypes.Leaf memory, bool) {
        _checkRoundLeaf(idx, p, partSiblings, partRoot, e.active);
        return PredictionTypes.next(old, p, e, deposits, requests);
    }

    function _checkRoundLeaf(
        uint32 idx,
        PredictionTypes.PartLeaf memory p,
        bytes32[16] memory siblings,
        bytes32 partRoot,
        bool active
    ) internal pure {
        if (active) {
            if (SparseTree16.rootFrom(PredictionTypes.partHash(p), idx, siblings) != partRoot) {
                revert BadProof();
            }
        } else if (p.up != 0 || p.down != 0 || p.ticketHash != 0) {
            revert BadProof();
        }
    }

    function ticketDigest(bytes32 domain, uint256 round, uint256 up, uint256 down, uint64 nonce)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(hex"1901", domain, keccak256(abi.encode(TICKET_TYPEHASH, round, up, down, nonce)))
        );
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PredictionChannel} from "../../src/predict/PredictionChannel.sol";
import {PredictionDisputes} from "../../src/predict/PredictionDisputes.sol";
import {PredictionStorage} from "../../src/predict/PredictionStorage.sol";
import {PredictionRules} from "../../src/predict/PredictionRules.sol";
import {PredictionTypes as T} from "../../src/predict/PredictionTypes.sol";
import {AnchorRegistry} from "../../src/AnchorRegistry.sol";
import {WitnessVerifier} from "../../src/verifiers/WitnessVerifier.sol";

/// Test-side sparse tree over a dense leaf array (indices 0 .. n-1), written independently of
/// SparseTree16: zero[i+1] = keccak(zero[i], zero[i]).
library Tree {
    function siblings(bytes32[] memory leaves, uint256 idx) internal pure returns (bytes32[16] memory sib) {
        bytes32[] memory cur = leaves;
        bytes32 z;
        for (uint256 l; l < 16; ++l) {
            uint256 s = idx ^ 1;
            sib[l] = s < cur.length ? cur[s] : z;
            cur = _up(cur, z);
            idx >>= 1;
            z = keccak256(abi.encodePacked(z, z));
        }
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory cur = leaves;
        bytes32 z;
        for (uint256 l; l < 16; ++l) {
            cur = _up(cur, z);
            z = keccak256(abi.encodePacked(z, z));
        }
        return cur.length == 0 ? z : cur[0];
    }

    /// The siblings SparseTree16.transition consumes for leaves at `indices` (ascending).
    function multiproof(bytes32[] memory leaves, uint256[] memory indices)
        internal
        pure
        returns (bytes32[] memory out)
    {
        out = new bytes32[](16 * indices.length);
        uint256 k;
        bytes32[] memory cur = leaves;
        uint256[] memory idx = new uint256[](indices.length);
        for (uint256 i; i < idx.length; ++i) {
            idx[i] = indices[i];
        }
        uint256 n = idx.length;
        bytes32 z;
        for (uint256 l; l < 16; ++l) {
            uint256 m;
            for (uint256 i; i < n;) {
                uint256 x = idx[i];
                if (x & 1 == 0 && i + 1 < n && idx[i + 1] == x + 1) {
                    i += 2;
                } else {
                    uint256 s = x ^ 1;
                    out[k++] = s < cur.length ? cur[s] : z;
                    i += 1;
                }
                idx[m++] = x >> 1;
            }
            n = m;
            cur = _up(cur, z);
            z = keccak256(abi.encodePacked(z, z));
        }
        assembly {
            mstore(out, k)
        }
    }

    function _up(bytes32[] memory cur, bytes32 z) private pure returns (bytes32[] memory nxt) {
        nxt = new bytes32[]((cur.length + 1) / 2);
        for (uint256 i; i < nxt.length; ++i) {
            bytes32 b = 2 * i + 1 < cur.length ? cur[2 * i + 1] : z;
            nxt[i] = keccak256(abi.encodePacked(cur[2 * i], b));
        }
    }
}

/// Shared setup: the witness fixture (oracle slot = 6000 at block 100, 7000 at block 101),
/// a channel, and an off-chain model of the operator's tree that tests mutate deliberately.
abstract contract PredictionBase is Test {
    uint256 constant L1 = 11155111;
    uint256 constant WINDOW = 1 hours;
    uint256 constant BOND = 1 ether;
    uint64 constant DEADLINE = 30;
    uint64 constant CHALLENGE_END = 95; // ≥ DEADLINE + 64 (MIN_COMMIT_CHALLENGE_BLOCKS)
    uint64 constant RESOLUTION = 101; // oracle reads 7000 here (the fixture header's number)

    PredictionChannel ch;
    /// The same address, typed for the functions the channel runs by delegatecall.
    PredictionDisputes D;
    PredictionRules rules;
    AnchorRegistry anchors;
    WitnessVerifier wv;
    address op = address(0x0FE7);
    address watcher = address(0x5EE);
    address oracle;
    bytes32 oracleSlot;
    bytes raw1;
    bytes package1;

    uint256[] keys;
    address[] who;
    /// The finalized tree as the model holds it (index = user index).
    T.Leaf[] fin;

    function setUp() public virtual {
        vm.chainId(L1);
        vm.warp(1_700_000_000);
        vm.roll(20);
        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/read-and-split.json"));
        oracle = vm.parseJsonAddress(j, ".fixture");
        oracleSlot = vm.parseJsonBytes32(j, ".shareSlot");
        raw1 = vm.parseJsonBytes(j, ".h1.rawHeader");
        package1 = vm.parseJsonBytes(j, ".h1.package");
        anchors = new AnchorRegistry();
        wv = new WitnessVerifier();
        rules = new PredictionRules();
        ch = new PredictionChannel(new PredictionDisputes(_policy()));
        D = PredictionDisputes(address(ch));
        vm.deal(op, 100 ether);
        vm.prank(op);
        ch.postBond{value: BOND}();
    }

    /// The production floors: 1 h challenge window, 1 day forced delay, 64 commit blocks.
    function _policy() internal view returns (PredictionStorage.Config memory) {
        return PredictionStorage.Config({
            operator: op,
            anchors: anchors,
            witnessVerifier: wv,
            rules: rules,
            minBond: BOND,
            challengeWindow: WINDOW,
            forceDelay: 1 days,
            commitChallengeBlocks: 64,
            maxRoundBlocks: 1800
        });
    }

    // ---- users ------------------------------------------------------------------------------

    function _addUsers(uint256 n, uint256 amount) internal {
        for (uint256 i; i < n; ++i) {
            uint256 k = 0xA000 + keys.length;
            address a = vm.addr(k);
            keys.push(k);
            who.push(a);
            fin.push(T.Leaf(0, 0, 0, 0));
            vm.deal(a, amount);
            vm.prank(a);
            ch.deposit{value: amount}();
        }
    }

    // ---- tickets and the participation list -----------------------------------------------

    /// A committed ticket as tests hold it.
    struct Tk {
        uint32 idx;
        T.Ticket t;
    }

    function _digest(uint256 r, uint256 up, uint256 down, uint64 nonce) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SkimPrediction"),
                keccak256("0"),
                L1,
                address(ch)
            )
        );
        bytes32 s = keccak256(
            abi.encode(keccak256("Ticket(uint256 round,uint256 up,uint256 down,uint64 nonce)"), r, up, down, nonce)
        );
        return keccak256(abi.encodePacked(hex"1901", domain, s));
    }

    function _ticket(uint256 key, uint256 r, uint256 up, uint256 down, uint64 nonce)
        internal
        view
        returns (T.Ticket memory)
    {
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(key, _digest(r, up, down, nonce));
        return T.Ticket(up, down, nonce, abi.encodePacked(rr, ss, v));
    }

    function _pack(Tk[] memory e) internal pure returns (bytes memory) {
        bytes[] memory parts = new bytes[](e.length);
        for (uint256 i; i < e.length; ++i) {
            T.Ticket memory t = e[i].t;
            parts[i] = abi.encodePacked(e[i].idx, uint128(t.up), uint128(t.down), t.nonce, t.sig);
        }
        return _join(parts);
    }

    /// Concatenation in one allocation (repeated bytes.concat is quadratic in memory).
    function _join(bytes[] memory parts) internal pure returns (bytes memory out) {
        uint256 len;
        for (uint256 i; i < parts.length; ++i) {
            len += parts[i].length;
        }
        out = new bytes(len);
        uint256 at;
        for (uint256 i; i < parts.length; ++i) {
            bytes memory p = parts[i];
            assembly {
                mcopy(add(add(out, 32), at), add(p, 32), mload(p))
            }
            at += p.length;
        }
    }

    function _part(T.Ticket memory t) internal pure returns (T.PartLeaf memory) {
        return T.PartLeaf(t.up, t.down, keccak256(abi.encodePacked(t.nonce, t.sig)));
    }

    function _partHash(T.PartLeaf memory p) internal pure returns (bytes32) {
        if (p.up == 0 && p.down == 0 && p.ticketHash == 0) return 0;
        return keccak256(abi.encode(keccak256("skim-predict/participation-leaf/v0"), p.up, p.down, p.ticketHash));
    }

    /// Dense round-leaf hashes over all users.
    function _partLeaves(Tk[] memory e) internal view returns (bytes32[] memory h) {
        h = new bytes32[](who.length);
        for (uint256 i; i < e.length; ++i) {
            h[e[i].idx] = _partHash(_part(e[i].t));
        }
    }

    function _partOf(Tk[] memory e, uint32 idx) internal pure returns (T.PartLeaf memory p) {
        for (uint256 i; i < e.length; ++i) {
            if (e[i].idx == idx) return _part(e[i].t);
        }
    }

    // ---- rounds -----------------------------------------------------------------------------

    function _open(uint256 strike) internal returns (uint256 r) {
        vm.prank(op);
        r = ch.openRound(strike, oracle, oracleSlot, 0, 256, DEADLINE, CHALLENGE_END, RESOLUTION);
    }

    function _commit(uint256 r, Tk[] memory e) internal {
        vm.prank(op);
        D.commit(r, _pack(e));
    }

    function _recordResolution() internal {
        vm.roll(200);
        vm.setBlockhash(RESOLUTION, keccak256(raw1));
        anchors.record(raw1);
    }

    // ---- the balance tree -------------------------------------------------------------------

    function _leafHash(T.Leaf memory l) internal pure returns (bytes32) {
        if (l.balance == 0 && l.cumWithdrawn == 0 && l.depositsApplied == 0 && l.requestsApplied == 0) return 0;
        return keccak256(
            abi.encode(
                keccak256("skim-predict/balance-leaf/v0"),
                l.balance,
                l.cumWithdrawn,
                l.depositsApplied,
                l.requestsApplied
            )
        );
    }

    function _hashes(T.Leaf[] memory ls) internal pure returns (bytes32[] memory h) {
        h = new bytes32[](ls.length);
        for (uint256 i; i < ls.length; ++i) {
            h[i] = _leafHash(ls[i]);
        }
    }

    function _finSiblings(uint256 idx) internal view returns (bytes32[16] memory) {
        return Tree.siblings(_hashes(fin), idx);
    }

    function _packLeaf(T.Leaf memory l) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint128(l.balance), uint128(l.cumWithdrawn), uint128(l.depositsApplied), uint32(l.requestsApplied)
        );
    }

    /// The packed updates turning `fin` into `next` at every index where they differ, and the
    /// multiproof of everything else.
    function _updates(T.Leaf[] memory next) internal view returns (bytes memory u, bytes32[] memory proof) {
        bytes32[] memory h = _hashes(fin);
        uint256 n;
        for (uint256 i; i < next.length; ++i) {
            if (_leafHash(next[i]) != h[i]) n++;
        }
        uint256[] memory idx = new uint256[](n);
        bytes[] memory parts = new bytes[](n);
        uint256 k;
        for (uint256 i; i < next.length; ++i) {
            if (_leafHash(next[i]) == h[i]) continue;
            parts[k] = bytes.concat(abi.encodePacked(uint32(i)), _packLeaf(fin[i]), _packLeaf(next[i]));
            idx[k++] = i;
        }
        u = _join(parts);
        if (n != 0) proof = Tree.multiproof(h, idx);
    }

    function _propose(uint256 r, T.Leaf[] memory next) internal {
        _propose(r, next, _cursorFor(next));
    }

    function _propose(uint256 r, T.Leaf[] memory next, uint256 cursor) internal {
        (bytes memory u, bytes32[] memory proof) = _updates(next);
        vm.prank(op);
        ch.propose(r, u, proof, cursor);
    }

    /// The queue prefix `next` serves: request number s of user i is served when
    /// next[i].requestsApplied > s.
    function _cursorFor(T.Leaf[] memory next) internal view returns (uint256 c) {
        uint256 len = ch.queueLength();
        uint256[] memory seen = new uint256[](next.length);
        for (c = 0; c < len; ++c) {
            (uint32 idx,,) = ch.queue(c);
            if (idx >= next.length || next[idx].requestsApplied <= seen[idx]) break;
            seen[idx]++;
        }
    }

    function _finalize(T.Leaf[] memory next) internal {
        vm.warp(block.timestamp + WINDOW);
        ch.finalize();
        for (uint256 i; i < next.length; ++i) {
            fin[i] = next[i];
        }
        assertEq(ch.finalizedRoot(), Tree.root(_hashes(fin)), "model root");
    }

    function _copyFin() internal view returns (T.Leaf[] memory c) {
        c = new T.Leaf[](fin.length);
        for (uint256 i; i < fin.length; ++i) {
            c[i] = fin[i];
        }
    }
}

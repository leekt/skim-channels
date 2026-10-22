// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Tree} from "../predict/PredictionBase.sol";
import {TestUSD} from "./Clearing.t.sol";
import {ClearingRules as R} from "../../src/clearing/ClearingRules.sol";
import {ClearingLedger as L} from "../../src/clearing/ClearingLedger.sol";
import {ClearingChannel} from "../../src/clearing/ClearingChannel.sol";
import {ClearingDisputes} from "../../src/clearing/ClearingDisputes.sol";
import {ClearingStorage, IERC20Lite} from "../../src/clearing/ClearingStorage.sol";
import {ClearingCodec} from "../../src/clearing/ClearingCodec.sol";
import {ClearingChecker} from "../../src/clearing/ClearingChecker.sol";
import {ClearingL1, IPriceFeed} from "../../src/clearing/ClearingL1.sol";
import {ClearingDirectBatch} from "../../src/clearing/ClearingDirectBatch.sol";
import {AnchorRegistry} from "../../src/AnchorRegistry.sol";
import {AllocationFixture} from "../../src/examples/AllocationFixture.sol";
import {WitnessVerifier} from "../../src/verifiers/WitnessVerifier.sol";

/// The same fills settled three ways, priced as L1 transactions (as PredictionCost.t.sol:
/// 21,000 + calldata incl. the EIP-7623 floor + cooled execution − capped refund):
/// - ClearingChannel: optimistic; publishes packed fills and changed accounts.
/// - ClearingDirectBatch: the same fills as one batch, verified completely on L1 at once.
/// - ClearingL1: one L1 transaction per fill (taker submits the maker's signed order).
/// Steady state: measured on a second batch (accounts exist, deposits applied).
/// Prints `compare,<system>,<scenario>,<fills>,<users>,<gas>`.
contract ClearingCompareTest is Test {
    ClearingChannel chn;
    ClearingDisputes D;
    ClearingL1 l1;
    ClearingDirectBatch direct;
    AnchorRegistry anchors;
    WitnessVerifier wv;
    ClearingCodec codec;
    ClearingChecker checker;
    TestUSD usd;
    address op = address(0x0FE7);
    address oracle;
    address feed;
    bytes pkg1;
    uint256 nUsers;
    L.Account[] fin;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1_700_000_000);
        string memory fx = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/read-and-split.json"));
        oracle = vm.parseJsonAddress(fx, ".fixture");
        bytes memory raw1 = vm.parseJsonBytes(fx, ".h1.rawHeader");
        pkg1 = vm.parseJsonBytes(fx, ".h1.package");
        anchors = new AnchorRegistry();
        wv = new WitnessVerifier();
        codec = new ClearingCodec();
        checker = new ClearingChecker();
        usd = new TestUSD();
        vm.roll(200);
        vm.setBlockhash(101, keccak256(raw1));
        anchors.record(raw1);
        chn = new ClearingChannel(
            new ClearingDisputes(
                ClearingStorage.Config({
                    operator: op,
                    usd: IERC20Lite(address(usd)),
                    anchors: anchors,
                    witnessVerifier: wv,
                    codec: codec,
                    priceFeed: oracle,
                    priceSlot: bytes32(0),
                    bandBps: 100,
                    challengeWindow: 1 hours,
                    forceDelay: 1 days,
                    maxAnchorAge: 8191,
                    minBond: 1 ether,
                    takeoverDelay: 2 days
                })
            )
        );
        D = ClearingDisputes(address(chn));
        feed = address(new AllocationFixture(7000)); // the direct-L1 baseline reads the feed itself
        l1 = new ClearingL1(IPriceFeed(feed), 100, address(usd));
        direct = new ClearingDirectBatch(op, anchors, wv, checker, oracle, bytes32(0), 100, 8191, address(usd));
        vm.deal(op, 100 ether);
    }

    function _txGas(address from, address to, bytes memory data, uint256 value) internal returns (uint256) {
        vm.cool(to);
        vm.cool(address(codec));
        vm.cool(address(checker));
        vm.cool(address(wv));
        vm.cool(address(anchors));
        vm.cool(address(usd));
        vm.cool(feed);
        vm.cool(address(chn.disputes()));
        vm.cool(from);
        vm.prank(from, from);
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        Vm.Gas memory g = vm.lastCallGas();
        uint256 zeros;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == 0) zeros++;
        }
        uint256 tokens = zeros + 4 * (data.length - zeros);
        uint256 standard = 4 * tokens + g.gasTotalUsed; // gasTotalUsed includes the 21,000 base
        uint256 floor = 21_000 + 10 * tokens;
        uint256 used = standard > floor ? standard : floor;
        uint256 refund = g.gasRefunded > 0 ? uint256(int256(g.gasRefunded)) : 0;
        if (refund > used / 5) refund = used / 5;
        return used - refund;
    }

    function _key(uint256 i) internal pure returns (uint256) {
        return 0x1000 + i;
    }

    function _who(uint256 i) internal pure returns (address) {
        return vm.addr(_key(i));
    }

    /// Users 0..u−1; even ones sell ETH, odd ones sell USD. Funded in all three systems.
    function _users(uint256 u) internal {
        nUsers = u;
        for (uint256 i; i < u; ++i) {
            address a = _who(i);
            vm.deal(a, 400 ether);
            usd.mint(a, 4_000_000);
            vm.startPrank(a);
            usd.approve(address(chn), type(uint256).max);
            usd.approve(address(l1), type(uint256).max);
            usd.approve(address(direct), type(uint256).max);
            direct.deposit{value: 100 ether}(R.ETH, 100 ether);
            direct.deposit(R.USD, 1_000_000);
            chn.deposit{value: 100 ether}(R.ETH, 100 ether);
            chn.deposit(R.USD, 1_000_000);
            l1.deposit{value: 100 ether}(R.ETH, 100 ether);
            l1.deposit(R.USD, 1_000_000);
            vm.stopPrank();
            fin.push();
        }
    }

    struct F {
        uint256 s; // ETH seller
        uint256 b; // USD seller
        uint64 ns;
        uint64 nb;
    }

    /// `f` fills; fill k pairs seller 2·(k mod u/2) with buyer 2·(k mod u/2)+1; nonces from `n0`.
    function _plan(uint256 f, uint256 u, uint64 n0) internal pure returns (F[] memory p) {
        p = new F[](f);
        uint256 pairs = u / 2;
        for (uint256 k; k < f; ++k) {
            uint256 j = k % pairs;
            uint64 round = uint64(k / pairs);
            p[k] = F(2 * j, 2 * j + 1, n0 + round, n0 + round);
        }
    }

    function _signed(uint256 i, uint8 sell, uint128 amt, uint128 want, uint64 nonce, bytes32 domain)
        internal
        pure
        returns (R.Order memory o, bytes memory sig)
    {
        o = R.Order(_who(i), sell, amt, want, nonce, 10_000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key(i), R.orderDigest(domain, o));
        sig = abi.encodePacked(r, s, v);
    }

    // ---- the channel ----------------------------------------------------------------------------------

    function _channelBatch(F[] memory p)
        internal
        returns (bytes memory fills, bytes memory u, bytes32[] memory proof, L.Account[] memory next)
    {
        bytes32 dom = chn.domain();
        next = new L.Account[](fin.length);
        bool[] memory touched = new bool[](fin.length);
        for (uint256 i; i < fin.length; ++i) {
            next[i] = fin[i];
        }
        for (uint256 k; k < p.length; ++k) {
            (R.Order memory a, bytes memory sa) = _signed(p[k].s, R.ETH, 0.01 ether, 69, p[k].ns, dom);
            (R.Order memory b, bytes memory sb) = _signed(p[k].b, R.USD, 70, 0.01 ether, p[k].nb, dom);
            fills = bytes.concat(fills, L.encodeOrder(uint32(p[k].s), a), sa, L.encodeOrder(uint32(p[k].b), b), sb);
            for (uint256 side; side < 2; ++side) {
                uint256 i = side == 0 ? p[k].s : p[k].b;
                if (!touched[i]) {
                    touched[i] = true;
                    L.applyDeposits(next[i], 100 ether, 1_000_000);
                }
            }
            require(L.applySide(next[p[k].s], R.ETH, 0.01 ether, 70, p[k].ns));
            require(L.applySide(next[p[k].b], R.USD, 70, 0.01 ether, p[k].nb));
        }
        bytes32[] memory h = new bytes32[](fin.length);
        uint256 n;
        for (uint256 i; i < fin.length; ++i) {
            h[i] = L.leafHash(fin[i]);
            if (L.leafHash(next[i]) != h[i]) n++;
        }
        uint256[] memory idx = new uint256[](n);
        uint256 c;
        for (uint256 i; i < fin.length; ++i) {
            if (L.leafHash(next[i]) == h[i]) continue;
            u = bytes.concat(u, abi.encodePacked(uint32(i)), L.encodeLeaf(fin[i]), L.encodeLeaf(next[i]));
            idx[c++] = i;
        }
        proof = Tree.multiproof(h, idx);
    }

    function _channelRun(F[] memory p, string memory label, bool measure) internal returns (bytes memory fills) {
        bytes memory u;
        bytes32[] memory proof;
        L.Account[] memory next;
        (fills, u, proof, next) = _channelBatch(p);
        uint256 g = _txGas(op, address(chn), abi.encodeCall(chn.propose, (pkg1, fills, u, proof, 0, 0, "")), 1 ether);
        vm.warp(block.timestamp + 1 hours);
        uint256 g2 = _txGas(address(0x5EE), address(chn), abi.encodeCall(chn.finalize, ()), 0);
        for (uint256 i; i < next.length; ++i) {
            fin[i] = next[i];
        }
        if (measure) {
            _log("channel", label, p.length, g + g2);
            _log("channel.calldata", label, p.length, fills.length + u.length + proof.length * 32);
        }
    }

    // ---- the same batch, verified at once on L1 (control) ----------------------------------

    function _directRun(F[] memory p, string memory label, bool measure) internal {
        (R.Fill[] memory fs, address[] memory users, uint16[] memory at) = _batchShape(p, direct.domain());
        uint256 g = _txGas(op, address(direct), abi.encodeCall(direct.settle, (pkg1, abi.encode(fs), users, at)), 0);
        if (measure) _log("direct", label, p.length, g);
    }

    function _batchShape(F[] memory p, bytes32 dom)
        internal
        view
        returns (R.Fill[] memory fs, address[] memory users, uint16[] memory at)
    {
        fs = new R.Fill[](p.length);
        users = new address[](nUsers);
        for (uint256 i; i < nUsers; ++i) {
            users[i] = _who(i);
        }
        for (uint256 i; i < nUsers; ++i) {
            for (uint256 j = i + 1; j < nUsers; ++j) {
                if (users[j] < users[i]) (users[i], users[j]) = (users[j], users[i]);
            }
        }
        at = new uint16[](2 * p.length);
        for (uint256 k; k < p.length; ++k) {
            (R.Order memory a, bytes memory sa) = _signed(p[k].s, R.ETH, 0.01 ether, 69, p[k].ns, dom);
            (R.Order memory b, bytes memory sb) = _signed(p[k].b, R.USD, 70, 0.01 ether, p[k].nb, dom);
            fs[k] = R.Fill(a, b, sa, sb);
            for (uint16 i; i < users.length; ++i) {
                if (users[i] == a.trader) at[2 * k] = i;
                if (users[i] == b.trader) at[2 * k + 1] = i;
            }
        }
    }

    // ---- one L1 transaction per fill ---------------------------------------------------------------------------

    function _l1run(F[] memory p, string memory label, bool measure) internal {
        uint256 total;
        for (uint256 k; k < p.length; ++k) {
            total += _l1fill(p[k]);
        }
        if (measure) _log("l1", label, p.length, total);
    }

    function _l1fill(F memory x) internal returns (uint256) {
        (R.Order memory a, bytes memory sa) = _signed(x.s, R.ETH, 0.01 ether, 69, x.ns, l1.domain());
        R.Order memory b = R.Order(_who(x.b), R.USD, 70, 0.01 ether, x.nb, 10_000);
        return _txGas(_who(x.b), address(l1), abi.encodeCall(l1.fill, (a, sa, b)), 0);
    }

    function _log(string memory sys, string memory label, uint256 f, uint256 g) internal view {
        console.log(
            string.concat(
                "compare,", sys, ",", label, ",", vm.toString(f), ",", vm.toString(nUsers), ",", vm.toString(g)
            )
        );
    }

    function _scenario(string memory label, uint256 f, uint256 u, bool withDirect) internal {
        _users(u);
        // Batch 1 onboards everyone (deposits applied); batch 2 is measured.
        uint256 warm = u / 2;
        _channelRun(_plan(warm, u, 1), label, false);
        if (withDirect) _directRun(_plan(warm, u, 1), label, false);
        _l1run(_plan(warm, u, 1), label, false);
        F[] memory p = _plan(f, u, 2);
        bytes memory fills = _channelRun(p, label, true);
        if (withDirect) _directRun(p, label, true);
        _l1run(p, label, true);
        fills;
    }

    function test_compare_sparse_32_fills_64_users() public {
        _scenario("sparse", 32, 64, true);
    }

    function test_compare_dense_128_fills_16_users() public {
        _scenario("dense", 128, 16, true);
    }

    function test_compare_256_fills_32_users() public {
        _scenario("big", 256, 32, false);
    }

    /// Worst-case chn disputes on a 256-fill batch: the last fill, and an account in 16 fills.
    function test_dispute_gas() public {
        _users(32);
        _channelRun(_plan(16, 32, 1), "warm", false);
        F[] memory p = _plan(256, 32, 2);
        (bytes memory fills, bytes memory u, bytes32[] memory proof, L.Account[] memory next) = _channelBatch(p);
        next[0].usd += 1; // user 0's leaf is wrong
        // re-encode the updates with the wrong leaf
        u = "";
        bytes32[] memory h = new bytes32[](fin.length);
        uint256[] memory idx = new uint256[](fin.length);
        for (uint256 i; i < fin.length; ++i) {
            h[i] = L.leafHash(fin[i]);
            idx[i] = i;
            u = bytes.concat(u, abi.encodePacked(uint32(i)), L.encodeLeaf(fin[i]), L.encodeLeaf(next[i]));
        }
        proof = Tree.multiproof(h, idx);
        vm.prank(op);
        chn.propose{value: 1 ether}(pkg1, fills, u, proof, 0, 0, "");
        uint256 snap = vm.snapshotState();
        bytes32[] memory nh = new bytes32[](fin.length);
        for (uint256 i; i < fin.length; ++i) {
            nh[i] = L.leafHash(next[i]);
        }
        uint256 g = _txGas(
            address(0x5EE),
            address(chn),
            abi.encodeCall(D.challengeAccount, (0, fin[0], Tree.siblings(h, 0), next[0], Tree.siblings(nh, 0), fills)),
            0
        );
        _log("channel.challengeAccount", "16-fills-of-256", 256, g);
        vm.revertToState(snap);
        // A forged last signature, measured the same way.
        fills[fills.length - 1] = bytes1(uint8(fills[fills.length - 1]) ^ 1);
        vm.store(address(chn), bytes32(uint256(_pendingSlot()) + 1), keccak256(fills)); // fillsHash
        g = _txGas(address(0x5EE), address(chn), abi.encodeCall(D.challengeFill, (fills, 255)), 0);
        _log("channel.challengeFill", "last-of-256", 256, g);
    }

    /// Storage slot of ClearingStorage._pending (forge inspect ClearingChannel storage).
    function _pendingSlot() internal pure returns (uint256) {
        return 13;
    }
}

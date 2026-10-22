// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ClearingRules as R} from "../../src/clearing/ClearingRules.sol";
import {ClearingSettlement, IERC20Min} from "../../src/clearing/ClearingSettlement.sol";
import {ClearingChecker} from "../../src/clearing/ClearingChecker.sol";
import {AnchorRegistry} from "../../src/AnchorRegistry.sol";
import {WitnessVerifier} from "../../src/verifiers/WitnessVerifier.sol";
import {TestUSD} from "./Clearing.t.sol";

/// L1 cost of clearing batches by size. Prints `clearing,<step>,<fills>,<gas>`; transaction gas
/// as in PredictionCost.t.sol (21,000 + calldata incl. the EIP-7623 floor + cooled execution −
/// capped refund). Each fill is between two fresh traders. Witness: the fixture's price slot.
contract ClearingCostTest is Test {
    ClearingSettlement st;
    ClearingChecker checker;
    AnchorRegistry anchors;
    WitnessVerifier wv;
    TestUSD usd;
    address op = address(0x0FE7);
    bytes pkg1;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1_700_000_000);
        string memory fx = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/read-and-split.json"));
        bytes memory raw1 = vm.parseJsonBytes(fx, ".h1.rawHeader");
        pkg1 = vm.parseJsonBytes(fx, ".h1.package");
        anchors = new AnchorRegistry();
        wv = new WitnessVerifier();
        checker = new ClearingChecker();
        usd = new TestUSD();
        vm.roll(200);
        vm.setBlockhash(101, keccak256(raw1));
        anchors.record(raw1);
        st = new ClearingSettlement(
            ClearingSettlement.Config({
                operator: op,
                usd: IERC20Min(address(usd)),
                anchors: anchors,
                witnessVerifier: wv,
                priceFeed: vm.parseJsonAddress(fx, ".fixture"),
                priceSlot: bytes32(0),
                bandBps: 100,
                challengeWindow: 1 hours,
                maxAnchorAge: 256,
                minBond: 1 ether,
                checker: checker
            })
        );
        vm.deal(op, 10 ether);
        vm.prank(op);
        st.postBond{value: 1 ether}();
    }

    function _txGas(address from, address to, bytes memory data) internal returns (uint256) {
        vm.cool(address(st));
        vm.cool(address(checker));
        vm.cool(address(wv));
        vm.cool(address(anchors));
        vm.cool(address(usd));
        vm.cool(from);
        vm.prank(from, from);
        (bool ok, bytes memory ret) = to.call(data);
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

    function _signed(uint256 key, uint8 sell, uint128 sellAmt, uint128 buyAmt)
        internal
        view
        returns (R.Order memory o, bytes memory sig)
    {
        o = R.Order(vm.addr(key), sell, sellAmt, buyAmt, 1, 1000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, R.orderDigest(st.domain(), o));
        sig = abi.encodePacked(r, s, v);
    }

    function _run(uint256 n) internal {
        R.Fill[] memory fs = new R.Fill[](n);
        address[] memory users = new address[](2 * n);
        for (uint256 i; i < n; ++i) {
            uint256 ks = 0x1000 + 2 * i;
            uint256 kb = ks + 1;
            vm.deal(vm.addr(ks), 1 ether);
            vm.prank(vm.addr(ks));
            st.deposit{value: 1 ether}(R.ETH, 1 ether);
            usd.mint(vm.addr(kb), 7000);
            vm.startPrank(vm.addr(kb));
            usd.approve(address(st), 7000);
            st.deposit(R.USD, 7000);
            vm.stopPrank();
            (R.Order memory a, bytes memory sa) = _signed(ks, R.ETH, 1 ether, 6990);
            (R.Order memory b, bytes memory sb) = _signed(kb, R.USD, 7000, 1 ether);
            fs[i] = R.Fill(a, b, sa, sb);
            users[2 * i] = vm.addr(ks);
            users[2 * i + 1] = vm.addr(kb);
        }
        for (uint256 i; i < users.length; ++i) {
            for (uint256 j = i + 1; j < users.length; ++j) {
                if (users[j] < users[i]) (users[i], users[j]) = (users[j], users[i]);
            }
        }
        uint16[] memory at = new uint16[](2 * n);
        for (uint256 f; f < n; ++f) {
            for (uint16 i; i < users.length; ++i) {
                if (users[i] == fs[f].a.trader) at[2 * f] = i;
                if (users[i] == fs[f].b.trader) at[2 * f + 1] = i;
            }
        }
        bytes memory fills = abi.encode(fs);
        uint256 snap = vm.snapshotState();
        uint256 g = _txGas(op, address(st), abi.encodeCall(st.proposeBatch, (1, pkg1, fills, users, at)));
        console.log(string.concat("clearing,proposeBatch,", vm.toString(n), ",", vm.toString(g)));
        console.log(string.concat("clearing,fillsBytes,", vm.toString(n), ",", vm.toString(fills.length)));
        {
            // effects for finalize, recomputed
            int256[] memory dEth = new int256[](users.length);
            int256[] memory dUsd = new int256[](users.length);
            uint64[] memory nonces = new uint64[](users.length);
            for (uint256 i; i < users.length; ++i) {
                (uint128 e,,,,) = st.accounts(users[i]);
                nonces[i] = 1;
                if (e > 0) (dEth[i], dUsd[i]) = (-1 ether, 7000);
                else (dEth[i], dUsd[i]) = (1 ether, -7000);
            }
            vm.warp(block.timestamp + 1 hours);
            g = _txGas(address(0x5EE), address(st), abi.encodeCall(st.finalize, (users, dEth, dUsd, nonces)));
            console.log(string.concat("clearing,finalize,", vm.toString(n), ",", vm.toString(g)));
        }
        // Worst-case signature challenge: a forged last order in an otherwise equal batch.
        vm.revertToState(snap);
        fs[n - 1].sigB = fs[0].sigA;
        fills = abi.encode(fs);
        vm.prank(op);
        st.proposeBatch(1, pkg1, fills, users, at);
        g = _txGas(address(0x5EE), address(st), abi.encodeCall(st.challengeSignature, (fills, n - 1, true)));
        console.log(string.concat("clearing,challengeSignature,", vm.toString(n), ",", vm.toString(g)));
    }

    function test_cost_1_fill() public {
        _run(1);
    }

    function test_cost_8_fills() public {
        _run(8);
    }

    function test_cost_32_fills() public {
        _run(32);
    }

    function test_cost_entry_exit() public {
        address u = address(0xBEEF);
        vm.deal(u, 1 ether);
        vm.prank(u);
        st.deposit{value: 1 ether}(R.ETH, 1 ether);
        uint256 g = _txGas(u, address(st), abi.encodeCall(st.requestWithdraw, (R.ETH, 0.5 ether)));
        console.log(string.concat("clearing,requestWithdraw,0,", vm.toString(g)));
        g = _txGas(u, address(st), abi.encodeCall(st.claimWithdraw, (0)));
        console.log(string.concat("clearing,claimWithdraw,0,", vm.toString(g)));
    }
}

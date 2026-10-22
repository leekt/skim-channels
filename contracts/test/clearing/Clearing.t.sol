// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {L1View} from "../../src/clearing/L1View.sol";

/// A plain 6-decimal test token (no fee), used by forge and ts/e2e-clearing.ts.
contract TestUSD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// L1View: the app's read-only window on L1 fails closed.
contract L1ViewTest is Test {
    L1View view_;
    string fx;
    address oracle;

    function setUp() public {
        view_ = new L1View(11155111);
        fx = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/witnesses/read-and-split.json"));
        oracle = vm.parseJsonAddress(fx, ".fixture");
    }

    function test_pinThenRead() public {
        bytes32 id = view_.pin(vm.parseJsonBytes(fx, ".h1.rawHeader"), vm.parseJsonBytes(fx, ".h1.package"));
        assertEq(view_.read(id, oracle, bytes32(0)), 7000);
        bytes32 id0 = view_.pin(vm.parseJsonBytes(fx, ".h0.rawHeader"), vm.parseJsonBytes(fx, ".h0.package"));
        assertEq(view_.read(id0, oracle, bytes32(0)), 6000, "another snapshot, its own value");
        assertEq(view_.read(id, oracle, bytes32(0)), 7000, "the first is unchanged");
    }

    function test_missingStateFailsClosed() public {
        bytes32 id = view_.pin(vm.parseJsonBytes(fx, ".h1.rawHeader"), vm.parseJsonBytes(fx, ".h1.package"));
        vm.expectRevert(abi.encodeWithSelector(L1View.NotWitnessed.selector, id, oracle, bytes32(uint256(1))));
        view_.read(id, oracle, bytes32(uint256(1)));
        vm.expectRevert();
        view_.read(bytes32(uint256(123)), oracle, bytes32(0)); // never pinned
    }

    function test_badWitnessesFailClosed() public {
        bytes memory raw1 = vm.parseJsonBytes(fx, ".h1.rawHeader");
        string[4] memory bad = ["mixedRoots", "wrongValue", "presentClaimedAbsent", "unsorted"];
        for (uint256 i; i < bad.length; ++i) {
            (bool ok,) = address(view_)
                .call(abi.encodeCall(view_.pin, (raw1, vm.parseJsonBytes(fx, string.concat(".bad.", bad[i])))));
            assertFalse(ok, bad[i]);
        }
        // A header that isn't the package's anchor.
        vm.expectRevert(L1View.HeaderMismatch.selector);
        view_.pin(vm.parseJsonBytes(fx, ".h0.rawHeader"), vm.parseJsonBytes(fx, ".h1.package"));
        // Another chain's anchor.
        L1View other = new L1View(1);
        vm.expectRevert(L1View.WrongChain.selector);
        other.pin(raw1, vm.parseJsonBytes(fx, ".h1.package"));
    }
}

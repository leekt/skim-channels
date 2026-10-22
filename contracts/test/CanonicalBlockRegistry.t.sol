// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CanonicalBlockRegistry} from "../src/CanonicalBlockRegistry.sol";
import {MockTransitionVerifier} from "../src/mocks/MockTransitionVerifier.sol";
import {IStateTransitionVerifier} from "../src/interfaces/IStateTransitionVerifier.sol";
import {AnchorRegistry} from "../src/AnchorRegistry.sol";
import {ChannelTypes} from "../src/libraries/ChannelTypes.sol";
import {RLPEncode} from "./helpers/RLPEncode.sol";

contract RejectingVerifier is IStateTransitionVerifier {
    function profileKind() external pure returns (uint8) {
        return ChannelTypes.PROFILE_NATIVE_REEXECUTION_DEVNET;
    }

    function verify(bytes32, bytes32, bytes calldata, bytes32, bytes32, bytes calldata) external pure returns (bool) {
        return false;
    }
}

contract CanonicalBlockRegistryTest is Test {
    bytes32 constant ROLLUP = keccak256("rollup");
    bytes32 constant PROFILE = keccak256("profile");
    AnchorRegistry anchors;
    MockTransitionVerifier mockV;
    CanonicalBlockRegistry reg;
    bytes genesis;
    bytes32 anchorId;
    bytes proof;

    function _header(bytes32 parent, uint256 number, bytes32 salt) internal pure returns (bytes memory) {
        bytes[] memory f = new bytes[](15);
        f[0] = RLPEncode.str(abi.encodePacked(parent));
        f[1] = RLPEncode.str(abi.encodePacked(bytes32(0)));
        f[2] = RLPEncode.str(abi.encodePacked(address(0)));
        f[3] = RLPEncode.str(abi.encodePacked(keccak256(abi.encode("state", number, salt))));
        f[4] = RLPEncode.str(abi.encodePacked(bytes32(0)));
        f[5] = RLPEncode.str(abi.encodePacked(keccak256(abi.encode("receipts", number, salt))));
        f[6] = RLPEncode.str(new bytes(256));
        f[7] = RLPEncode.num(0);
        f[8] = RLPEncode.num(number);
        f[9] = RLPEncode.num(30_000_000);
        f[10] = RLPEncode.num(0);
        f[11] = RLPEncode.num(1_700_000_000 + number);
        f[12] = RLPEncode.str("");
        f[13] = RLPEncode.str(abi.encodePacked(bytes32(0)));
        f[14] = RLPEncode.str(new bytes(8));
        return RLPEncode.list(f);
    }

    function setUp() public {
        anchors = new AnchorRegistry();
        mockV = new MockTransitionVerifier();
        genesis = _header(bytes32(0), 0, "g");
        reg = new CanonicalBlockRegistry(ROLLUP, PROFILE, mockV, anchors, genesis);
        // A real L1 anchor: an L1 header whose hash this chain reports at its height.
        bytes memory l1 = _header(keccak256("l1-parent"), 5, "l1");
        vm.roll(10);
        vm.setBlockhash(5, keccak256(l1));
        anchorId = anchors.record(l1);
        proof = abi.encodePacked(mockV.MOCK_PROOF());
        bytes32[] memory blobs = new bytes32[](1);
        blobs[0] = bytes32(uint256(0x01) << 248 | 0xda);
        vm.blobhashes(blobs);
    }

    function test_extendsCanonicalChain() public {
        bytes memory b1 = _header(keccak256(genesis), 1, "a");
        bytes32 h1 = reg.submit(b1, anchorId, proof);
        assertEq(reg.head(), h1);
        assertTrue(reg.isAcceptedBlock(ROLLUP, h1));
        assertFalse(reg.isAcceptedBlock(keccak256("other rollup"), h1));
        assertEq(
            reg.acceptedBlock(ROLLUP, h1).receiptsRoot, keccak256(abi.encode("receipts", uint256(1), bytes32("a")))
        );
        assertEq(reg.acceptedBlock(ROLLUP, h1).executionProfileHash, PROFILE);
        assertEq(reg.profileKind(), ChannelTypes.PROFILE_MOCK_LOCAL);
        // Permissionless: anyone extends it.
        vm.prank(address(0xbeef));
        reg.submit(_header(h1, 2, "b"), anchorId, proof);
    }

    function test_competingForkRejected() public {
        reg.submit(_header(keccak256(genesis), 1, "a"), anchorId, proof);
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "not on the canonical tip"));
        reg.submit(_header(keccak256(genesis), 1, "competitor"), anchorId, proof);
    }

    function test_wrongParentOrNumberRejected() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "not on the canonical tip"));
        reg.submit(_header(keccak256("unknown"), 1, "a"), anchorId, proof);
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "number"));
        reg.submit(_header(keccak256(genesis), 2, "a"), anchorId, proof);
    }

    function test_unrecordedAnchorRejected() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "L1 anchor not recorded"));
        reg.submit(_header(keccak256(genesis), 1, "a"), keccak256("fake anchor"), proof);
    }

    function test_missingBlobRejected() public {
        vm.blobhashes(new bytes32[](0));
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "no blob: data not on L1"));
        reg.submit(_header(keccak256(genesis), 1, "a"), anchorId, proof);
    }

    function test_unverifiedTransitionRejected() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "transition not verified"));
        reg.submit(_header(keccak256(genesis), 1, "a"), anchorId, hex"00");
        CanonicalBlockRegistry strict =
            new CanonicalBlockRegistry(ROLLUP, PROFILE, new RejectingVerifier(), anchors, genesis);
        assertEq(strict.profileKind(), ChannelTypes.PROFILE_NATIVE_REEXECUTION_DEVNET);
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "transition not verified"));
        strict.submit(_header(keccak256(genesis), 1, "a"), anchorId, proof);
    }

    function test_genesisMustBeBlockZero() public {
        vm.expectRevert(abi.encodeWithSelector(CanonicalBlockRegistry.Rejected.selector, "genesis number"));
        new CanonicalBlockRegistry(ROLLUP, PROFILE, mockV, anchors, _header(bytes32(0), 1, "g"));
    }
}

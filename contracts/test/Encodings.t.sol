// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChannelTypes} from "../src/libraries/ChannelTypes.sol";
import {MockAcceptedBlockRegistry} from "../src/mocks/MockAcceptedBlockRegistry.sol";
import {IAcceptedBlockRegistry} from "../src/interfaces/IAcceptedBlockRegistry.sol";

contract Decoder {
    function decodeRequest(bytes calldata data) external pure returns (ChannelTypes.FinalRequest memory) {
        return ChannelTypes.decodeFinalRequest(data);
    }

    function decodeTerms(bytes calldata data) external pure returns (ChannelTypes.ChannelTerms memory) {
        return ChannelTypes.decodeTerms(data);
    }
}

/// Recomputes every commitment in fixtures/encodings/commitments.json (written by Rust).
contract EncodingsTest is Test {
    string json;
    Decoder dec;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/../fixtures/encodings/commitments.json"));
        dec = new Decoder();
    }

    function _b32(string memory k) internal view returns (bytes32) {
        return vm.parseJsonBytes32(json, k);
    }

    function _anchor() internal view returns (ChannelTypes.L1Anchor memory) {
        return ChannelTypes.L1Anchor({
            chainId: uint256(_b32(".anchor.chainId")),
            blockNumber: uint64(vm.parseJsonUint(json, ".anchor.blockNumber")),
            blockHash: _b32(".anchor.blockHash"),
            stateRoot: _b32(".anchor.stateRoot")
        });
    }

    function _terms() internal view returns (ChannelTypes.ChannelTerms memory) {
        return ChannelTypes.ChannelTerms({
            channelId: _b32(".terms.channelId"),
            rollupId: _b32(".terms.rollupId"),
            settlementContract: vm.parseJsonAddress(json, ".terms.settlementContract"),
            executor: vm.parseJsonAddress(json, ".terms.executor"),
            moduleCodeHash: _b32(".terms.moduleCodeHash"),
            participantRoot: _b32(".terms.participantRoot"),
            policyHash: _b32(".terms.policyHash"),
            closeDeadline: uint64(vm.parseJsonUint(json, ".terms.closeDeadline"))
        });
    }

    function _request() internal view returns (ChannelTypes.FinalRequest memory) {
        return ChannelTypes.FinalRequest({
            channelId: _b32(".request.channelId"),
            termsHash: _b32(".request.termsHash"),
            anchorId: _b32(".request.anchorId"),
            policyHash: _b32(".request.policyHash"),
            executionProfileHash: _b32(".request.executionProfileHash"),
            inputHash: _b32(".request.inputHash"),
            nonce: uint64(vm.parseJsonUint(json, ".request.nonce"))
        });
    }

    function _profile() internal view returns (ChannelTypes.ExecutionProfile memory) {
        return ChannelTypes.ExecutionProfile({
            rollupId: _b32(".profile.rollupId"),
            kind: uint8(vm.parseJsonUint(json, ".profile.kind")),
            genesisHash: _b32(".profile.genesisHash"),
            programHash: _b32(".profile.programHash"),
            forkSchemaHash: _b32(".profile.forkSchemaHash"),
            daSchemaHash: _b32(".profile.daSchemaHash"),
            executorCodeHash: _b32(".profile.executorCodeHash")
        });
    }

    function test_anchorMatchesRust() public view {
        ChannelTypes.L1Anchor memory a = _anchor();
        assertEq(abi.encode(a), vm.parseJsonBytes(json, ".anchor.encoded"));
        assertEq(ChannelTypes.anchorId(a), _b32(".anchor.id"));
    }

    function test_policyProfileTermsMatchRust() public view {
        ChannelTypes.ChannelPolicy memory p = ChannelTypes.ChannelPolicy({
            anchorConfirmation: uint8(vm.parseJsonUint(json, ".policy.anchorConfirmation")),
            maxAnchorLag: uint32(vm.parseJsonUint(json, ".policy.maxAnchorLag"))
        });
        assertEq(ChannelTypes.policyHash(p), _b32(".policy.hash"));
        assertEq(ChannelTypes.profileHash(_profile()), _b32(".profile.hash"));
        ChannelTypes.ChannelTerms memory t = _terms();
        assertEq(abi.encode(t), vm.parseJsonBytes(json, ".terms.encoded"));
        assertEq(ChannelTypes.termsHash(t), _b32(".terms.hash"));
    }

    function test_channelIdAndParticipantsMatchRust() public view {
        uint256 chainId = vm.parseJsonUint(json, ".l1ChainId");
        address settlement = vm.parseJsonAddress(json, ".settlement");
        bytes32 cid = ChannelTypes.channelId(chainId, settlement, vm.parseJsonAddress(json, ".opener"), _b32(".salt"));
        assertEq(cid, _b32(".channelId"));
        assertEq(
            ChannelTypes.participantRoot(vm.parseJsonAddressArray(json, ".participants")), _b32(".participantRoot")
        );
    }

    function test_requestMatchesRust() public view {
        ChannelTypes.FinalRequest memory r = _request();
        bytes memory enc = vm.parseJsonBytes(json, ".request.encoded");
        assertEq(abi.encode(r), enc);
        uint256 chainId = vm.parseJsonUint(json, ".l1ChainId");
        address settlement = vm.parseJsonAddress(json, ".settlement");
        assertEq(ChannelTypes.domainSeparator(chainId, settlement), _b32(".request.domainSeparator"));
        assertEq(ChannelTypes.requestSigningHash(r, chainId, settlement), _b32(".request.signingHash"));
        ChannelTypes.FinalRequest memory d = dec.decodeRequest(enc);
        assertEq(ChannelTypes.requestStructHash(d), ChannelTypes.requestStructHash(r));
    }

    function test_malformedRequestsRejected() public {
        string[3] memory keys =
            [".malformedRequests.truncated", ".malformedRequests.trailingByte", ".malformedRequests.dirtyNoncePadding"];
        for (uint256 i; i < keys.length; ++i) {
            bytes memory bad = vm.parseJsonBytes(json, keys[i]);
            (bool ok,) = address(dec).call(abi.encodeCall(Decoder.decodeRequest, (bad)));
            assertFalse(ok, keys[i]);
        }
    }

    function test_dirtyAddressPaddingRejected() public {
        bytes memory enc = vm.parseJsonBytes(json, ".terms.encoded");
        enc[64] = 0xff;
        (bool ok,) = address(dec).call(abi.encodeCall(Decoder.decodeTerms, (enc)));
        assertFalse(ok);
    }

    function test_unknownProfileKindRejected() public {
        ChannelTypes.ExecutionProfile memory p = _profile();
        p.kind = 3;
        vm.expectRevert(abi.encodeWithSelector(ChannelTypes.UnknownProfileKind.selector, uint8(3)));
        this.hashProfile(p);
    }

    function hashProfile(ChannelTypes.ExecutionProfile memory p) external pure returns (bytes32) {
        return ChannelTypes.profileHash(p);
    }

    function test_participantsMustBeCanonical() public {
        address[] memory ps = new address[](2);
        ps[0] = address(0xa11ce);
        ps[1] = address(0xb0b);
        vm.expectRevert(ChannelTypes.BadParticipants.selector);
        this.root(ps);
        ps[1] = address(0xa11ce);
        vm.expectRevert(ChannelTypes.BadParticipants.selector);
        this.root(ps);
    }

    function root(address[] memory ps) external pure returns (bytes32) {
        return ChannelTypes.participantRoot(ps);
    }

    function test_mockRegistryIsLabeledMock() public {
        MockAcceptedBlockRegistry reg = new MockAcceptedBlockRegistry(address(this));
        assertEq(reg.profileKind(), ChannelTypes.PROFILE_MOCK_LOCAL);
        IAcceptedBlockRegistry.AcceptedBlock memory b;
        reg.mockAccept(bytes32("r"), bytes32("h"), b);
        assertTrue(reg.isAcceptedBlock(bytes32("r"), bytes32("h")));
        vm.prank(address(0xbad));
        vm.expectRevert(MockAcceptedBlockRegistry.NotOperator.selector);
        reg.mockAccept(bytes32("r"), bytes32("h2"), b);
    }

    function testFuzz_signingHashSeparatesDomains(uint256 chainA, uint256 chainB, address s) public view {
        vm.assume(chainA != chainB);
        ChannelTypes.FinalRequest memory r = _request();
        assertTrue(ChannelTypes.requestSigningHash(r, chainA, s) != ChannelTypes.requestSigningHash(r, chainB, s));
    }
}

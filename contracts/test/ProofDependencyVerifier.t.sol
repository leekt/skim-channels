// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProofDependencyVerifier, IDependencySource} from "../src/verifiers/ProofDependencyVerifier.sol";
import {IStateTransitionVerifier} from "../src/interfaces/IStateTransitionVerifier.sol";

/// TEST STUB of the EIP-8357 registry call convention (no network has the real one with a
/// real key; see the contract's notes).
contract RegistryStub {
    bytes32 public vk;
    uint16 public schema;

    function set(bytes32 v, uint16 s) external {
        (vk, schema) = (v, s);
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        require(data.length == 32 && bytes32(data) == 0 && vk != 0, "unregistered");
        return abi.encodePacked(vk, bytes32(uint256(schema)));
    }
}

/// TEST STUB dependency source: attests exactly one (scheme, dataHash, vk).
contract SourceStub is IDependencySource {
    bytes32 public key;

    function attest(uint8 s, bytes32 d, bytes32 v) external {
        key = keccak256(abi.encode(s, d, v));
    }

    function verified(uint8 s, bytes32 d, bytes32 v) external view returns (bool) {
        return key == keccak256(abi.encode(s, d, v));
    }
}

contract ProofDependencyVerifierTest is Test {
    ProofDependencyVerifier v;
    SourceStub src;
    IStateTransitionVerifier.Transition t;

    function setUp() public {
        vm.etch(0x00005e9c1447C1A05A642ec9eB76D9C125468357, type(RegistryStub).runtimeCode);
        RegistryStub(payable(0x00005e9c1447C1A05A642ec9eB76D9C125468357)).set(keccak256("vk"), 0x1501);
        src = new SourceStub();
        v = new ProofDependencyVerifier(src, 0x1501);
        t = IStateTransitionVerifier.Transition(keccak256("p"), keccak256("s"), keccak256("da"), 0, 0, hex"c0");
    }

    function test_acceptsOnlyAnAttestationOfThisTransitionUnderTheRegisteredKey() public {
        assertEq(v.profileKind(), 2);
        assertFalse(v.verify(t, ""), "nothing attested");
        src.attest(0x11, v.publicInput(t), keccak256("vk"));
        assertTrue(v.verify(t, ""));
        // Any other transition input changes the public input.
        IStateTransitionVerifier.Transition memory u = t;
        u.l1MessagesRoot = keccak256("other messages");
        assertFalse(v.verify(u, ""));
        // A rotated key in the registry invalidates attestations under the old one.
        RegistryStub(payable(0x00005e9c1447C1A05A642ec9eB76D9C125468357)).set(keccak256("vk2"), 0x1501);
        assertFalse(v.verify(t, ""));
        // Another schema than the profile's.
        RegistryStub(payable(0x00005e9c1447C1A05A642ec9eB76D9C125468357)).set(keccak256("vk"), 0x1600);
        assertFalse(v.verify(t, ""));
    }

    function test_noRegistryNoAcceptance() public {
        vm.etch(0x00005e9c1447C1A05A642ec9eB76D9C125468357, "");
        src.attest(0x11, v.publicInput(t), keccak256("vk"));
        assertFalse(v.verify(t, ""));
    }
}

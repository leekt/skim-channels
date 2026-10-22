// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ChannelTypes} from "./ChannelTypes.sol";
import {MerklePatricia} from "./MerklePatricia.sol";
import {EthTypes} from "./EthTypes.sol";

/// @notice Solidity twin of crates/channel-witness `verify`: a WitnessPackage is accepted only
///         if every account and slot is proven (present or absent) against the one state root
///         of its anchor, in canonical order and within bounds. Checked against
///         fixtures/witnesses/read-and-split.json.
library WitnessLib {
    struct AccountWitness {
        address account;
        bool exists;
        uint64 nonce;
        uint256 balance;
        bytes32 storageRoot;
        bytes32 codeHash;
        bytes code;
        bytes[] proof;
    }

    struct StorageWitness {
        address account;
        bytes32 slot;
        uint256 value;
        bytes[] proof;
    }

    struct WitnessPackage {
        ChannelTypes.L1Anchor anchor;
        AccountWitness[] accounts;
        StorageWitness[] slots;
    }

    /// @notice A verified storage read.
    struct Read {
        address account;
        bytes32 slot;
        uint256 value;
    }

    uint256 internal constant MAX_ACCOUNTS = 256;
    uint256 internal constant MAX_SLOTS = 1024;
    bytes32 internal constant KECCAK_EMPTY = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    error NonCanonicalPackage();
    error PackageTooLarge();
    error BadAccountProof(address account);
    error BadStorageProof(address account, bytes32 slot);
    error StorageWithoutAccount(address account);
    error CodeMismatch(address account);

    function decode(bytes calldata data) internal pure returns (WitnessPackage memory p) {
        p = abi.decode(data, (WitnessPackage));
        if (keccak256(abi.encode(p)) != keccak256(data)) revert NonCanonicalPackage();
    }

    function verify(WitnessPackage memory p) internal pure returns (Read[] memory reads) {
        if (p.accounts.length > MAX_ACCOUNTS || p.slots.length > MAX_SLOTS) revert PackageTooLarge();
        bytes32 stateRoot = p.anchor.stateRoot;
        for (uint256 i; i < p.accounts.length; ++i) {
            AccountWitness memory w = p.accounts[i];
            if (i > 0 && p.accounts[i - 1].account >= w.account) revert NonCanonicalPackage();
            (bool found, bytes memory leaf) =
                MerklePatricia.get(stateRoot, abi.encodePacked(keccak256(abi.encodePacked(w.account))), w.proof);
            if (w.exists) {
                if (!found) revert BadAccountProof(w.account);
                EthTypes.Account memory acct = EthTypes.decodeAccount(leaf);
                if (
                    acct.nonce != w.nonce || acct.balance != w.balance || acct.storageRoot != w.storageRoot
                        || acct.codeHash != w.codeHash
                ) {
                    revert BadAccountProof(w.account);
                }
                if ((w.code.length != 0 || w.codeHash == KECCAK_EMPTY) && keccak256(w.code) != w.codeHash) {
                    revert CodeMismatch(w.account);
                }
            } else {
                if (found) revert BadAccountProof(w.account);
                if (w.nonce != 0 || w.balance != 0 || w.storageRoot != 0 || w.codeHash != 0 || w.code.length != 0) {
                    revert BadAccountProof(w.account);
                }
            }
        }
        reads = new Read[](p.slots.length);
        uint256 a;
        for (uint256 i; i < p.slots.length; ++i) {
            StorageWitness memory s = p.slots[i];
            if (i > 0) {
                StorageWitness memory prev = p.slots[i - 1];
                if (prev.account > s.account || (prev.account == s.account && prev.slot >= s.slot)) {
                    revert NonCanonicalPackage();
                }
            }
            // Both lists are sorted by account: advance to this slot's account.
            while (a < p.accounts.length && p.accounts[a].account < s.account) a++;
            if (a == p.accounts.length || p.accounts[a].account != s.account) revert StorageWithoutAccount(s.account);
            AccountWitness memory w = p.accounts[a];
            bytes32 sroot = w.exists ? w.storageRoot : MerklePatricia.EMPTY_ROOT;
            if (sroot == MerklePatricia.EMPTY_ROOT) {
                if (s.value != 0 || s.proof.length != 0) revert BadStorageProof(s.account, s.slot);
            } else {
                (bool found, bytes memory leaf) =
                    MerklePatricia.get(sroot, abi.encodePacked(keccak256(abi.encodePacked(s.slot))), s.proof);
                if (s.value == 0 ? found : (!found || EthTypes.decodeSlotValue(leaf) != s.value)) {
                    revert BadStorageProof(s.account, s.slot);
                }
            }
            reads[i] = Read(s.account, s.slot, s.value);
        }
    }

    /// @notice The verified value of (account, slot); reverts if the package didn't cover it.
    function find(Read[] memory reads, address account, bytes32 slot) internal pure returns (uint256) {
        for (uint256 i; i < reads.length; ++i) {
            if (reads[i].account == account && reads[i].slot == slot) return reads[i].value;
        }
        revert NotWitnessed(account, slot);
    }

    error NotWitnessed(address account, bytes32 slot);
}

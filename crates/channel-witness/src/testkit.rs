//! Synthetic L1 state with real Merkle-Patricia proofs, for tests (feature `testkit`).
//! [`MockState`] holds accounts and storage, computes the state root, and emits
//! [`WitnessPackage`]s for any read set, exactly as an honest `eth_getProof` would.

use std::collections::BTreeMap;

use alloy_consensus::Header;
use alloy_primitives::{Address, B256, Bytes, U256, keccak256};
use alloy_trie::{
    EMPTY_ROOT_HASH, HashBuilder, KECCAK_EMPTY, Nibbles, TrieAccount, proof::ProofRetainer,
};
use channel_types::L1Anchor;

use crate::{AccountWitness, StorageWitness, WitnessPackage};

#[derive(Debug, Clone, Default)]
pub struct MockAccount {
    pub nonce: u64,
    pub balance: U256,
    pub code: Bytes,
    pub storage: BTreeMap<B256, U256>,
}

#[derive(Debug, Clone, Default)]
pub struct MockState {
    pub accounts: BTreeMap<Address, MockAccount>,
}

/// (root, proof for each target) of a trie over hashed keys.
fn trie(leaves: Vec<(B256, Vec<u8>)>, targets: &[B256]) -> (B256, Vec<Vec<Bytes>>) {
    let mut leaves = leaves;
    leaves.sort_by_key(|a| a.0);
    let ts: Vec<Nibbles> = targets.iter().map(|t| Nibbles::unpack(t)).collect();
    let mut hb = HashBuilder::default().with_proof_retainer(ProofRetainer::new(ts.clone()));
    for (k, v) in &leaves {
        hb.add_leaf(Nibbles::unpack(k), v);
    }
    let root = hb.root();
    let nodes = hb.take_proof_nodes().into_nodes_sorted();
    let proofs = ts
        .iter()
        .map(|t| {
            nodes
                .iter()
                .filter(|(p, _)| t.starts_with(p))
                .map(|(_, n)| n.clone())
                .collect()
        })
        .collect();
    (root, proofs)
}

impl MockState {
    pub fn set_storage(&mut self, a: Address, slot: B256, v: U256) -> &mut Self {
        let s = &mut self
            .accounts
            .entry(a)
            .or_insert_with(|| MockAccount {
                nonce: 1,
                ..Default::default()
            })
            .storage;
        if v.is_zero() {
            s.remove(&slot);
        } else {
            s.insert(slot, v);
        }
        self
    }

    fn storage_trie(acct: &MockAccount, targets: &[B256]) -> (B256, Vec<Vec<Bytes>>) {
        if acct.storage.is_empty() {
            return (
                EMPTY_ROOT_HASH,
                targets.iter().map(|_| Vec::new()).collect(),
            );
        }
        let leaves = acct
            .storage
            .iter()
            .map(|(k, v)| (keccak256(k), alloy_rlp::encode(v)))
            .collect();
        let hashed: Vec<B256> = targets.iter().map(keccak256).collect();
        trie(leaves, &hashed)
    }

    pub fn trie_account(acct: &MockAccount) -> TrieAccount {
        TrieAccount {
            nonce: acct.nonce,
            balance: acct.balance,
            storage_root: Self::storage_trie(acct, &[]).0,
            code_hash: if acct.code.is_empty() {
                KECCAK_EMPTY
            } else {
                keccak256(&acct.code)
            },
        }
    }

    fn account_leaves(&self) -> Vec<(B256, Vec<u8>)> {
        self.accounts
            .iter()
            .map(|(a, acct)| (keccak256(a), alloy_rlp::encode(Self::trie_account(acct))))
            .collect()
    }

    pub fn state_root(&self) -> B256 {
        trie(self.account_leaves(), &[]).0
    }

    /// A header at `number` over this state, and its anchor.
    pub fn header(&self, chain_id: u64, number: u64, parent: B256) -> (Bytes, L1Anchor) {
        let h = Header {
            number,
            parent_hash: parent,
            state_root: self.state_root(),
            gas_limit: 30_000_000,
            timestamp: 1_700_000_000 + number * 12,
            ..Default::default()
        };
        let raw = Bytes::from(alloy_rlp::encode(&h));
        let anchor = L1Anchor {
            chainId: U256::from(chain_id),
            blockNumber: number,
            blockHash: keccak256(&raw),
            stateRoot: h.state_root,
        };
        (raw, anchor)
    }

    /// The witness package for `reads` (account → slots; `with_code` includes code).
    pub fn package(
        &self,
        anchor: &L1Anchor,
        reads: &BTreeMap<Address, (Vec<B256>, bool)>,
    ) -> WitnessPackage {
        assert_eq!(
            anchor.stateRoot,
            self.state_root(),
            "anchor is for another state"
        );
        let targets: Vec<B256> = reads.keys().map(keccak256).collect();
        let (_, proofs) = trie(self.account_leaves(), &targets);
        let mut accounts = Vec::new();
        let mut storage = Vec::new();
        for ((addr, (slots, with_code)), proof) in reads.iter().zip(proofs) {
            match self.accounts.get(addr) {
                None => {
                    accounts.push(AccountWitness {
                        account: *addr,
                        exists: false,
                        nonce: 0,
                        balance: U256::ZERO,
                        storageRoot: B256::ZERO,
                        codeHash: B256::ZERO,
                        code: Bytes::new(),
                        proof,
                    });
                    for s in slots {
                        storage.push(StorageWitness {
                            account: *addr,
                            slot: *s,
                            value: U256::ZERO,
                            proof: Vec::new(),
                        });
                    }
                }
                Some(acct) => {
                    let ta = Self::trie_account(acct);
                    accounts.push(AccountWitness {
                        account: *addr,
                        exists: true,
                        nonce: ta.nonce,
                        balance: ta.balance,
                        storageRoot: ta.storage_root,
                        codeHash: ta.code_hash,
                        code: if *with_code {
                            acct.code.clone()
                        } else {
                            Bytes::new()
                        },
                        proof,
                    });
                    let mut sorted = slots.clone();
                    sorted.sort();
                    let (_, sproofs) = Self::storage_trie(acct, &sorted);
                    for (s, p) in sorted.iter().zip(sproofs) {
                        let value = acct.storage.get(s).copied().unwrap_or_default();
                        storage.push(StorageWitness {
                            account: *addr,
                            slot: *s,
                            value,
                            proof: p,
                        });
                    }
                }
            }
        }
        WitnessPackage {
            anchor: anchor.clone(),
            accounts,
            slots: storage,
        }
    }
}

/// Read set helper: `[(address, [slots], with_code)]`.
pub fn reads(items: &[(Address, &[B256], bool)]) -> BTreeMap<Address, (Vec<B256>, bool)> {
    items
        .iter()
        .map(|(a, s, c)| (*a, (s.to_vec(), *c)))
        .collect()
}

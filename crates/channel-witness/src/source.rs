//! Witness collection from skim over JSON-RPC (PROJECT.md §10 "Integration strategy").
//!
//! skim's `eth_getProof` already assembles EIP-1186 proofs from SNAP and verifies them
//! (`skim_snap::el::ElTransport::get_proof`); this module doesn't fetch state itself. It asks
//! skim at the anchor's exact block hash (EIP-1898) and re-verifies every answer against the
//! *authenticated* anchor before a package exists. A wrong, stale or partial answer (from any
//! endpoint, skim or not) is an error, never a value. No other RPC is used as a fallback.

use std::collections::BTreeMap;

use alloy_primitives::{Address, B256, Bytes, U64, U256, keccak256};
use alloy_trie::{EMPTY_ROOT_HASH, KECCAK_EMPTY, Nibbles, TrieAccount, proof::verify_proof};
use channel_types::L1Anchor;
use serde::Deserialize;
use serde_json::json;

use crate::{AccountWitness, StorageWitness, WitnessError, WitnessPackage, verify};

/// An `eth_getProof` answer (EIP-1186).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProofResponse {
    pub address: Address,
    pub account_proof: Vec<Bytes>,
    pub balance: U256,
    pub code_hash: B256,
    pub nonce: U64,
    pub storage_hash: B256,
    pub storage_proof: Vec<StorageProofResponse>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StorageProofResponse {
    pub key: U256,
    pub value: U256,
    pub proof: Vec<Bytes>,
}

#[derive(Debug, thiserror::Error)]
pub enum SourceError {
    #[error("transport: {0}")]
    Transport(String),
    #[error("rpc error {code}: {message}")]
    Rpc {
        code: i64,
        message: String,
        data: Option<serde_json::Value>,
    },
    #[error("answer does not match the request: {0}")]
    Mismatch(&'static str),
    #[error("answer does not verify against the anchor: {0}")]
    Unverifiable(#[from] WitnessError),
}

/// Where proofs come from. Implementations need not be trusted: [`collect_witness`] verifies.
pub trait ProofSource {
    fn get_proof(
        &self,
        address: Address,
        slots: &[B256],
        block_hash: B256,
    ) -> Result<ProofResponse, SourceError>;
    fn get_code(&self, address: Address, block_hash: B256) -> Result<Bytes, SourceError>;
}

/// skim's JSON-RPC endpoint (`skim run --rpc`, default `http://127.0.0.1:8545`).
pub struct SkimRpc {
    url: String,
    agent: ureq::Agent,
}

impl SkimRpc {
    pub fn new(url: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            agent: ureq::AgentBuilder::new()
                .timeout(std::time::Duration::from_secs(30))
                .build(),
        }
    }

    fn call<T: serde::de::DeserializeOwned>(
        &self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<T, SourceError> {
        let body = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
        let resp: serde_json::Value = self
            .agent
            .post(&self.url)
            .send_json(body)
            .map_err(|e| SourceError::Transport(e.to_string()))?
            .into_json()
            .map_err(|e| SourceError::Transport(e.to_string()))?;
        if let Some(err) = resp.get("error") {
            return Err(SourceError::Rpc {
                code: err["code"].as_i64().unwrap_or(0),
                message: err["message"].as_str().unwrap_or_default().to_string(),
                data: err.get("data").cloned(),
            });
        }
        serde_json::from_value(resp["result"].clone())
            .map_err(|e| SourceError::Transport(format!("bad result: {e}")))
    }
}

impl ProofSource for SkimRpc {
    fn get_proof(
        &self,
        address: Address,
        slots: &[B256],
        block_hash: B256,
    ) -> Result<ProofResponse, SourceError> {
        self.call(
            "eth_getProof",
            json!([address, slots, {"blockHash": block_hash, "requireCanonical": true}]),
        )
    }

    fn get_code(&self, address: Address, block_hash: B256) -> Result<Bytes, SourceError> {
        self.call(
            "eth_getCode",
            json!([address, {"blockHash": block_hash, "requireCanonical": true}]),
        )
    }
}

/// Fetches and verifies the witness for `reads` (account → (slots, needs code)) at `anchor`,
/// which must already be authenticated (from [`crate::anchor::AnchorBook`]).
pub fn collect_witness(
    src: &impl ProofSource,
    anchor: &L1Anchor,
    reads: &BTreeMap<Address, (Vec<B256>, bool)>,
) -> Result<WitnessPackage, SourceError> {
    let mut accounts = Vec::with_capacity(reads.len());
    let mut storage = Vec::new();
    for (addr, (slots, with_code)) in reads {
        let mut slots = slots.clone();
        slots.sort();
        slots.dedup();
        let r = src.get_proof(*addr, &slots, anchor.blockHash)?;
        if r.address != *addr {
            return Err(SourceError::Mismatch("address"));
        }
        if r.storage_proof.len() != slots.len() {
            return Err(SourceError::Mismatch("storage proof count"));
        }
        let exists = account_exists(anchor.stateRoot, &r)?;
        let code = match (exists, with_code) {
            (true, true) if r.code_hash != KECCAK_EMPTY => src.get_code(*addr, anchor.blockHash)?,
            _ => Bytes::new(),
        };
        accounts.push(if exists {
            AccountWitness {
                account: *addr,
                exists,
                nonce: r.nonce.to(),
                balance: r.balance,
                storageRoot: r.storage_hash,
                codeHash: r.code_hash,
                code,
                proof: r.account_proof.clone(),
            }
        } else {
            AccountWitness {
                account: *addr,
                exists,
                nonce: 0,
                balance: U256::ZERO,
                storageRoot: B256::ZERO,
                codeHash: B256::ZERO,
                code: Bytes::new(),
                proof: r.account_proof.clone(),
            }
        });
        let empty_trie = !exists || r.storage_hash == EMPTY_ROOT_HASH;
        for (slot, sp) in slots.iter().zip(&r.storage_proof) {
            if B256::from(sp.key) != *slot {
                return Err(SourceError::Mismatch("storage key"));
            }
            // In an empty trie the account proof settles the slot; keep the package canonical.
            let proof = if empty_trie {
                Vec::new()
            } else {
                sp.proof.clone()
            };
            storage.push(StorageWitness {
                account: *addr,
                slot: *slot,
                value: sp.value,
                proof,
            });
        }
    }
    let pkg = WitnessPackage {
        anchor: anchor.clone(),
        accounts,
        slots: storage,
    };
    verify(&pkg, anchor)?;
    Ok(pkg)
}

/// Decides presence from the proof itself, not from the answer's fields: the account is
/// present only if the proof includes exactly these fields, absent only if it proves
/// exclusion (and then the fields must be empty).
fn account_exists(state_root: B256, r: &ProofResponse) -> Result<bool, SourceError> {
    let key = Nibbles::unpack(keccak256(r.address));
    let acct = TrieAccount {
        nonce: r.nonce.to(),
        balance: r.balance,
        storage_root: r.storage_hash,
        code_hash: r.code_hash,
    };
    if verify_proof(
        state_root,
        key,
        Some(alloy_rlp::encode(acct)),
        &r.account_proof,
    )
    .is_ok()
    {
        return Ok(true);
    }
    if verify_proof(state_root, key, None, &r.account_proof).is_ok() {
        let empty = r.nonce.is_zero()
            && r.balance.is_zero()
            && (r.storage_hash.is_zero() || r.storage_hash == EMPTY_ROOT_HASH)
            && (r.code_hash.is_zero() || r.code_hash == KECCAK_EMPTY)
            && r.storage_proof.iter().all(|s| s.value.is_zero());
        return if empty {
            Ok(false)
        } else {
            Err(SourceError::Mismatch("absent account with nonzero fields"))
        };
    }
    Err(WitnessError::BadAccountProof(r.address).into())
}

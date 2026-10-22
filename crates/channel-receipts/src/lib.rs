//! Receipt inclusion (PROJECT.md §7): the settlement path proves a `ChannelOutcome` log
//! against an accepted L2 block's `receiptsRoot`.
//!
//! - Trie key: `RLP(transactionIndex)`, unhashed. Leaf value: the receipt's consensus
//!   encoding, EIP-2718 type byte included for typed receipts (a JSON-RPC receipt object is
//!   not this encoding).
//! - [`receipts_root`] / [`receipt_proof`] build from all of a block's encoded receipts;
//!   [`verify_receipt`] checks one receipt at one index against a root.
//! - [`decode_receipt`] is strict: unknown types and non-canonical encodings are rejected.
//!
//! This is necessary but not sufficient for settlement: the root must come from a header
//! whose hash an accepted-block registry vouches for (§6, §7.4).

use alloy_consensus::{Header, ReceiptEnvelope};
use alloy_eips::eip2718::{Decodable2718, Encodable2718};
use alloy_primitives::{B256, Bytes, Log, keccak256};
use alloy_rlp::Decodable;
use alloy_trie::{HashBuilder, Nibbles, proof::ProofRetainer, proof::verify_proof};

pub mod fixtures;

pub const MAX_RECEIPT_PROOF_NODES: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ReceiptError {
    #[error("receipt proof does not verify against the receipts root")]
    BadProof,
    #[error("proof exceeds bounds")]
    TooLarge,
    #[error("malformed receipt: {0}")]
    Malformed(String),
    #[error("malformed header: {0}")]
    BadHeader(String),
    #[error("index {0} out of range")]
    Index(usize),
}

/// The trie key for a transaction index.
pub fn index_key(index: usize) -> Vec<u8> {
    alloy_rlp::encode(index)
}

fn sorted_leaves(encoded: &[Bytes]) -> Vec<(Nibbles, &Bytes)> {
    let mut leaves: Vec<(Nibbles, &Bytes)> = encoded
        .iter()
        .enumerate()
        .map(|(i, r)| (Nibbles::unpack(index_key(i)), r))
        .collect();
    leaves.sort_by_key(|a| a.0);
    leaves
}

pub fn receipts_root(encoded: &[Bytes]) -> B256 {
    let mut hb = HashBuilder::default();
    for (k, v) in sorted_leaves(encoded) {
        hb.add_leaf(k, v);
    }
    hb.root()
}

/// The ordered proof path (root first) for receipt `index`.
pub fn receipt_proof(encoded: &[Bytes], index: usize) -> Result<Vec<Bytes>, ReceiptError> {
    if index >= encoded.len() {
        return Err(ReceiptError::Index(index));
    }
    let target = Nibbles::unpack(index_key(index));
    let mut hb = HashBuilder::default().with_proof_retainer(ProofRetainer::new(vec![target]));
    for (k, v) in sorted_leaves(encoded) {
        hb.add_leaf(k, v);
    }
    hb.root();
    Ok(hb
        .take_proof_nodes()
        .into_nodes_sorted()
        .into_iter()
        .filter(|(p, _)| target.starts_with(p))
        .map(|(_, n)| n)
        .collect())
}

pub fn verify_receipt(
    root: B256,
    index: usize,
    encoded_receipt: &[u8],
    proof: &[Bytes],
) -> Result<(), ReceiptError> {
    if proof.len() > MAX_RECEIPT_PROOF_NODES {
        return Err(ReceiptError::TooLarge);
    }
    verify_proof(
        root,
        Nibbles::unpack(index_key(index)),
        Some(encoded_receipt.to_vec()),
        proof,
    )
    .map_err(|_| ReceiptError::BadProof)
}

/// Decodes a consensus-encoded receipt; must re-encode to the same bytes.
pub fn decode_receipt(encoded: &[u8]) -> Result<ReceiptEnvelope, ReceiptError> {
    let r = ReceiptEnvelope::decode_2718(&mut &encoded[..])
        .map_err(|e| ReceiptError::Malformed(e.to_string()))?;
    if r.encoded_2718() != encoded {
        return Err(ReceiptError::Malformed("non-canonical encoding".into()));
    }
    Ok(r)
}

/// Successful execution (EIP-658 status).
pub fn succeeded(r: &ReceiptEnvelope) -> bool {
    r.status()
}

pub fn logs(r: &ReceiptEnvelope) -> &[Log] {
    r.logs()
}

/// Decodes a raw header strictly and returns (hash, header).
pub fn decode_header(raw: &[u8]) -> Result<(B256, Header), ReceiptError> {
    let h = Header::decode(&mut &raw[..]).map_err(|e| ReceiptError::BadHeader(e.to_string()))?;
    if alloy_rlp::encode(&h) != raw {
        return Err(ReceiptError::BadHeader("non-canonical encoding".into()));
    }
    Ok((keccak256(raw), h))
}

#[cfg(test)]
mod tests;

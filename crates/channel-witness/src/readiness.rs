//! `stateReady` versus `proofReady` (PROJECT.md §4).
//!
//! skim can know a value at block N+2 (a SNAP proof at N, then BAL writes for N+1 and N+2)
//! without any proof at N+2's root. Such a value is fine for previews and UI, but it is not
//! a witness: an execution needs [`AnchorBook::proof_ready`]. [`readiness`] reports both, so
//! a runtime can show "value known, proof pending" instead of silently using the value.

use alloy_primitives::{Address, B256, U256};

use crate::{
    ReadKey,
    anchor::{AnchorBook, AnchorError},
};

/// Where a locally held value came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provenance {
    /// Proven against this state root.
    Proven { state_root: B256 },
    /// Proven at `proven_at`, then kept current by applying BAL writes through `through_block`.
    /// Correct (BALs are committed in headers) but carries no proof at the newer root.
    BalDerived {
        proven_at: B256,
        through_block: B256,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CachedValue {
    pub value: U256,
    pub provenance: Provenance,
}

/// A local value store (skim's versioned state, or a cache of its RPC answers).
pub trait LocalState {
    fn storage_at(&self, block_hash: B256, account: Address, slot: B256) -> Option<CachedValue>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Readiness {
    /// Every storage key has a known value at this block.
    pub state_ready: bool,
    /// A verified witness at this exact anchor covers every key.
    pub proof_ready: bool,
    /// Why `proof_ready` is false, when it is.
    pub proof_error: Option<AnchorError>,
}

pub fn readiness(
    book: &AnchorBook,
    local: &impl LocalState,
    anchor_id: B256,
    keys: &[ReadKey],
) -> Result<Readiness, AnchorError> {
    let block_hash = book
        .block_hash_of(anchor_id)
        .ok_or(AnchorError::Unknown(anchor_id))?;
    let state_ready = keys.iter().all(|k| match k {
        ReadKey::Storage(a, s) => local.storage_at(block_hash, *a, *s).is_some(),
        // Account/code values are not tracked by this view; only proofs can satisfy them.
        ReadKey::Account(_) | ReadKey::Code(_) => false,
    });
    let proof = book.proof_ready(anchor_id, keys);
    Ok(Readiness {
        state_ready,
        proof_ready: proof.is_ok(),
        proof_error: proof.err(),
    })
}

//! Recovery from L1 data alone (experiment 1): replay every accepted checkpoint's published
//! net diff, in nonce order, and check the result against the vault's accepted roots. The
//! inputs are what any L1 node has: `CheckpointAccepted` events and their transactions'
//! calldata (`submitCheckpoint(id, claim, data, proof)`). No operator, prover or skim needed.

use alloy_primitives::{Address, B256, U256, keccak256};
use alloy_sol_types::SolCall;
use serde::Serialize;

use crate::{AppError, LeafProof, Ledger, submitCheckpointCall};

/// One accepted checkpoint as found on L1.
pub struct Accepted {
    pub nonce: u64,
    /// `CheckpointAccepted.dataHash`
    pub data_hash: B256,
    /// The submitting transaction's input.
    pub calldata: Vec<u8>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Recovered {
    pub nonce: u64,
    pub exit_root: B256,
    pub credit_root: B256,
    pub deposit_cursor: u64,
    pub exits: Vec<LeafProof>,
    pub credits: Vec<LeafProof>,
}

#[derive(Debug, thiserror::Error)]
pub enum RecoverError {
    #[error("checkpoint {0}: calldata is not submitCheckpoint for this channel")]
    NotACheckpoint(u64),
    #[error("checkpoint {0}: published data doesn't hash to the accepted dataHash")]
    DataHash(u64),
    #[error("checkpoints are not consecutive from 1 (got nonce {0})")]
    Gap(u64),
    #[error("replayed {what} root {got} differs from the accepted {want}")]
    Root {
        what: &'static str,
        got: B256,
        want: B256,
    },
    #[error(transparent)]
    App(#[from] AppError),
}

/// Rebuilds the ledger from `checkpoints` (any order) and checks it against the vault's
/// accepted `(exitRoot, creditRoot)`.
pub fn recover(
    channel: B256,
    mut checkpoints: Vec<Accepted>,
    accepted_exit_root: B256,
    accepted_credit_root: B256,
) -> Result<(Ledger, Recovered), RecoverError> {
    checkpoints.sort_by_key(|c| c.nonce);
    let mut ledger = Ledger::default();
    for (i, cp) in checkpoints.iter().enumerate() {
        if cp.nonce != i as u64 + 1 {
            return Err(RecoverError::Gap(cp.nonce));
        }
        let call = submitCheckpointCall::abi_decode(&cp.calldata)
            .map_err(|_| RecoverError::NotACheckpoint(cp.nonce))?;
        if call.id != channel {
            return Err(RecoverError::NotACheckpoint(cp.nonce));
        }
        if keccak256(&call.data) != cp.data_hash {
            return Err(RecoverError::DataHash(cp.nonce));
        }
        ledger.apply_published(
            &call.data,
            call.claim.depositCursor,
            call.claim.forcedCursor,
        )?;
        let c = ledger.claim(call.claim.terminal);
        if c.exitRoot != call.claim.exitRoot {
            return Err(RecoverError::Root {
                what: "exit",
                got: c.exitRoot,
                want: call.claim.exitRoot,
            });
        }
        if c.creditRoot != call.claim.creditRoot {
            return Err(RecoverError::Root {
                what: "credit",
                got: c.creditRoot,
                want: call.claim.creditRoot,
            });
        }
    }
    let exit_root = ledger.balances.root(true);
    let credit_root = ledger.credits.root(false);
    if exit_root != accepted_exit_root {
        return Err(RecoverError::Root {
            what: "final exit",
            got: exit_root,
            want: accepted_exit_root,
        });
    }
    if credit_root != accepted_credit_root {
        return Err(RecoverError::Root {
            what: "final credit",
            got: credit_root,
            want: accepted_credit_root,
        });
    }
    let proofs = |exits: bool| -> Vec<LeafProof> {
        let t = if exits {
            &ledger.balances
        } else {
            &ledger.credits
        };
        t.sorted()
            .iter()
            .filter_map(|e| t.proof(exits, e.recipient, e.token))
            .collect()
    };
    let out = Recovered {
        nonce: checkpoints.len() as u64,
        exit_root,
        credit_root,
        deposit_cursor: ledger.deposit_cursor,
        exits: proofs(true),
        credits: proofs(false),
    };
    Ok((ledger, out))
}

/// Total value per token in a recovered table (for accounting checks).
pub fn total(entries: &[LeafProof], token: Address) -> U256 {
    entries
        .iter()
        .filter(|e| e.token == token)
        .map(|e| e.value)
        .sum()
}

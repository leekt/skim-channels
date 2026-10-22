//! Anchor lifecycle (PROJECT.md §3.2, §3.3, §4 "Witness lifecycle"):
//!
//! observe header → (attach verified witnesses) → confirmed at the policy → executable
//!
//! - Anchors come only from headers: [`AnchorBook::observe`] takes the raw RLP header and
//!   derives number, hash (keccak of the bytes) and state root itself. Nobody can hand the
//!   book a state root that isn't in a header it hashed.
//! - Confirmation evidence comes from a [`ConfirmationSource`] (skim's light-client
//!   authenticated `safe` / `finalized`). An anchor is executable only if the confirmed head
//!   links back to it through headers the book holds; an unknown link fails closed.
//! - `Latest` is optimistic and needs [`Mode::OptimisticExperiment`]. `Safe` is never taken
//!   as `FcrConfirmed`, and `FcrConfirmed` is refused until a real evidence source exists.
//! - A reorged block (and its descendants) is invalidated for good, and its witnesses are
//!   dropped; a replacement block is a different anchor and needs its own witnesses.
//! - Promotion is recomputed from the current evidence each time, so an anchor that stops
//!   being confirmed (e.g. a `safe` head that moved to another branch) stops being executable.

use std::collections::HashMap;

use alloy_consensus::Header;
use alloy_primitives::{B256, U256, keccak256};
use alloy_rlp::Decodable;
use channel_types::{ConfirmationPolicy, L1Anchor};

use crate::{ReadKey, VerifiedWitness, WitnessError, WitnessPackage, verify};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Only authenticated evidence (`Safe`, `Finalized`) promotes anchors.
    Authenticated,
    /// Local experiments: `Latest` allowed, and labeled optimistic everywhere it shows.
    OptimisticExperiment,
}

/// A confirmed head at some level, as reported by the evidence source.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Confirmation {
    pub level: ConfirmationPolicy,
    pub number: u64,
    pub hash: B256,
    /// Whether the source authenticated it (light client). `Latest` never is.
    pub authenticated: bool,
}

pub trait ConfirmationSource {
    fn head(&self, level: ConfirmationPolicy) -> Option<Confirmation>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Invalidation {
    Reorged,
    /// Another block at this height was finalized.
    FinalizedConflict,
    /// Its parent was invalidated.
    AncestorInvalid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Candidate,
    Executable(ConfirmationPolicy),
    Invalidated(Invalidation),
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AnchorError {
    #[error("malformed or non-canonical header: {0}")]
    BadHeader(String),
    #[error("confirmation policy {0:?} is not supported: {1}")]
    Unsupported(ConfirmationPolicy, &'static str),
    #[error("unknown anchor {0}")]
    Unknown(B256),
    #[error("anchor {0} is invalidated ({1:?})")]
    Invalidated(B256, Invalidation),
    #[error("anchor {0} is not confirmed at the channel's policy")]
    NotConfirmed(B256),
    #[error("no verified witness at anchor {0} covers {1:?}")]
    MissingWitness(B256, Option<ReadKey>),
    #[error(transparent)]
    Witness(#[from] WitnessError),
}

#[derive(Debug)]
struct Entry {
    anchor: L1Anchor,
    parent: B256,
    status: Status,
    witnesses: Vec<VerifiedWitness>,
}

#[derive(Debug)]
pub struct AnchorBook {
    chain_id: u64,
    policy: ConfirmationPolicy,
    mode: Mode,
    /// By block hash.
    entries: HashMap<B256, Entry>,
    /// anchor id → block hash.
    by_id: HashMap<B256, B256>,
}

impl AnchorBook {
    pub fn new(chain_id: u64, policy: ConfirmationPolicy, mode: Mode) -> Result<Self, AnchorError> {
        match (policy, mode) {
            (ConfirmationPolicy::FcrConfirmed, _) => {
                return Err(AnchorError::Unsupported(
                    policy,
                    "no FCR confirmation-evidence source is integrated (M4)",
                ));
            }
            (ConfirmationPolicy::Latest, Mode::Authenticated) => {
                return Err(AnchorError::Unsupported(
                    policy,
                    "optimistic anchors need Mode::OptimisticExperiment",
                ));
            }
            _ => {}
        }
        Ok(Self {
            chain_id,
            policy,
            mode,
            entries: HashMap::new(),
            by_id: HashMap::new(),
        })
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// Records a header seen on L1. The anchor is derived from the header bytes.
    pub fn observe(&mut self, raw_header: &[u8]) -> Result<L1Anchor, AnchorError> {
        let h = Header::decode(&mut &raw_header[..])
            .map_err(|e| AnchorError::BadHeader(e.to_string()))?;
        if alloy_rlp::encode(&h) != raw_header {
            return Err(AnchorError::BadHeader(
                "does not re-encode to the same bytes".into(),
            ));
        }
        let hash = keccak256(raw_header);
        let anchor = L1Anchor {
            chainId: U256::from(self.chain_id),
            blockNumber: h.number,
            blockHash: hash,
            stateRoot: h.state_root,
        };
        if let Some(e) = self.entries.get(&hash) {
            return Ok(e.anchor.clone());
        }
        let status = match self.entries.get(&h.parent_hash).map(|p| p.status) {
            Some(Status::Invalidated(_)) => Status::Invalidated(Invalidation::AncestorInvalid),
            _ => Status::Candidate,
        };
        self.by_id.insert(anchor.id(), hash);
        self.entries.insert(
            hash,
            Entry {
                anchor: anchor.clone(),
                parent: h.parent_hash,
                status,
                witnesses: Vec::new(),
            },
        );
        Ok(anchor)
    }

    /// Verifies `pkg` against the anchor of block `block_hash` and keeps it. Returns the
    /// package hash.
    pub fn attach(&mut self, block_hash: B256, pkg: &WitnessPackage) -> Result<B256, AnchorError> {
        let e = self
            .entries
            .get_mut(&block_hash)
            .ok_or(AnchorError::Unknown(block_hash))?;
        if let Status::Invalidated(why) = e.status {
            return Err(AnchorError::Invalidated(e.anchor.id(), why));
        }
        let w = verify(pkg, &e.anchor)?;
        let h = w.package_hash();
        if !e.witnesses.iter().any(|x| x.package_hash() == h) {
            e.witnesses.push(w);
        }
        Ok(h)
    }

    /// Re-evaluates every non-invalidated anchor against `src`'s current evidence.
    pub fn promote(&mut self, src: &impl ConfirmationSource) {
        let head = src.head(self.policy).filter(|c| {
            c.level == self.policy
                && (c.authenticated
                    || (self.mode == Mode::OptimisticExperiment
                        && c.level == ConfirmationPolicy::Latest))
        });
        let hashes: Vec<B256> = self.entries.keys().copied().collect();
        for hash in hashes {
            if matches!(self.entries[&hash].status, Status::Invalidated(_)) {
                continue;
            }
            let number = self.entries[&hash].anchor.blockNumber;
            let verdict = head
                .and_then(|c| (c.number >= number).then(|| self.on_chain_of(c.hash, number, hash)));
            let e = self.entries.get_mut(&hash).expect("present");
            match verdict {
                Some(Some(true)) => e.status = Status::Executable(self.policy),
                Some(Some(false)) if self.policy == ConfirmationPolicy::Finalized => {
                    self.invalidate(hash, Invalidation::FinalizedConflict);
                }
                _ => e.status = Status::Candidate,
            }
        }
    }

    /// Walks back from `head` to height `number`: `Some(true)` if it reaches `target`,
    /// `Some(false)` if it reaches another block there, `None` if a link is unknown.
    fn on_chain_of(&self, head: B256, number: u64, target: B256) -> Option<bool> {
        let mut cur = head;
        loop {
            let e = self.entries.get(&cur)?;
            if e.anchor.blockNumber == number {
                return Some(cur == target);
            }
            if e.anchor.blockNumber < number {
                return None;
            }
            cur = e.parent;
        }
    }

    /// A reorg removed `block_hash`: it and every known descendant are invalidated and lose
    /// their witnesses.
    pub fn reorged(&mut self, block_hash: B256) {
        self.invalidate(block_hash, Invalidation::Reorged);
    }

    fn invalidate(&mut self, root: B256, why: Invalidation) {
        let mut stack = vec![(root, why)];
        while let Some((h, why)) = stack.pop() {
            if let Some(e) = self.entries.get_mut(&h) {
                e.status = Status::Invalidated(why);
                e.witnesses.clear();
            }
            stack.extend(
                self.entries
                    .iter()
                    .filter(|(_, e)| e.parent == h)
                    .map(|(c, _)| (*c, Invalidation::AncestorInvalid)),
            );
        }
    }

    pub fn status(&self, anchor_id: B256) -> Option<Status> {
        self.by_id.get(&anchor_id).map(|h| self.entries[h].status)
    }

    fn entry(&self, anchor_id: B256) -> Result<&Entry, AnchorError> {
        self.by_id
            .get(&anchor_id)
            .map(|h| &self.entries[h])
            .ok_or(AnchorError::Unknown(anchor_id))
    }

    /// `proofReady`: a verified witness at exactly this anchor covers every key. Says nothing
    /// about confirmation.
    pub fn proof_ready(
        &self,
        anchor_id: B256,
        keys: &[ReadKey],
    ) -> Result<&VerifiedWitness, AnchorError> {
        let e = self.entry(anchor_id)?;
        if let Status::Invalidated(why) = e.status {
            return Err(AnchorError::Invalidated(anchor_id, why));
        }
        e.witnesses
            .iter()
            .find(|w| keys.iter().all(|k| w.covers(k)))
            .ok_or_else(|| {
                let missing = keys
                    .iter()
                    .find(|k| !e.witnesses.iter().any(|w| w.covers(k)))
                    .copied();
                AnchorError::MissingWitness(anchor_id, missing)
            })
    }

    /// What an execution may use: confirmed at the policy, not invalidated, and proof-ready.
    pub fn executable(
        &self,
        anchor_id: B256,
        keys: &[ReadKey],
    ) -> Result<&VerifiedWitness, AnchorError> {
        match self.entry(anchor_id)?.status {
            Status::Invalidated(why) => Err(AnchorError::Invalidated(anchor_id, why)),
            Status::Candidate => Err(AnchorError::NotConfirmed(anchor_id)),
            Status::Executable(_) => self.proof_ready(anchor_id, keys),
        }
    }

    /// The newest executable anchor whose witnesses cover `keys`: how a channel advances
    /// from H0 to H1 without reopening.
    pub fn latest_executable(&self, keys: &[ReadKey]) -> Option<&VerifiedWitness> {
        let mut best: Option<&VerifiedWitness> = None;
        for e in self.entries.values() {
            if let Ok(w) = self.executable(e.anchor.id(), keys)
                && best.is_none_or(|b| b.anchor().blockNumber < w.anchor().blockNumber)
            {
                best = Some(w);
            }
        }
        best
    }

    pub fn block_hash_of(&self, anchor_id: B256) -> Option<B256> {
        self.by_id.get(&anchor_id).copied()
    }

    /// The anchor for a header this book holds.
    pub fn anchor(&self, block_hash: B256) -> Option<&L1Anchor> {
        self.entries.get(&block_hash).map(|e| &e.anchor)
    }
}

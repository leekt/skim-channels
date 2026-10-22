//! L1 witnesses for execution channels (PROJECT.md §3.5, §4).
//!
//! A [`WitnessPackage`] holds EIP-1186-style account and storage proofs, **all against one
//! exact L1 state root** (its anchor). [`verify`] is the only way to obtain a
//! [`VerifiedWitness`], the read view an execution may use:
//! - the package's anchor must equal the authenticated anchor the caller supplies
//!   ([`anchor::AnchorBook`] produces those); a package for another block is refused;
//! - every account is proven present (with these exact fields) or proven absent;
//! - every slot is proven against its account's storage root (present, or proven absent);
//!   a slot of an absent account or an empty storage trie is zero with an empty proof;
//! - code, when included, must hash to the proven code hash;
//! - order is canonical and sizes are bounded, so the [`package_hash`] is unique.
//!
//! Reading a key the package doesn't cover is [`WitnessError::NotWitnessed`], never zero.
//!
//! Values versus witnesses (§4): a value skim keeps current by applying BAL writes has no
//! proof at the newer root. [`readiness`] keeps `state_ready` (a value is known) apart from
//! `proof_ready` (a verified witness at this exact anchor covers it); only the latter
//! authorizes execution.

use std::collections::BTreeMap;

use alloy_primitives::{Address, B256, Bytes, U256, keccak256};
use alloy_sol_types::{SolValue, sol};
use alloy_trie::{EMPTY_ROOT_HASH, KECCAK_EMPTY, Nibbles, TrieAccount, proof::verify_proof};
use channel_types::L1Anchor;

pub mod anchor;
pub mod header;
pub mod readiness;
pub mod source;
#[cfg(any(test, feature = "testkit"))]
pub mod testkit;

/// Bounds on what a package may contain, so parsing and verification stay bounded.
pub const MAX_ACCOUNTS: usize = 256;
pub const MAX_SLOTS: usize = 1024;
pub const MAX_PROOF_NODES: usize = 64;
/// A full branch node is at most 532 bytes of RLP; nothing legitimate is larger.
pub const MAX_NODE_BYTES: usize = 600;
pub const MAX_CODE_BYTES: usize = 0x6000 * 2; // EIP-7954-sized headroom over EIP-170

sol! {
    /// One account at the anchor's state root. `exists == false` means proven absent and
    /// every field must be zero.
    #[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
    struct AccountWitness {
        address account;
        bool exists;
        uint64 nonce;
        uint256 balance;
        bytes32 storageRoot;
        bytes32 codeHash;
        /// Empty unless the execution needs the code; then keccak256(code) == codeHash.
        bytes code;
        bytes[] proof;
    }

    /// One storage slot, proven against its account's storage root.
    #[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
    struct StorageWitness {
        address account;
        bytes32 slot;
        uint256 value;
        bytes[] proof;
    }

    /// The canonical witness package: `abi.encode(WitnessPackage)` is what an L2 execution
    /// receives and what `package_hash` commits to.
    #[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
    struct WitnessPackage {
        L1Anchor anchor;
        AccountWitness[] accounts;
        StorageWitness[] slots;
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum WitnessError {
    #[error("package anchor {got} is not the authenticated anchor {want}")]
    AnchorMismatch { got: B256, want: B256 },
    #[error("package exceeds bounds: {0}")]
    TooLarge(&'static str),
    #[error("package is not in canonical order (or repeats a key): {0}")]
    NotCanonical(&'static str),
    #[error("absent account {0} carries nonzero fields")]
    AbsentAccountFields(Address),
    #[error("account proof for {0} does not verify against the state root")]
    BadAccountProof(Address),
    #[error("storage proof for {0} slot {1} does not verify against the storage root")]
    BadStorageProof(Address, B256),
    #[error("storage for {0} without a witness for its account")]
    StorageWithoutAccount(Address),
    #[error("slot {1} of {0} is in an empty trie but claims a value or carries a proof")]
    EmptyTrieSlot(Address, B256),
    #[error("code for {0} does not match its code hash")]
    CodeMismatch(Address),
    #[error("{0} slot {1:?} is not covered by the witness")]
    NotWitnessed(Address, Option<B256>),
    #[error("malformed package encoding: {0}")]
    Encoding(String),
}

/// Keccak of the canonical ABI encoding.
pub fn package_hash(p: &WitnessPackage) -> B256 {
    keccak256(p.abi_encode())
}

/// Strict decoding of `abi.encode(WitnessPackage)`: must re-encode to the same bytes.
pub fn decode_package(data: &[u8]) -> Result<WitnessPackage, WitnessError> {
    channel_types::decode_strict::<WitnessPackage>(data)
        .map_err(|e| WitnessError::Encoding(e.to_string()))
}

/// A package checked against an authenticated anchor. Only [`verify`] constructs one.
#[derive(Debug, Clone)]
pub struct VerifiedWitness {
    anchor: L1Anchor,
    package_hash: B256,
    accounts: BTreeMap<Address, Option<TrieAccount>>,
    code: BTreeMap<Address, Bytes>,
    slots: BTreeMap<(Address, B256), U256>,
}

impl VerifiedWitness {
    pub fn anchor(&self) -> &L1Anchor {
        &self.anchor
    }

    pub fn anchor_id(&self) -> B256 {
        self.anchor.id()
    }

    pub fn package_hash(&self) -> B256 {
        self.package_hash
    }

    /// The account, or `None` if proven absent. Unwitnessed is an error, never "absent".
    pub fn account(&self, a: Address) -> Result<Option<TrieAccount>, WitnessError> {
        self.accounts
            .get(&a)
            .copied()
            .ok_or(WitnessError::NotWitnessed(a, None))
    }

    pub fn storage(&self, a: Address, slot: B256) -> Result<U256, WitnessError> {
        self.slots
            .get(&(a, slot))
            .copied()
            .ok_or(WitnessError::NotWitnessed(a, Some(slot)))
    }

    pub fn code(&self, a: Address) -> Result<&Bytes, WitnessError> {
        self.code.get(&a).ok_or(WitnessError::NotWitnessed(a, None))
    }

    pub fn covers(&self, key: &ReadKey) -> bool {
        match key {
            ReadKey::Account(a) => self.accounts.contains_key(a),
            ReadKey::Storage(a, s) => self.slots.contains_key(&(*a, *s)),
            ReadKey::Code(a) => {
                self.code.contains_key(a) || matches!(self.accounts.get(a), Some(None))
            }
        }
    }
}

/// One piece of L1 state an execution reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ReadKey {
    Account(Address),
    Storage(Address, B256),
    Code(Address),
}

fn check_proof_bounds(proof: &[Bytes], what: &'static str) -> Result<(), WitnessError> {
    if proof.len() > MAX_PROOF_NODES || proof.iter().any(|n| n.len() > MAX_NODE_BYTES) {
        return Err(WitnessError::TooLarge(what));
    }
    Ok(())
}

/// Verifies `pkg` against `trusted`, the authenticated anchor. Fails closed on anything not
/// proven against exactly `trusted.stateRoot`.
pub fn verify(pkg: &WitnessPackage, trusted: &L1Anchor) -> Result<VerifiedWitness, WitnessError> {
    if pkg.anchor != *trusted {
        return Err(WitnessError::AnchorMismatch {
            got: pkg.anchor.id(),
            want: trusted.id(),
        });
    }
    if pkg.accounts.len() > MAX_ACCOUNTS {
        return Err(WitnessError::TooLarge("accounts"));
    }
    if pkg.slots.len() > MAX_SLOTS {
        return Err(WitnessError::TooLarge("storage"));
    }
    if !pkg.accounts.windows(2).all(|w| w[0].account < w[1].account) {
        return Err(WitnessError::NotCanonical("accounts"));
    }
    if !pkg
        .slots
        .windows(2)
        .all(|w| (w[0].account, w[0].slot) < (w[1].account, w[1].slot))
    {
        return Err(WitnessError::NotCanonical("storage"));
    }
    let state_root = trusted.stateRoot;
    let mut accounts = BTreeMap::new();
    let mut code = BTreeMap::new();
    for w in &pkg.accounts {
        check_proof_bounds(&w.proof, "account proof")?;
        if w.code.len() > MAX_CODE_BYTES {
            return Err(WitnessError::TooLarge("code"));
        }
        let key = Nibbles::unpack(keccak256(w.account));
        let acct = if w.exists {
            let a = TrieAccount {
                nonce: w.nonce,
                balance: w.balance,
                storage_root: w.storageRoot,
                code_hash: w.codeHash,
            };
            verify_proof(state_root, key, Some(alloy_rlp::encode(a)), &w.proof)
                .map_err(|_| WitnessError::BadAccountProof(w.account))?;
            Some(a)
        } else {
            let zero = w.nonce == 0
                && w.balance.is_zero()
                && w.storageRoot.is_zero()
                && w.codeHash.is_zero()
                && w.code.is_empty();
            if !zero {
                return Err(WitnessError::AbsentAccountFields(w.account));
            }
            verify_proof(state_root, key, None, &w.proof)
                .map_err(|_| WitnessError::BadAccountProof(w.account))?;
            None
        };
        if let Some(a) = &acct
            && (!w.code.is_empty() || a.code_hash == KECCAK_EMPTY)
        {
            if keccak256(&w.code) != a.code_hash {
                return Err(WitnessError::CodeMismatch(w.account));
            }
            code.insert(w.account, Bytes::from(w.code.to_vec()));
        }
        accounts.insert(w.account, acct);
    }
    let mut slots = BTreeMap::new();
    for s in &pkg.slots {
        check_proof_bounds(&s.proof, "storage proof")?;
        let acct = accounts
            .get(&s.account)
            .ok_or(WitnessError::StorageWithoutAccount(s.account))?;
        let storage_root = acct.map(|a| a.storage_root).unwrap_or(EMPTY_ROOT_HASH);
        if storage_root == EMPTY_ROOT_HASH {
            // The account proof already settles every slot: zero, and nothing else to carry.
            if !s.value.is_zero() || !s.proof.is_empty() {
                return Err(WitnessError::EmptyTrieSlot(s.account, s.slot));
            }
        } else {
            let expected = (!s.value.is_zero()).then(|| alloy_rlp::encode(s.value));
            verify_proof(
                storage_root,
                Nibbles::unpack(keccak256(s.slot)),
                expected,
                &s.proof,
            )
            .map_err(|_| WitnessError::BadStorageProof(s.account, s.slot))?;
        }
        slots.insert((s.account, s.slot), s.value);
    }
    Ok(VerifiedWitness {
        anchor: trusted.clone(),
        package_hash: package_hash(pkg),
        accounts,
        code,
        slots,
    })
}

#[cfg(test)]
mod tests;

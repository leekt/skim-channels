//! The executor's state: app-local accounts, plus imported L1 accounts read at the pinned block.
//!
//! - **Imported accounts** (the addresses the app declared) are L1's, at the pin. Their balance,
//!   nonce, code and storage come from verified proofs, fetched on first use. Code is fetched
//!   separately and must hash to the proven code hash. A value that can't be fetched and
//!   verified is an error, never zero.
//! - **The overlay** holds app writes into imported accounts' storage, allowed only where the
//!   slot's L1 value at the pin is proven zero (see `guard`). Base and overlay are kept apart:
//!   once a slot is in the overlay, later writes to it are checked against its L1 base, not the
//!   overlay value.
//! - **Everything else is app-local.** An address that isn't imported starts empty here,
//!   whatever it holds on L1, so L1 balances are never spendable on the app.
//!
//! - **Read-only imports** (e.g. a price feed the app's settlement checks against L1 itself)
//!   take no overlay writes at all, so what the app reads there is always L1's value.
//!
//! Every verified entry is kept as evidence for the pin: accounts (with code where it ran),
//! storage read, and the zero proofs behind overlay writes.

use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    sync::Arc,
};

use alloy_primitives::{Address, B256, Bytes, U256, keccak256};
use channel_types::L1Anchor;
use channel_witness::{
    AccountWitness, StorageWitness, WitnessPackage,
    source::{SkimRpc, collect_witness},
    verify,
};
use revm::{
    Database, DatabaseCommit,
    bytecode::Bytecode,
    database_interface::DBErrorMarker,
    primitives::{AddressMap, KECCAK_EMPTY},
    state::{Account, AccountInfo},
};

#[derive(Debug, Clone, thiserror::Error)]
pub enum DbError {
    #[error("L1 state for {0} unavailable at the pin: {1}")]
    Unavailable(Address, String),
    #[error("unknown code hash {0}")]
    UnknownCode(B256),
}

impl DBErrorMarker for DbError {}

/// Verified L1 state at the current head: the working set (every account and slot the app has
/// touched), proven against that head's state root. The follower re-proves it at each new head
/// in the background, so it stays warm.
#[derive(Clone, Default)]
pub struct Base {
    accounts: BTreeMap<Address, AccountWitness>,
    slots: BTreeMap<(Address, B256), StorageWitness>,
}

impl Base {
    /// The working set: each account, with the slots read or written under it.
    pub fn keys(&self) -> BTreeMap<Address, Vec<B256>> {
        let mut k: BTreeMap<Address, Vec<B256>> =
            self.accounts.keys().map(|a| (*a, vec![])).collect();
        for (a, s) in self.slots.keys() {
            k.entry(*a).or_default().push(*s);
        }
        k
    }

    /// Takes in a verified package (accounts without their code: code is content-addressed).
    pub fn insert(&mut self, pkg: WitnessPackage) {
        for a in pkg.accounts {
            self.accounts.insert(
                a.account,
                AccountWitness {
                    code: Bytes::new(),
                    ..a
                },
            );
        }
        for s in pkg.slots {
            self.slots.insert((s.account, s.slot), s);
        }
    }

    pub fn merge(&mut self, other: Base) {
        self.accounts.extend(other.accounts);
        self.slots.extend(other.slots);
    }

    pub fn account(&self, a: &Address) -> Option<&AccountWitness> {
        self.accounts.get(a)
    }

    pub fn slot(&self, a: Address, s: B256) -> Option<U256> {
        self.slots.get(&(a, s)).map(|w| w.value)
    }
}

/// Where contracts read which L1 block their imported reads reflect: any call to this
/// app-local account returns `(uint256 number, bytes32 hash, uint256 timestamp)` of the head
/// the executor has applied. Only the executor writes its storage, as the head moves.
pub const L1_HEAD: Address = Address::new([
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x4c, 0x31,
]);
/// SLOAD 0,1,2 into memory 0x00,0x20,0x40 and return 96 bytes, whatever the calldata.
const L1_HEAD_CODE: [u8; 23] = [
    0x60, 0x00, 0x54, 0x60, 0x00, 0x52, 0x60, 0x01, 0x54, 0x60, 0x20, 0x52, 0x60, 0x02, 0x54, 0x60,
    0x40, 0x52, 0x60, 0x60, 0x60, 0x00, 0xf3,
];

#[derive(Clone, Default, Debug)]
pub struct LocalAccount {
    pub info: AccountInfo,
    pub storage: HashMap<U256, U256>,
}

#[derive(Clone)]
pub struct AppDb {
    pub anchor: L1Anchor,
    pub imported: BTreeSet<Address>,
    /// Imported accounts that take no overlay writes (a subset of `imported`).
    pub readonly: BTreeSet<Address>,
    pub local: HashMap<Address, LocalAccount>,
    /// App writes into imported accounts' storage, at slots whose L1 value is zero.
    pub overlay: BTreeMap<(Address, U256), U256>,
    pub base: Base,
    pub code: HashMap<B256, Bytecode>,
    pub block_hashes: BTreeMap<u64, B256>,
    pub(crate) src: Arc<SkimRpc>,
}

impl AppDb {
    pub fn new(src: Arc<SkimRpc>, anchor: L1Anchor, imported: BTreeSet<Address>) -> Self {
        let code = Bytecode::new_raw(Bytes::from_static(&L1_HEAD_CODE));
        let code_hash = code.hash_slow();
        let mut local = HashMap::new();
        local.insert(
            L1_HEAD,
            LocalAccount {
                // `AccountInfo::default()` carries empty code: set the real code, not just its hash.
                info: AccountInfo {
                    code_hash,
                    code: Some(code.clone()),
                    nonce: 1,
                    ..Default::default()
                },
                storage: HashMap::new(),
            },
        );
        Self {
            anchor,
            imported,
            readonly: BTreeSet::new(),
            local,
            overlay: BTreeMap::new(),
            base: Base::default(),
            code: HashMap::from([(code_hash, code)]),
            block_hashes: BTreeMap::new(),
            src,
        }
    }

    pub fn is_imported(&self, a: &Address) -> bool {
        self.imported.contains(a)
    }

    pub fn is_readonly(&self, a: &Address) -> bool {
        self.readonly.contains(a)
    }

    /// Records the head the executor has applied in the L1 head account.
    pub fn set_head(&mut self, timestamp: u64) {
        let a = self.local.get_mut(&L1_HEAD).expect("L1 head account");
        a.storage
            .insert(U256::ZERO, U256::from(self.anchor.blockNumber));
        a.storage
            .insert(U256::from(1), U256::from_be_bytes(self.anchor.blockHash.0));
        a.storage.insert(U256::from(2), U256::from(timestamp));
    }

    /// A dependency the working set didn't have yet, proven at the current head on the spot
    /// (it joins the working set, so the follower keeps it warm from now on).
    fn fetch(&mut self, addr: Address, slots: &[B256], code: bool) -> Result<(), DbError> {
        crate::metrics::COLD_FETCHES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        crate::metrics::PROOF_REQUESTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let reads = BTreeMap::from([(addr, (slots.to_vec(), code))]);
        let pkg = collect_witness(&*self.src, &self.anchor, &reads)
            .map_err(|e| DbError::Unavailable(addr, e.to_string()))?;
        for a in pkg.accounts {
            if !a.code.is_empty() {
                // Verified against the proven code hash; code is content-addressed, so it's
                // fetched once and reused at every later head.
                self.code
                    .insert(a.codeHash, Bytecode::new_raw(Bytes::from(a.code.to_vec())));
            }
            self.base.accounts.insert(
                a.account,
                AccountWitness {
                    code: Bytes::new(),
                    ..a
                },
            );
        }
        for s in pkg.slots {
            self.base.slots.insert((s.account, s.slot), s);
        }
        Ok(())
    }

    /// The imported account at the pin, with its code. `None`: proven absent.
    pub fn base_account(&mut self, addr: Address) -> Result<Option<AccountInfo>, DbError> {
        if self.base.accounts.contains_key(&addr) {
            crate::metrics::WARM_READS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        } else {
            self.fetch(addr, &[], false)?;
        }
        let w = &self.base.accounts[&addr];
        if !w.exists {
            return Ok(None);
        }
        let hash = w.codeHash;
        if hash != KECCAK_EMPTY && !self.code.contains_key(&hash) {
            self.fetch(addr, &[], true)?;
        }
        let w = &self.base.accounts[&addr];
        let code = if hash == KECCAK_EMPTY {
            Bytecode::default()
        } else {
            self.code[&hash].clone()
        };
        Ok(Some(AccountInfo::new(w.balance, w.nonce, hash, code)))
    }

    /// The imported slot's L1 value at the pin (proven; zero only if proven zero).
    pub fn base_slot(&mut self, addr: Address, slot: U256) -> Result<U256, DbError> {
        let key = B256::from(slot);
        if self.base.slots.contains_key(&(addr, key)) {
            crate::metrics::WARM_READS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        } else {
            self.fetch(addr, &[key], false)?;
        }
        Ok(self.base.slots[&(addr, key)].value)
    }

    /// Everything verified at this pin, as one canonical package (re-verified here).
    pub fn evidence(&self) -> Result<WitnessPackage, String> {
        let pkg = WitnessPackage {
            anchor: self.anchor.clone(),
            // Code included for every account whose code is known (it ran, or was read).
            accounts: self
                .base
                .accounts
                .values()
                .map(|a| match self.code.get(&a.codeHash) {
                    Some(c) if a.exists && a.codeHash != KECCAK_EMPTY => AccountWitness {
                        code: c.original_bytes().to_vec().into(),
                        ..a.clone()
                    },
                    _ => a.clone(),
                })
                .collect(),
            slots: self.base.slots.values().cloned().collect(),
        };
        verify(&pkg, &self.anchor).map_err(|e| e.to_string())?;
        Ok(pkg)
    }

    /// A state change revm wants to commit that would touch an imported account's balance,
    /// nonce or code, or write storage whose L1 value isn't zero. The guard stops these as
    /// they're attempted; this re-checks the final diff before anything is kept.
    pub fn check_commit(&mut self, changes: &AddressMap<Account>) -> Result<(), String> {
        for (addr, acc) in changes {
            if !acc.is_touched() || !self.is_imported(addr) {
                continue;
            }
            if acc.is_selfdestructed() {
                return Err(format!("imported account {addr} self-destructed"));
            }
            let base = self
                .base_account(*addr)
                .map_err(|e| e.to_string())?
                .unwrap_or_default();
            if acc.info.balance != base.balance
                || acc.info.nonce != base.nonce
                || acc.info.code_hash != base.code_hash
            {
                return Err(format!(
                    "imported account {addr}: balance, nonce or code changed"
                ));
            }
            for (slot, v) in acc.changed_storage_slots() {
                let _ = v;
                if self.is_readonly(addr) {
                    return Err(format!("imported account {addr} is read-only"));
                }
                if !self
                    .base_slot(*addr, *slot)
                    .map_err(|e| e.to_string())?
                    .is_zero()
                {
                    return Err(format!("imported slot {addr}[{slot:#x}] is non-zero on L1"));
                }
            }
        }
        Ok(())
    }
}

/// revm's view: borrows the executor's state for one transaction or call.
pub struct Db<'a>(pub &'a mut AppDb);

impl Database for Db<'_> {
    type Error = DbError;

    fn basic(&mut self, address: Address) -> Result<Option<AccountInfo>, DbError> {
        if self.0.is_imported(&address) {
            return self.0.base_account(address);
        }
        Ok(self.0.local.get(&address).map(|a| a.info.clone()))
    }

    fn code_by_hash(&mut self, code_hash: B256) -> Result<Bytecode, DbError> {
        if code_hash == KECCAK_EMPTY {
            return Ok(Bytecode::default());
        }
        self.0
            .code
            .get(&code_hash)
            .cloned()
            .ok_or(DbError::UnknownCode(code_hash))
    }

    fn storage(&mut self, address: Address, index: U256) -> Result<U256, DbError> {
        if self.0.is_imported(&address) {
            if let Some(v) = self.0.overlay.get(&(address, index)) {
                return Ok(*v);
            }
            return self.0.base_slot(address, index);
        }
        Ok(self
            .0
            .local
            .get(&address)
            .and_then(|a| a.storage.get(&index).copied())
            .unwrap_or_default())
    }

    fn block_hash(&mut self, number: u64) -> Result<B256, DbError> {
        Ok(self
            .0
            .block_hashes
            .get(&number)
            .copied()
            .unwrap_or_default())
    }
}

impl DatabaseCommit for AppDb {
    fn commit(&mut self, changes: AddressMap<Account>) {
        for (addr, mut acc) in changes {
            if !acc.is_touched() {
                continue;
            }
            if self.is_imported(&addr) {
                // Only overlay storage can change here (`check_commit` ran first).
                for (slot, v) in acc.changed_storage_slots() {
                    self.overlay.insert((addr, *slot), v.present_value());
                }
                continue;
            }
            if acc.is_selfdestructed() {
                self.local.remove(&addr);
                continue;
            }
            if let Some(code) = acc.info.code.take()
                && !code.is_empty()
            {
                self.code.insert(acc.info.code_hash, code);
            }
            let created = acc.is_created();
            let entry = self.local.entry(addr).or_default();
            if created {
                entry.storage.clear();
            }
            entry.info = AccountInfo {
                code: None,
                ..acc.info
            };
            for (slot, v) in acc.storage {
                entry.storage.insert(slot, v.present_value());
            }
        }
    }
}

pub fn code_hash(code: &[u8]) -> B256 {
    if code.is_empty() {
        KECCAK_EMPTY
    } else {
        keccak256(code)
    }
}

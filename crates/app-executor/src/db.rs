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

/// Verified L1 state at one pin: what has been fetched so far.
#[derive(Clone, Default)]
pub struct Base {
    accounts: BTreeMap<Address, AccountWitness>,
    with_code: BTreeSet<Address>,
    slots: BTreeMap<(Address, B256), StorageWitness>,
}

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
    src: Arc<SkimRpc>,
}

impl AppDb {
    pub fn new(src: Arc<SkimRpc>, anchor: L1Anchor, imported: BTreeSet<Address>) -> Self {
        Self {
            anchor,
            imported,
            readonly: BTreeSet::new(),
            local: HashMap::new(),
            overlay: BTreeMap::new(),
            base: Base::default(),
            code: HashMap::new(),
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

    fn fetch(&mut self, addr: Address, slots: &[B256], code: bool) -> Result<(), DbError> {
        let reads = BTreeMap::from([(addr, (slots.to_vec(), code))]);
        let pkg = collect_witness(&*self.src, &self.anchor, &reads)
            .map_err(|e| DbError::Unavailable(addr, e.to_string()))?;
        for a in pkg.accounts {
            let keep_code = self
                .base
                .accounts
                .get(&a.account)
                .is_some_and(|old| !old.code.is_empty());
            if !keep_code {
                self.base.accounts.insert(a.account, a);
            }
        }
        if code {
            self.base.with_code.insert(addr);
        }
        for s in pkg.slots {
            self.base.slots.insert((s.account, s.slot), s);
        }
        Ok(())
    }

    /// The imported account at the pin, with its code. `None`: proven absent.
    pub fn base_account(&mut self, addr: Address) -> Result<Option<AccountInfo>, DbError> {
        if !self.base.with_code.contains(&addr) {
            self.fetch(addr, &[], true)?;
        }
        let w = &self.base.accounts[&addr];
        if !w.exists {
            return Ok(None);
        }
        let code = if w.codeHash == KECCAK_EMPTY {
            Bytecode::default()
        } else {
            Bytecode::new_raw(Bytes::from(w.code.to_vec()))
        };
        self.code.insert(w.codeHash, code.clone());
        Ok(Some(AccountInfo::new(w.balance, w.nonce, w.codeHash, code)))
    }

    /// The imported slot's L1 value at the pin (proven; zero only if proven zero).
    pub fn base_slot(&mut self, addr: Address, slot: U256) -> Result<U256, DbError> {
        let key = B256::from(slot);
        if !self.base.slots.contains_key(&(addr, key)) {
            self.fetch(addr, &[key], false)?;
        }
        Ok(self.base.slots[&(addr, key)].value)
    }

    /// Everything verified at this pin, as one canonical package (re-verified here).
    pub fn evidence(&self) -> Result<WitnessPackage, String> {
        let pkg = WitnessPackage {
            anchor: self.anchor.clone(),
            accounts: self.base.accounts.values().cloned().collect(),
            slots: self.base.slots.values().cloned().collect(),
        };
        verify(&pkg, &self.anchor).map_err(|e| e.to_string())?;
        Ok(pkg)
    }

    /// The same app state over a new pin with nothing fetched yet.
    pub fn repinned(&self, anchor: L1Anchor) -> Self {
        Self {
            anchor,
            base: Base::default(),
            ..self.clone()
        }
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

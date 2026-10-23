//! The app network: one transaction per block, mined on arrival, over `AppDb`.
//!
//! Execution environment: the app chain's own block context (its chain id, block number and
//! timestamp, fee 0), Amsterdam rules. L1 code imported here runs against L1 storage at the
//! pin, but `block.*`, `msg.sender` and anything in the overlay are the app's. A call into an
//! imported contract returns what L1 would only for equivalent inputs and context.
//!
//! The executor **follows L1's head** (`--follow`, default `latest`): its imported state is a
//! subscription, current at every new block, never held at an old one. Each transaction
//! records the head it ran against, and contracts can read that head from the L1 head account
//! (`db::L1_HEAD`). Moving to a new head keeps all app state. An overlay slot whose L1 value is
//! still zero there stays; one that became non-zero on L1 is a conflict: following stops,
//! the previous head and all state are kept, and the conflict is reported. No state is
//! dropped implicitly. (`executor_pin` moves to a given block explicitly: replay tooling, with
//! following off.)

use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    sync::Arc,
};

use alloy_consensus::{Transaction, TxEnvelope, transaction::SignerRecoverable};
use alloy_eips::{Decodable2718, Typed2718};
use alloy_primitives::{Address, B256, Bytes, Log, TxKind, U256, keccak256};
use channel_runner::{Rpc, anchor_of, fetch_header};
use channel_types::L1Anchor;
use channel_witness::source::SkimRpc;
use revm::{
    Context, InspectEvm, MainBuilder, MainContext,
    bytecode::Bytecode,
    context::{
        BlockEnv, CfgEnv, TxEnv,
        result::{EVMError, ExecutionResult},
    },
    context_interface::block::BlobExcessGasAndPrice,
    primitives::{AddressMap, hardfork::SpecId},
    state::Account,
};
use serde_json::{Value, json};

use crate::{
    db::{AppDb, Base, Db},
    guard::Guard,
};

pub const SPEC: SpecId = SpecId::AMSTERDAM;
const BLOCK_GAS: u64 = 10_000_000_000;

#[derive(Debug, thiserror::Error)]
pub enum ExecError {
    #[error("execution reverted")]
    Reverted(Bytes),
    #[error("{0}")]
    Halted(String),
    #[error("L1 state unavailable: {0}")]
    Unavailable(String),
    #[error("L1 write rule: {0}")]
    WriteRule(String),
    #[error("invalid transaction: {0}")]
    Invalid(String),
    #[error("pin refused: L1 now holds values at {} overlay slot(s)", .0.len())]
    Conflict(Vec<Value>),
}

#[derive(Clone)]
pub struct Block {
    pub number: u64,
    pub hash: B256,
    pub parent: B256,
    pub timestamp: u64,
    pub tx: Option<B256>,
    pub gas_used: u64,
}

#[derive(Clone)]
pub struct TxRecord {
    pub hash: B256,
    pub raw: Bytes,
    pub from: Address,
    pub to: Option<Address>,
    pub nonce: u64,
    pub value: U256,
    pub input: Bytes,
    pub gas_limit: u64,
    pub ty: u8,
    pub block: u64,
    pub status: bool,
    pub gas_used: u64,
    pub logs: Vec<Log>,
    pub contract: Option<Address>,
    /// The L1 pin this transaction executed against.
    pub l1: (u64, B256),
}

#[derive(Clone)]
struct State {
    db: AppDb,
    blocks: Vec<Block>,
    txs: Vec<TxRecord>,
}

pub struct Executor {
    pub chain_id: u64,
    pub l1_chain_id: u64,
    l1: Rpc,
    state: State,
    snapshots: Vec<State>,
    /// The L1 tag the executor follows (`latest`, `safe`, …), or none.
    follow: Option<String>,
    /// Set when an overlay conflict stopped following.
    conflict: Option<Vec<Value>>,
    last_error: Option<String>,
}

pub struct Call {
    pub from: Address,
    pub to: Option<Address>,
    pub data: Bytes,
    pub value: U256,
    pub gas: Option<u64>,
}

impl Executor {
    pub fn new(
        l1_url: &str,
        chain_id: u64,
        imported: BTreeSet<Address>,
        readonly: BTreeSet<Address>,
        pin: &str,
    ) -> Result<Self, String> {
        let l1 = Rpc::new(l1_url);
        let l1_chain_id = u64::from_str_radix(
            l1.call("eth_chainId", json!([]))
                .map_err(|e| e.to_string())?
                .as_str()
                .unwrap_or("0x0")
                .trim_start_matches("0x"),
            16,
        )
        .map_err(|e| e.to_string())?;
        let h = fetch_header(&l1, pin).map_err(|e| e.to_string())?;
        let anchor = anchor_of(l1_chain_id, &h);
        let imported = imported.union(&readonly).copied().collect();
        let mut db = AppDb::new(Arc::new(SkimRpc::new(l1_url)), anchor, imported);
        db.readonly = readonly;
        db.set_head(h.header.timestamp);
        let genesis = Block {
            number: 0,
            hash: keccak256(b"app-executor genesis"),
            parent: B256::ZERO,
            timestamp: now(),
            tx: None,
            gas_used: 0,
        };
        db.block_hashes.insert(0, genesis.hash);
        Ok(Self {
            chain_id,
            l1_chain_id,
            l1,
            state: State {
                db,
                blocks: vec![genesis],
                txs: vec![],
            },
            snapshots: vec![],
            follow: None,
            conflict: None,
            last_error: None,
        })
    }

    pub fn anchor(&self) -> &L1Anchor {
        &self.state.db.anchor
    }

    pub fn db(&mut self) -> &mut AppDb {
        &mut self.state.db
    }

    pub fn head(&self) -> &Block {
        self.state.blocks.last().expect("genesis")
    }

    pub fn block(&self, n: u64) -> Option<&Block> {
        self.state.blocks.get(n as usize)
    }

    pub fn block_by_hash(&self, h: B256) -> Option<&Block> {
        self.state.blocks.iter().find(|b| b.hash == h)
    }

    pub fn tx(&self, h: B256) -> Option<&TxRecord> {
        self.state.txs.iter().find(|t| t.hash == h)
    }

    pub fn txs(&self) -> &[TxRecord] {
        &self.state.txs
    }

    fn block_env(&self) -> BlockEnv {
        let head = self.head();
        BlockEnv {
            number: U256::from(head.number + 1),
            beneficiary: Address::ZERO,
            timestamp: U256::from(now().max(head.timestamp + 1)),
            gas_limit: BLOCK_GAS,
            basefee: 0,
            difficulty: U256::ZERO,
            prevrandao: Some(B256::ZERO),
            blob_excess_gas_and_price: Some(BlobExcessGasAndPrice::new(0, 5_007_716)),
            ..Default::default()
        }
    }

    fn cfg(&self, validating: bool) -> CfgEnv {
        let mut cfg = CfgEnv::new_with_spec(SPEC);
        cfg.chain_id = self.chain_id;
        cfg.disable_base_fee = true;
        cfg.disable_block_gas_limit = true;
        cfg.tx_gas_limit_cap = Some(u64::MAX);
        cfg.limit_contract_code_size = Some(usize::MAX);
        if !validating {
            cfg.disable_nonce_check = true;
            cfg.disable_balance_check = true;
            cfg.disable_eip3607 = true;
            cfg.disable_fee_charge = true;
            cfg.tx_chain_id_check = false;
        }
        cfg
    }

    fn run(
        &mut self,
        tx: TxEnv,
        validating: bool,
    ) -> Result<(ExecutionResult, AddressMap<Account>), ExecError> {
        let block = self.block_env();
        let cfg = self.cfg(validating);
        let mut guard = Guard::default();
        let res = {
            let mut evm = Context::mainnet()
                .with_db(Db(&mut self.state.db))
                .with_block(block)
                .with_cfg(cfg)
                .build_mainnet_with_inspector(&mut guard);
            evm.inspect_tx(tx)
        };
        if let Some(f) = guard.fault {
            return Err(ExecError::Unavailable(f.to_string()));
        }
        match res {
            Ok(r) => Ok((r.result, r.state)),
            Err(EVMError::Database(e)) => Err(ExecError::Unavailable(e.to_string())),
            Err(EVMError::Transaction(e)) => Err(ExecError::Invalid(e.to_string())),
            Err(e) => Err(ExecError::Halted(format!("{e:?}"))),
        }
    }

    /// `eth_call`: nothing is kept.
    pub fn call(&mut self, c: &Call) -> Result<(Bytes, u64), ExecError> {
        let tx = TxEnv {
            caller: c.from,
            gas_limit: c.gas.unwrap_or(BLOCK_GAS / 10),
            kind: c.to.map(TxKind::Call).unwrap_or(TxKind::Create),
            value: c.value,
            data: c.data.clone(),
            chain_id: Some(self.chain_id),
            ..Default::default()
        };
        let (result, _) = self.run(tx, false)?;
        match result {
            ExecutionResult::Success { output, gas, .. } => {
                Ok((output.into_data(), gas.tx_gas_used()))
            }
            ExecutionResult::Revert { output, .. } => Err(ExecError::Reverted(output)),
            ExecutionResult::Halt { reason, .. } => Err(ExecError::Halted(format!("{reason:?}"))),
        }
    }

    /// `eth_sendRawTransaction`: executes and mines one block, or refuses without any change.
    pub fn send_raw(&mut self, raw: &[u8]) -> Result<B256, ExecError> {
        let env = TxEnvelope::decode_2718(&mut &raw[..])
            .map_err(|e| ExecError::Invalid(e.to_string()))?;
        if env.is_eip4844() || env.is_eip7702() {
            return Err(ExecError::Invalid(
                "blob and set-code transactions aren't supported".into(),
            ));
        }
        let from = env
            .recover_signer()
            .map_err(|e| ExecError::Invalid(e.to_string()))?;
        if self.state.db.is_imported(&from) {
            return Err(ExecError::WriteRule(format!(
                "sender {from} is an imported L1 account"
            )));
        }
        let hash = *env.tx_hash();
        if self.tx(hash).is_some() {
            return Err(ExecError::Invalid("already known".into()));
        }
        let tx = TxEnv {
            tx_type: env.ty(),
            caller: from,
            gas_limit: env.gas_limit(),
            // Fees are 0 on the app network whatever the wallet signed: gas settles nowhere,
            // and no app-local balance is ever needed to pay for it.
            gas_price: 0,
            kind: env.kind(),
            value: env.value(),
            data: env.input().clone(),
            nonce: env.nonce(),
            chain_id: env.chain_id(),
            access_list: env.access_list().cloned().unwrap_or_default(),
            gas_priority_fee: env.max_priority_fee_per_gas().map(|_| 0),
            ..Default::default()
        };
        let (result, changes) = self.run(tx, true)?;
        // Re-checks the final diff; only adds verified base entries, so a refusal changes nothing.
        self.state
            .db
            .check_commit(&changes)
            .map_err(ExecError::WriteRule)?;
        revm::DatabaseCommit::commit(&mut self.state.db, changes);
        let (status, gas_used, logs) = match result {
            ExecutionResult::Success { gas, logs, .. } => (true, gas.tx_gas_used(), logs),
            ExecutionResult::Revert { gas, .. } | ExecutionResult::Halt { gas, .. } => {
                (false, gas.tx_gas_used(), vec![])
            }
        };
        let to = env.to();
        let contract = (to.is_none() && status).then(|| from.create(env.nonce()));
        let parent = self.head().hash;
        let number = self.head().number + 1;
        let timestamp = now().max(self.head().timestamp + 1);
        let block_hash =
            keccak256([parent.as_slice(), &number.to_be_bytes(), hash.as_slice()].concat());
        self.state.blocks.push(Block {
            number,
            hash: block_hash,
            parent,
            timestamp,
            tx: Some(hash),
            gas_used,
        });
        self.state.db.block_hashes.insert(number, block_hash);
        let a = &self.state.db.anchor;
        self.state.txs.push(TxRecord {
            hash,
            raw: Bytes::copy_from_slice(raw),
            from,
            to,
            nonce: env.nonce(),
            value: env.value(),
            input: env.input().clone(),
            gas_limit: env.gas_limit(),
            ty: env.ty(),
            block: number,
            status,
            gas_used,
            logs,
            contract,
            l1: (a.blockNumber, a.blockHash),
        });
        Ok(hash)
    }

    pub fn db_ref(&self) -> &AppDb {
        &self.state.db
    }

    pub fn following(&self) -> bool {
        self.follow.is_some() && self.conflict.is_none()
    }

    pub fn note_error(&mut self, e: String) {
        self.last_error = Some(e);
    }

    /// The current head, the working set to prove at the next one (every account and slot
    /// touched, overlay slots included), and the code hashes already held.
    pub fn working_set(&self) -> (L1Anchor, BTreeMap<Address, Vec<B256>>, HashSet<B256>) {
        let db = &self.state.db;
        let mut keys = db.base.keys();
        for (a, s) in db.overlay.keys() {
            let v = keys.entry(*a).or_default();
            let s = B256::from(*s);
            if !v.contains(&s) {
                v.push(s);
            }
        }
        (db.anchor.clone(), keys, db.code.keys().copied().collect())
    }

    /// Adopt a new head whose working set was proven at it (by the follower, off this lock).
    /// App state is kept. An overlay slot whose L1 value became non-zero is a conflict: nothing
    /// changes, following stops, and the conflict is reported.
    pub fn adopt(
        &mut self,
        anchor: L1Anchor,
        timestamp: u64,
        base: Base,
        codes: Vec<(B256, Bytecode)>,
    ) -> Result<Value, ExecError> {
        if anchor == self.state.db.anchor {
            return Ok(self.pin_json(0));
        }
        // Every overlay slot must be proven at the new head (one written since the follower took
        // its working set is proven here): an unproven slot is never taken as zero.
        let mut base = base;
        let missing: BTreeMap<Address, Vec<B256>> = self
            .state
            .db
            .overlay
            .keys()
            .filter(|(a, s)| base.slot(*a, B256::from(*s)).is_none())
            .fold(BTreeMap::new(), |mut m, (a, s)| {
                m.entry(*a).or_insert_with(Vec::new).push(B256::from(*s));
                m
            });
        if !missing.is_empty() {
            let known = self.state.db.code.keys().copied().collect();
            let (extra, _) =
                crate::follow::prove_set(&self.state.db.src, &anchor, &missing, &known)
                    .map_err(ExecError::Unavailable)?;
            base.merge(extra);
        }
        let mut conflicts = vec![];
        for ((account, slot), local) in &self.state.db.overlay {
            let l1 = base
                .slot(*account, B256::from(*slot))
                .expect("proven above");
            if !l1.is_zero() {
                conflicts.push(
                    json!({"account": account, "slot": B256::from(*slot), "l1": l1, "app": local}),
                );
            }
        }
        if !conflicts.is_empty() {
            self.conflict = Some(conflicts.clone());
            return Err(ExecError::Conflict(conflicts));
        }
        let db = &mut self.state.db;
        for (h, c) in codes {
            db.code.insert(h, c);
        }
        db.anchor = anchor;
        db.base = base;
        db.set_head(timestamp);
        crate::metrics::HEADS_ADOPTED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.last_error = None;
        Ok(self.pin_json(self.state.db.overlay.len()))
    }

    /// Move to a given L1 block (a tag, number or hash) now, proving the working set there:
    /// replay tooling, debugging and evidence. The app's normal freshness is the follower.
    pub fn pin(&mut self, id: &str) -> Result<Value, ExecError> {
        let h = fetch_header(&self.l1, id).map_err(|e| ExecError::Unavailable(e.to_string()))?;
        let anchor = anchor_of(self.l1_chain_id, &h);
        if anchor == self.state.db.anchor {
            return Ok(self.pin_json(0));
        }
        let (_, keys, known) = self.working_set();
        let (base, codes) = crate::follow::prove_set(&self.state.db.src, &anchor, &keys, &known)
            .map_err(ExecError::Unavailable)?;
        let r = self.adopt(anchor, h.header.timestamp, base, codes);
        if r.is_err() && self.follow.is_none() {
            self.conflict = None; // an explicit move is refused; it doesn't stop anything
        }
        r
    }

    pub fn set_follow(&mut self, tag: Option<String>) {
        self.follow = tag;
    }

    /// Catch up with the followed tag now (`executor_sync`): what the follower does at its next
    /// block, done immediately.
    pub fn follow_now(&mut self) -> Result<Value, ExecError> {
        let Some(tag) = self.follow.clone() else {
            return Ok(self.pin_json(self.state.db.overlay.len()));
        };
        if let Some(c) = &self.conflict {
            return Err(ExecError::Conflict(c.clone()));
        }
        let h = fetch_header(&self.l1, &tag).map_err(|e| ExecError::Unavailable(e.to_string()))?;
        let anchor = anchor_of(self.l1_chain_id, &h);
        if anchor == self.state.db.anchor {
            return Ok(self.pin_json(self.state.db.overlay.len()));
        }
        let (_, keys, known) = self.working_set();
        let (base, codes) = crate::follow::prove_set(&self.state.db.src, &anchor, &keys, &known)
            .map_err(ExecError::Unavailable)?;
        self.adopt(anchor, h.header.timestamp, base, codes)
    }

    fn pin_json(&self, overlay_kept: usize) -> Value {
        let a = &self.state.db.anchor;
        json!({"chainId": self.l1_chain_id, "number": a.blockNumber, "hash": a.blockHash, "stateRoot": a.stateRoot, "overlayKept": overlay_kept})
    }

    pub fn status(&self) -> Value {
        let db = &self.state.db;
        json!({
            "pin": self.pin_json(db.overlay.len()),
            "following": self.follow.is_some() && self.conflict.is_none(),
            "follow": self.follow,
            "conflict": self.conflict,
            "lastError": self.last_error,
            "workingSet": self.state.db.base.keys().iter().map(|(a, s)| json!({"account": a, "slots": s.len()})).collect::<Vec<_>>(),
            "imported": db.imported,
            "readonly": db.readonly,
            "overlay": db.overlay.iter().map(|((a, s), v)| json!({"account": a, "slot": B256::from(*s), "value": v})).collect::<Vec<_>>(),
        })
    }

    /// Genesis ETH for an app-local account.
    pub fn alloc(&mut self, a: Address, wei: U256) -> Result<(), String> {
        if self.state.db.is_imported(&a) {
            return Err(format!("{a} is imported: its balance is L1's"));
        }
        self.state.db.local.entry(a).or_default().info.balance = wei;
        Ok(())
    }

    pub fn snapshot(&mut self) -> usize {
        self.snapshots.push(self.state.clone());
        self.snapshots.len() - 1
    }

    pub fn revert(&mut self, id: usize) -> bool {
        if id >= self.snapshots.len() {
            return false;
        }
        self.state = self.snapshots[id].clone();
        self.snapshots.truncate(id);
        true
    }
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

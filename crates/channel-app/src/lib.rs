//! App channels (docs/guide/app-channels.md): the exit/credit trees, the reference ledger app
//! with its (mock) prover, the net-diff codec, and recovery from L1 data alone.
//!
//! Encodings match `contracts/src/app/AppLeaves.sol` and `contracts/test/app/AppLedger.sol`
//! (cross-checked by `fixtures/app/tree.json`):
//! - exit leaf   = keccak256(abi.encode(EXIT_TAG,   recipient, token, amount))
//! - credit leaf = keccak256(abi.encode(CREDIT_TAG, recipient, token, cumulative))
//! - tree: nonzero entries sorted by keccak256(abi.encode(recipient, token)), padded with zero
//!   leaves to 2^depth (depth >= 1), node = keccak256(left || right); empty tree root = 0
//! - published data (one checkpoint) = abi.encode(Entry[] exitDiff, Entry[] creditDiff): every
//!   key whose value changed since the previous checkpoint, zero meaning deleted, in key order.

use std::collections::BTreeMap;

use alloy_primitives::{Address, B256, U256, keccak256};
use alloy_sol_types::{SolValue, sol};

pub mod recover;

sol! {
    #[derive(Debug, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
    struct Entry {
        address recipient;
        address token;
        uint256 value;
    }

    /// AppChannelVault.Claim
    #[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
    struct Claim {
        bytes32 stateRoot;
        bytes32 exitRoot;
        bytes32 creditRoot;
        uint64 depositCursor;
        uint64 forcedCursor;
        bytes32 anchorId;
        bool terminal;
    }

    /// AppChannelVault.Deposit / Forced
    #[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
    struct Deposit {
        address owner;
        address token;
        uint256 amount;
    }

    #[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
    struct Forced {
        address account;
        address token;
        uint64 at;
    }

    function submitCheckpoint(bytes32 id, Claim claim, bytes data, bytes proof);

    /// AppChannelVault.Channel (Status is a uint8 in the ABI).
    #[derive(Debug, PartialEq, Eq)]
    struct Channel {
        uint8 status;
        address verifier;
        uint64 closeDeadline;
        uint32 payoutDelay;
        uint64 frozenAt;
        uint64 nonce;
        uint64 depositCursor;
        uint64 forcedCursor;
        bytes32 configHash;
        bytes32 checkpointHash;
        bytes32 stateRoot;
        bytes32 exitRoot;
        bytes32 creditRoot;
    }

    /// The vault calls the runtime makes.
    interface IAppChannelVault {
        function channel(bytes32 id) external view returns (Channel memory);
        function depositCount(bytes32 id) external view returns (uint256);
        function forcedCount(bytes32 id) external view returns (uint256);
        function deposits(bytes32 id, uint256 i) external view returns (Deposit memory);
        function forcedRequest(bytes32 id, uint256 i) external view returns (Forced memory);
        function inputsHash(bytes32 id, Claim claim, bytes32 dataHash) external view returns (bytes32);
        event CheckpointAccepted(bytes32 indexed channelId, uint64 indexed nonce, bytes32 checkpointHash, bytes32 dataHash);
    }
}

pub fn exit_tag() -> B256 {
    keccak256("skim-app-channels/exit-leaf/v0")
}

pub fn credit_tag() -> B256 {
    keccak256("skim-app-channels/credit-leaf/v0")
}

pub fn mock_tag() -> B256 {
    keccak256("skim-app-channels/mock-proof/v0")
}

pub fn key(recipient: Address, token: Address) -> B256 {
    keccak256((recipient, token).abi_encode_params())
}

pub fn leaf(exits: bool, recipient: Address, token: Address, value: U256) -> B256 {
    let tag = if exits { exit_tag() } else { credit_tag() };
    keccak256((tag, recipient, token, value).abi_encode_params())
}

/// One tree (exits or credits) over (recipient, token) → value. Serialized as its entries.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(from = "Vec<Entry>", into = "Vec<Entry>")]
pub struct Table(pub BTreeMap<(Address, Address), U256>);

impl From<Vec<Entry>> for Table {
    fn from(v: Vec<Entry>) -> Self {
        let mut t = Table::default();
        for e in v {
            t.set(e.recipient, e.token, e.value);
        }
        t
    }
}

impl From<Table> for Vec<Entry> {
    fn from(t: Table) -> Self {
        t.sorted()
    }
}

/// An inclusion proof for `AppChannelVault.claimExit` / `claimCredit`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct LeafProof {
    pub recipient: Address,
    pub token: Address,
    pub value: U256,
    pub index: u64,
    pub siblings: Vec<B256>,
}

impl Table {
    pub fn get(&self, r: Address, t: Address) -> U256 {
        self.0.get(&(r, t)).copied().unwrap_or_default()
    }

    pub fn set(&mut self, r: Address, t: Address, v: U256) {
        if v.is_zero() {
            self.0.remove(&(r, t));
        } else {
            self.0.insert((r, t), v);
        }
    }

    /// Nonzero entries in tree (key) order.
    pub fn sorted(&self) -> Vec<Entry> {
        let mut v: Vec<Entry> = self
            .0
            .iter()
            .map(|(&(recipient, token), &value)| Entry {
                recipient,
                token,
                value,
            })
            .collect();
        v.sort_by_key(|e| key(e.recipient, e.token));
        v
    }

    fn levels(&self, exits: bool) -> Vec<Vec<B256>> {
        let es = self.sorted();
        let mut size = 2usize;
        while size < es.len() {
            size <<= 1;
        }
        let mut level: Vec<B256> = vec![B256::ZERO; size];
        for (i, e) in es.iter().enumerate() {
            level[i] = leaf(exits, e.recipient, e.token, e.value);
        }
        let mut levels = vec![level];
        while levels.last().unwrap().len() > 1 {
            let prev = levels.last().unwrap();
            levels.push(
                prev.chunks(2)
                    .map(|p| keccak256([p[0].as_slice(), p[1].as_slice()].concat()))
                    .collect(),
            );
        }
        levels
    }

    pub fn root(&self, exits: bool) -> B256 {
        if self.0.is_empty() {
            return B256::ZERO;
        }
        self.levels(exits).last().unwrap()[0]
    }

    pub fn proof(&self, exits: bool, r: Address, t: Address) -> Option<LeafProof> {
        let es = self.sorted();
        let index = es.iter().position(|e| e.recipient == r && e.token == t)?;
        let levels = self.levels(exits);
        let mut siblings = Vec::new();
        let mut idx = index;
        for level in &levels[..levels.len() - 1] {
            siblings.push(level[idx ^ 1]);
            idx >>= 1;
        }
        Some(LeafProof {
            recipient: r,
            token: t,
            value: es[index].value,
            index: index as u64,
            siblings,
        })
    }

    /// Entries whose value differs from `published` (zeros included), in key order.
    pub fn diff(&self, published: &Table) -> Vec<Entry> {
        let mut keys: Vec<(Address, Address)> =
            self.0.keys().chain(published.0.keys()).copied().collect();
        keys.sort();
        keys.dedup();
        let mut out: Vec<Entry> = keys
            .into_iter()
            .filter(|&(r, t)| self.get(r, t) != published.get(r, t))
            .map(|(r, t)| Entry {
                recipient: r,
                token: t,
                value: self.get(r, t),
            })
            .collect();
        out.sort_by_key(|e| key(e.recipient, e.token));
        out
    }

    pub fn apply(&mut self, diff: &[Entry]) {
        for e in diff {
            self.set(e.recipient, e.token, e.value);
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AppError {
    #[error("insufficient balance")]
    Insufficient,
    #[error("malformed published data: {0}")]
    Data(String),
}

/// The reference app: a ledger (balances, transfers, withdrawals). Exit allocation = balance;
/// withdrawals become cumulative credits. The off-chain prover is a MOCK (see the vault's
/// MockAppCheckpointVerifier): it computes the right roots but proves nothing.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Ledger {
    pub balances: Table,
    pub credits: Table,
    pub published_balances: Table,
    pub published_credits: Table,
    pub deposit_cursor: u64,
    pub forced_cursor: u64,
}

impl Ledger {
    pub fn consume_deposit(&mut self, d: &Deposit) {
        let b = self.balances.get(d.owner, d.token);
        self.balances.set(d.owner, d.token, b + d.amount);
        self.deposit_cursor += 1;
    }

    /// A forced exit: withdraw all of the token.
    pub fn consume_forced(&mut self, f: &Forced) {
        let all = self.balances.get(f.account, f.token);
        self.withdraw(f.account, f.token, all)
            .expect("all is available");
        self.forced_cursor += 1;
    }

    pub fn transfer(
        &mut self,
        from: Address,
        to: Address,
        token: Address,
        amount: U256,
    ) -> Result<(), AppError> {
        let b = self.balances.get(from, token);
        if b < amount {
            return Err(AppError::Insufficient);
        }
        self.balances.set(from, token, b - amount);
        let c = self.balances.get(to, token);
        self.balances.set(to, token, c + amount);
        Ok(())
    }

    pub fn withdraw(&mut self, who: Address, token: Address, amount: U256) -> Result<(), AppError> {
        let b = self.balances.get(who, token);
        if b < amount {
            return Err(AppError::Insufficient);
        }
        self.balances.set(who, token, b - amount);
        let c = self.credits.get(who, token);
        self.credits.set(who, token, c + amount);
        Ok(())
    }

    pub fn claim(&self, terminal: bool) -> Claim {
        let exit_root = self.balances.root(true);
        let credit_root = self.credits.root(false);
        let state_root = keccak256(
            (
                "ledger-state".to_string(),
                exit_root,
                credit_root,
                self.deposit_cursor,
                self.forced_cursor,
            )
                .abi_encode_params(),
        );
        Claim {
            stateRoot: state_root,
            exitRoot: exit_root,
            creditRoot: credit_root,
            depositCursor: self.deposit_cursor,
            forcedCursor: self.forced_cursor,
            anchorId: B256::ZERO,
            terminal,
        }
    }

    /// The checkpoint's published data: the net diff since the last accepted checkpoint.
    pub fn data(&self) -> Vec<u8> {
        (
            self.balances.diff(&self.published_balances),
            self.credits.diff(&self.published_credits),
        )
            .abi_encode_params()
    }

    /// After L1 accepted the checkpoint.
    pub fn mark_published(&mut self) {
        self.published_balances = self.balances.clone();
        self.published_credits = self.credits.clone();
    }

    /// Applies one accepted checkpoint's published data and cursors (recovery).
    pub fn apply_published(
        &mut self,
        data: &[u8],
        deposit_cursor: u64,
        forced_cursor: u64,
    ) -> Result<(), AppError> {
        let (ex, cr) = <(Vec<Entry>, Vec<Entry>)>::abi_decode_params(data)
            .map_err(|e| AppError::Data(e.to_string()))?;
        if (ex.clone(), cr.clone()).abi_encode_params() != data {
            return Err(AppError::Data("non-canonical encoding".into()));
        }
        self.balances.apply(&ex);
        self.credits.apply(&cr);
        self.deposit_cursor = deposit_cursor;
        self.forced_cursor = forced_cursor;
        self.mark_published();
        Ok(())
    }
}

/// The MOCK proof for a checkpoint whose public-inputs hash (`AppChannelVault.inputsHash`) is
/// `inputs_hash`. Binds the inputs; proves nothing about execution.
pub fn mock_proof(inputs_hash: B256) -> Vec<u8> {
    keccak256((mock_tag(), inputs_hash).abi_encode_params()).to_vec()
}

#[cfg(test)]
mod tests;

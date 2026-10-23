//! Following L1: a subscription, not a held block.
//!
//! - **Stream** (skim's `skim_streamNext`, subscribed to the imported accounts): wakes the
//!   follower when a block is applied, and reports `rewind` and `gap`. Its cursor is kept on disk
//!   (`--state-dir`), so a restart continues the stream instead of starting over. The state
//!   changes it carries are **state-ready**: skim's word, kept only to cross-check proofs and
//!   never used as execution input (this process can't authenticate them: skim doesn't serve the
//!   full block access list to check against the header). Without the stream (another L1
//!   node), the follower polls the head.
//! - **Proof-ready working set**: for each new head, every account and slot the app has touched
//!   is proven against that head's state root: one `eth_getProof` per account, all its slots,
//!   off the execution lock. Code is content-addressed and fetched once per code hash.
//! - **Adoption**: the proven head replaces the previous one between executions, atomically. An
//!   execution always runs against one head (never mixed roots), with warm reads. A dependency
//!   seen for the first time is proven at that same head on the spot and joins the working set.
//!   App state and overlays are kept; an overlay conflict stops following (exec.rs).

use std::{
    collections::{BTreeMap, HashSet},
    path::PathBuf,
    sync::{Arc, Mutex, atomic::Ordering::Relaxed},
    time::{Duration, Instant},
};

use alloy_primitives::{Address, B256, U256};
use channel_runner::{Rpc, anchor_of, fetch_header};
use channel_types::L1Anchor;
use channel_witness::source::{SkimRpc, collect_witness};
use revm::{bytecode::Bytecode, primitives::KECCAK_EMPTY};
use serde_json::{Value, json};

use crate::{db::Base, exec::Executor, metrics as m};

/// The working set proven at `anchor`, plus code for code hashes not seen before.
pub fn prove_set(
    src: &SkimRpc,
    anchor: &L1Anchor,
    keys: &BTreeMap<Address, Vec<B256>>,
    known_code: &HashSet<B256>,
) -> Result<(Base, Vec<(B256, Bytecode)>), String> {
    let mut base = Base::default();
    if keys.is_empty() {
        return Ok((base, vec![]));
    }
    let reads: BTreeMap<_, _> = keys.iter().map(|(a, s)| (*a, (s.clone(), false))).collect();
    m::PROOF_REQUESTS.fetch_add(reads.len() as u64, Relaxed);
    m::PROOF_SLOTS.fetch_add(keys.values().map(|s| s.len() as u64).sum(), Relaxed);
    let pkg = collect_witness(src, anchor, &reads).map_err(|e| e.to_string())?;
    base.insert(pkg);
    let mut codes = vec![];
    for a in keys.keys() {
        let Some(w) = base.account(a) else { continue };
        if w.exists && w.codeHash != KECCAK_EMPTY && !known_code.contains(&w.codeHash) {
            m::CODE_REQUESTS.fetch_add(1, Relaxed);
            let one = BTreeMap::from([(*a, (vec![], true))]);
            let pkg = collect_witness(src, anchor, &one).map_err(|e| e.to_string())?;
            for acc in pkg.accounts {
                codes.push((acc.codeHash, Bytecode::new_raw(acc.code.to_vec().into())));
            }
        }
    }
    Ok((base, codes))
}

struct Stream {
    rpc: Rpc,
    cursor: Value,
    path: Option<PathBuf>,
    /// State-ready changes by block hash: (account, slot) → value. Cross-check only.
    changes: BTreeMap<B256, Vec<(Address, B256, U256)>>,
}

impl Stream {
    fn load(rpc: Rpc, dir: &Option<PathBuf>) -> Self {
        let path = dir.as_ref().map(|d| d.join("stream-cursor.json"));
        let cursor = path
            .as_ref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or(Value::Null);
        Self {
            rpc,
            cursor,
            path,
            changes: BTreeMap::new(),
        }
    }

    /// One `skim_streamNext` call (waits up to `wait` for a new block). None: no stream here.
    fn next(&mut self, watched: &[Address], recent: (u64, B256), wait: Duration) -> Option<()> {
        let req = json!([{
            "cursor": self.cursor, "recent": [{"number": recent.0, "hash": recent.1}], "filters": [],
            "bal": {"addresses": watched}, "maxBlocks": 16, "waitMs": wait.as_millis() as u64,
        }]);
        let r = self.rpc.call("skim_streamNext", req).ok()?;
        for ev in r["events"].as_array().cloned().unwrap_or_default() {
            match ev["type"].as_str() {
                Some("apply") => {
                    m::STREAM_APPLY.fetch_add(1, Relaxed);
                    let block: Option<B256> =
                        serde_json::from_value(ev["block"]["hash"].clone()).ok();
                    for c in ev["stateChanges"].as_array().cloned().unwrap_or_default() {
                        if c["kind"].as_str() != Some("storage") {
                            continue;
                        }
                        let (Some(b), Ok(a), Ok(s), Ok(v)) = (
                            block,
                            serde_json::from_value::<Address>(c["address"].clone()),
                            serde_json::from_value::<U256>(c["slot"].clone()).map(B256::from), // unpadded hex
                            serde_json::from_value::<U256>(c["value"].clone()),
                        ) else {
                            continue;
                        };
                        m::STATE_READY_CHANGES.fetch_add(1, Relaxed);
                        self.changes.entry(b).or_default().push((a, s, v));
                    }
                }
                Some("rewind") => {
                    m::STREAM_REWIND.fetch_add(1, Relaxed);
                }
                Some("gap") => {
                    m::STREAM_GAP.fetch_add(1, Relaxed);
                }
                _ => {}
            }
        }
        self.cursor = r["cursor"].clone();
        if let Some(p) = &self.path {
            let _ = std::fs::write(p, serde_json::to_vec(&self.cursor).unwrap_or_default());
        }
        while self.changes.len() > 64 {
            let first = *self.changes.keys().next().expect("non-empty");
            self.changes.remove(&first);
        }
        Some(())
    }
}

/// Follow `tag` forever (see the module doc). Runs on its own thread.
pub fn run(
    ex: Arc<Mutex<Executor>>,
    l1_url: String,
    tag: String,
    every: Duration,
    state_dir: Option<PathBuf>,
) {
    let rpc = Rpc::new(&l1_url);
    let src = SkimRpc::new(&l1_url);
    let mut stream = Stream::load(Rpc::new(&l1_url), &state_dir);
    let mut has_stream = true;
    loop {
        let (cur, watched) = {
            let e = ex.lock().unwrap_or_else(|p| p.into_inner());
            let a = e.db_ref().anchor.clone();
            (
                (a.blockNumber, a.blockHash),
                e.db_ref().imported.iter().copied().collect::<Vec<_>>(),
            )
        };
        // Wait for the next block: the stream returns when skim applies one; otherwise poll.
        if has_stream && !watched.is_empty() {
            has_stream = stream.next(&watched, cur, every * 4).is_some();
        }
        if !has_stream || watched.is_empty() {
            std::thread::sleep(every);
        }
        // The working set as of now (after the wait), to prove at the new head.
        let (anchor, keys, known, following) = {
            let e = ex.lock().unwrap_or_else(|p| p.into_inner());
            let (a, k, c) = e.working_set();
            (a, k, c, e.following())
        };
        if !following {
            continue;
        }
        m::HEADER_REQUESTS.fetch_add(1, Relaxed);
        let Ok(h) = fetch_header(&rpc, &tag) else {
            continue;
        };
        let l1_chain_id = anchor.chainId.to::<u64>();
        let next = anchor_of(l1_chain_id, &h);
        if next.blockHash == anchor.blockHash {
            continue;
        }
        let t0 = Instant::now();
        let proven = prove_set(&src, &next, &keys, &known);
        let ms = t0.elapsed().as_millis() as u64;
        m::REFRESH_MS.fetch_add(ms, Relaxed);
        m::LAST_REFRESH_MS.store(ms, Relaxed);
        let (base, codes) = match proven {
            Ok(x) => x,
            Err(e) => {
                ex.lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .note_error(format!("proving head {}: {e}", next.blockNumber));
                continue;
            }
        };
        // Cross-check what the stream said changed in this block against the proofs.
        for (a, s, v) in stream
            .changes
            .get(&next.blockHash)
            .cloned()
            .unwrap_or_default()
        {
            if let Some(proven) = base.slot(a, s)
                && proven != v
            {
                m::STATE_READY_MISMATCHES.fetch_add(1, Relaxed);
            }
        }
        let _ = ex.lock().unwrap_or_else(|p| p.into_inner()).adopt(
            next,
            h.header.timestamp,
            base,
            codes,
        );
    }
}

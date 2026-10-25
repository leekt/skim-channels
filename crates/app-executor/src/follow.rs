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
//! - **Rolled from access lists** when the node serves them (skim's `skim_getBlockAccessList`):
//!   if the new head continues the current one (hash-linked, at most 16 blocks), each block's
//!   raw access list is checked against its header's `blockAccessListHash` and the working set
//!   takes the block's writes. No proof per block; keys the block didn't write keep their
//!   values. Any break (no list served, an unlinked chain, a bad commitment) proves instead.
//!   Evidence proves the set at the head again on request (`Executor::prove_now`).
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

use alloy_primitives::{Address, B256, Bytes, U256, keccak256};
use alloy_rlp::Decodable;
use channel_runner::{Rpc, VerifiedHeader, anchor_of, fetch_header};
use channel_types::L1Anchor;
use channel_witness::source::{SkimRpc, collect_witness};
use revm::{bytecode::Bytecode, primitives::KECCAK_EMPTY};
use serde_json::{Value, json};

use crate::{db::Base, exec::Executor, metrics as m};

/// A working set at a head, plus code for code hashes not seen before.
pub type Proven = (Base, Vec<(B256, Bytecode)>);

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

/// The working set at `head`, rolled from `base` (at `from`) through each block's access
/// list, each checked against its own header. `Ok(None)`: the node serves no access lists.
/// `Err`: anything else that stops the roll (the chain from `from` doesn't reach `head`, too
/// many blocks, a list that doesn't match its commitment): the caller proves instead.
pub fn roll_to(
    rpc: &Rpc,
    base: &Base,
    from: &L1Anchor,
    head: &VerifiedHeader,
) -> Result<Option<Proven>, String> {
    let (n0, n1) = (from.blockNumber, head.header.number);
    if n1 <= n0 || n1 - n0 > 16 {
        return Err(format!("head {n1} isn't a short extension of {n0}"));
    }
    // Blocks n0+1 ..= n1, hash-linked from `from` to `head`.
    let mut between = vec![];
    for n in n0 + 1..n1 {
        m::HEADER_REQUESTS.fetch_add(1, Relaxed);
        between.push(fetch_header(rpc, &format!("0x{n:x}")).map_err(|e| e.to_string())?);
    }
    let chain: Vec<&VerifiedHeader> = between.iter().chain(std::iter::once(head)).collect();
    let mut parent = from.blockHash;
    for h in &chain {
        if h.header.parent_hash != parent {
            return Err(format!(
                "block {} doesn't continue {parent}",
                h.header.number
            ));
        }
        parent = h.hash;
    }
    let mut cur = base.clone();
    let mut codes = vec![];
    for h in chain {
        let r = match rpc.call("skim_getBlockAccessList", json!([h.hash])) {
            Ok(r) => r,
            Err(e) if e.to_string().contains("-32601") => return Ok(None),
            Err(e) => return Err(e.to_string()),
        };
        let raw: Bytes =
            serde_json::from_value(r["raw"].clone()).map_err(|e| format!("access list: {e}"))?;
        let bal = verified_bal(&h.raw, &raw)?;
        m::BAL_BYTES.fetch_add(raw.len() as u64, Relaxed);
        let (next, c) = cur.roll(&bal);
        cur = next;
        codes.extend(c);
    }
    Ok(Some((cur, codes)))
}

/// A block's access list, decoded only if `keccak256(raw)` is the header's commitment.
pub fn verified_bal(
    raw_header: &[u8],
    raw: &[u8],
) -> Result<Vec<alloy_eip7928::AccountChanges>, String> {
    let header = alloy_consensus::Header::decode(&mut &raw_header[..])
        .map_err(|e| format!("header: {e}"))?;
    let committed = header
        .block_access_list_hash
        .ok_or_else(|| format!("block {} has no access list commitment", header.number))?;
    if keccak256(raw) != committed {
        return Err(format!(
            "block {}: access list doesn't match its commitment",
            header.number
        ));
    }
    let mut buf = raw;
    let bal = <Vec<alloy_eip7928::AccountChanges>>::decode(&mut buf)
        .map_err(|e| format!("access list: {e}"))?;
    if !buf.is_empty() {
        return Err("access list: trailing bytes".into());
    }
    Ok(bal)
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
    let mut has_bal = true; // until the node says it serves no access lists
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
        let (anchor, keys, known, following, base) = {
            let e = ex.lock().unwrap_or_else(|p| p.into_inner());
            let (a, k, c) = e.working_set();
            (a, k, c, e.following(), e.base())
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
        // From the blocks' access lists when they continue the current head; else proofs.
        let rolled = if has_bal {
            match roll_to(&rpc, &base, &anchor, &h) {
                Ok(Some(x)) => Some(x),
                Ok(None) => {
                    has_bal = false;
                    None
                }
                Err(_) => {
                    m::BAL_FALLBACKS.fetch_add(1, Relaxed);
                    None
                }
            }
        } else {
            None
        };
        if rolled.is_some() {
            m::BAL_ROLLS.fetch_add(1, Relaxed);
        }
        let proven = match rolled {
            Some(x) => Ok(x),
            None => prove_set(&src, &next, &keys, &known),
        };
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

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_eip7928::{AccountChanges, BlockAccessIndex, SlotChanges, StorageChange};

    fn header(bal_hash: Option<B256>) -> Vec<u8> {
        // An Amsterdam header: every earlier optional field present, as on the chain.
        let h = alloy_consensus::Header {
            number: 7,
            base_fee_per_gas: Some(7),
            withdrawals_root: Some(B256::ZERO),
            blob_gas_used: Some(0),
            excess_blob_gas: Some(0),
            parent_beacon_block_root: Some(B256::ZERO),
            requests_hash: Some(B256::ZERO),
            block_access_list_hash: bal_hash,
            ..Default::default()
        };
        alloy_rlp::encode(&h)
    }

    #[test]
    fn an_access_list_is_used_only_if_it_matches_its_headers_commitment() {
        let bal = vec![
            AccountChanges::new(Address::repeat_byte(1)).with_storage_change(SlotChanges::new(
                U256::from(2),
                vec![StorageChange::new(BlockAccessIndex(1), U256::from(3))],
            )),
        ];
        let raw = alloy_rlp::encode(&bal);
        let h = header(Some(keccak256(&raw)));
        assert_eq!(verified_bal(&h, &raw).unwrap(), bal);
        let mut tampered = raw.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert!(
            verified_bal(&h, &tampered)
                .unwrap_err()
                .contains("doesn't match")
        );
        assert!(
            verified_bal(&header(None), &raw)
                .unwrap_err()
                .contains("no access list commitment")
        );
    }

    /// A JSON-RPC node on localhost serving a fixed chain: `respond(method, params)` gives the
    /// result, or an error object when it returns `Err`.
    fn fake_node(
        respond: impl Fn(&str, &Value) -> Result<Value, Value> + Send + 'static,
    ) -> String {
        use std::io::{BufRead, BufReader, Read, Write};
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", l.local_addr().unwrap());
        std::thread::spawn(move || {
            for conn in l.incoming() {
                let Ok(mut out) = conn else { continue };
                let mut r = BufReader::new(out.try_clone().unwrap());
                loop {
                    let mut len = 0;
                    let mut line = String::new();
                    loop {
                        line.clear();
                        if r.read_line(&mut line).unwrap_or(0) == 0 {
                            return;
                        }
                        if line == "\r\n" {
                            break;
                        }
                        if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                            len = v.trim().parse().unwrap();
                        }
                    }
                    let mut body = vec![0; len];
                    r.read_exact(&mut body).unwrap();
                    let req: Value = serde_json::from_slice(&body).unwrap();
                    let resp = match respond(req["method"].as_str().unwrap(), &req["params"]) {
                        Ok(v) => json!({"jsonrpc": "2.0", "id": req["id"], "result": v}),
                        Err(e) => json!({"jsonrpc": "2.0", "id": req["id"], "error": e}),
                    };
                    let b = resp.to_string();
                    let _ = write!(
                        out,
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{b}",
                        b.len()
                    );
                }
            }
        });
        url
    }

    /// A block: its header, the header's RLP, and its access list's RLP.
    type Block = (alloy_consensus::Header, Vec<u8>, Vec<u8>);

    /// Blocks 10..=12, hash-linked; block n's access list sets slot 1 of `a` to n.
    fn chain(a: Address) -> Vec<Block> {
        let mut out: Vec<Block> = vec![];
        let mut parent = B256::repeat_byte(9);
        for n in 10..=12u64 {
            let bal = vec![AccountChanges::new(a).with_storage_change(SlotChanges::new(
                U256::from(1),
                vec![StorageChange::new(BlockAccessIndex(1), U256::from(n))],
            ))];
            let raw_bal = alloy_rlp::encode(&bal);
            let h = alloy_consensus::Header {
                parent_hash: parent,
                number: n,
                base_fee_per_gas: Some(7),
                withdrawals_root: Some(B256::ZERO),
                blob_gas_used: Some(0),
                excess_blob_gas: Some(0),
                parent_beacon_block_root: Some(B256::ZERO),
                requests_hash: Some(B256::ZERO),
                block_access_list_hash: Some(keccak256(&raw_bal)),
                ..Default::default()
            };
            let raw = alloy_rlp::encode(&h);
            parent = keccak256(&raw);
            out.push((h, raw, raw_bal));
        }
        out
    }

    /// Serves `blocks` by number and hash (raw headers via debug_getRawHeader), and their access
    /// lists unless `bals` is false.
    fn serve(blocks: Vec<Block>, bals: bool) -> String {
        fake_node(move |m, p| {
            let find = |f: &dyn Fn(&Block) -> bool| blocks.iter().find(|b| f(b)).cloned();
            let num = |v: &Value| {
                u64::from_str_radix(v.as_str().unwrap_or("0x0").trim_start_matches("0x"), 16)
                    .unwrap_or(0)
            };
            match m {
                "eth_getBlockByNumber" => Ok(find(&|b| b.0.number == num(&p[0]))
                    .map(|b| json!({"number": format!("0x{:x}", b.0.number), "hash": keccak256(&b.1)}))
                    .unwrap_or(Value::Null)),
                "eth_getBlockByHash" => Ok(find(&|b| keccak256(&b.1) == p[0].as_str().unwrap().parse::<B256>().unwrap())
                    .map(|b| json!({"number": format!("0x{:x}", b.0.number), "hash": keccak256(&b.1)}))
                    .unwrap_or(Value::Null)),
                "debug_getRawHeader" => Ok(find(&|b| b.0.number == num(&p[0])).map(|b| json!(Bytes::from(b.1))).unwrap_or(Value::Null)),
                "skim_getBlockAccessList" if bals => {
                    let h: B256 = p[0].as_str().unwrap().parse().unwrap();
                    Ok(find(&|b| keccak256(&b.1) == h).map(|b| json!({"raw": Bytes::from(b.2)})).unwrap_or(Value::Null))
                }
                _ => Err(json!({"code": -32601, "message": format!("method {m} not found")})),
            }
        })
    }

    fn base_at(a: Address, v: u64) -> Base {
        let mut b = Base::default();
        b.insert(channel_witness::WitnessPackage {
            anchor: L1Anchor {
                chainId: U256::ZERO,
                blockNumber: 0,
                blockHash: B256::ZERO,
                stateRoot: B256::ZERO,
            },
            accounts: vec![],
            slots: vec![channel_witness::StorageWitness {
                account: a,
                slot: B256::from(U256::from(1)),
                value: U256::from(v),
                proof: vec![],
            }],
        });
        b
    }

    fn anchor(b: &Block) -> L1Anchor {
        L1Anchor {
            chainId: U256::from(1),
            blockNumber: b.0.number,
            blockHash: keccak256(&b.1),
            stateRoot: b.0.state_root,
        }
    }

    #[test]
    fn the_follower_rolls_through_linked_blocks_and_falls_back_otherwise() {
        let a = Address::repeat_byte(0xa);
        let blocks = chain(a);
        let key = B256::from(U256::from(1));
        // Linked 10 → 12: both blocks' lists apply; the slot ends at 12.
        let rpc = Rpc::new(serve(blocks.clone(), true));
        let head = fetch_header(&rpc, "0xc").unwrap();
        let (rolled, _) = roll_to(&rpc, &base_at(a, 10), &anchor(&blocks[0]), &head)
            .unwrap()
            .unwrap();
        assert_eq!(rolled.slot(a, key), Some(U256::from(12)));
        assert!(rolled.rolled);
        // A node that serves no access lists: None (the follower proves, and stops asking).
        let rpc = Rpc::new(serve(blocks.clone(), false));
        let head = fetch_header(&rpc, "0xc").unwrap();
        assert!(
            roll_to(&rpc, &base_at(a, 10), &anchor(&blocks[0]), &head)
                .unwrap()
                .is_none()
        );
        // A list that doesn't match its header's commitment: refused.
        let mut bad = blocks.clone();
        bad[2].2 = alloy_rlp::encode(vec![AccountChanges::new(a)]);
        let rpc = Rpc::new(serve(bad, true));
        let head = fetch_header(&rpc, "0xc").unwrap();
        assert!(
            roll_to(&rpc, &base_at(a, 10), &anchor(&blocks[0]), &head)
                .err()
                .unwrap()
                .contains("doesn't match")
        );
        // A head that doesn't continue ours (another block 10): refused.
        let rpc = Rpc::new(serve(blocks.clone(), true));
        let head = fetch_header(&rpc, "0xc").unwrap();
        let other = L1Anchor {
            blockHash: B256::repeat_byte(1),
            ..anchor(&blocks[0])
        };
        assert!(
            roll_to(&rpc, &base_at(a, 10), &other, &head)
                .err()
                .unwrap()
                .contains("doesn't continue")
        );
    }
}

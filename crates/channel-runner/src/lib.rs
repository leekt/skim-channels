//! The channel runtime's RPC side (PROJECT.md §7.5, §10): authenticated L1 anchors from raw
//! headers, witness packages through skim's `eth_getProof`, and settlement evidence from an
//! L2 block's receipts.
//!
//! Nothing an endpoint returns is trusted as is:
//! - a header is accepted only if the RLP of its consensus fields hashes to the block hash
//!   asked for (so the state root and receipts root are bound to that hash);
//! - witnesses are verified against the anchor derived from that header
//!   ([`channel_witness::source::collect_witness`]);
//! - receipts are re-encoded in consensus form, and the whole block's receipt trie must
//!   rebuild to the header's `receiptsRoot` before a proof is cut from it.
//!
//! Whether the block hash itself is canonical / confirmed is a separate question: L1 anchors
//! need confirmation evidence (`AnchorBook`); L2 blocks need acceptance on L1.

use alloy_consensus::Header;
use alloy_eips::eip2718::Encodable2718;
use alloy_primitives::{B256, Bytes, U256, keccak256};
use alloy_rpc_types_eth::TransactionReceipt;
use channel_types::L1Anchor;
use serde_json::{Value, json};

#[derive(Debug, thiserror::Error)]
pub enum RunnerError {
    #[error("rpc {0}: {1}")]
    Rpc(String, String),
    #[error("header for {0} does not hash to it")]
    HeaderHash(B256),
    #[error("receipts of block {0} do not rebuild its receipts root")]
    ReceiptsRoot(B256),
    #[error("{0}")]
    Other(String),
}

pub struct Rpc {
    url: String,
    agent: ureq::Agent,
}

impl Rpc {
    pub fn new(url: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            agent: ureq::AgentBuilder::new()
                .timeout(std::time::Duration::from_secs(30))
                .build(),
        }
    }

    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn call(&self, method: &str, params: Value) -> Result<Value, RunnerError> {
        let body = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
        let resp: Value = self
            .agent
            .post(&self.url)
            .send_json(body)
            .map_err(|e| RunnerError::Rpc(method.into(), e.to_string()))?
            .into_json()
            .map_err(|e| RunnerError::Rpc(method.into(), e.to_string()))?;
        if let Some(err) = resp.get("error") {
            return Err(RunnerError::Rpc(method.into(), err.to_string()));
        }
        Ok(resp["result"].clone())
    }
}

/// A header whose bytes hash to the block hash: (hash, raw RLP, decoded).
pub struct VerifiedHeader {
    pub hash: B256,
    pub raw: Bytes,
    pub header: Header,
}

/// Fetches block `id` (a number/tag string or a 0x hash) and checks it hashes to its hash.
/// If `id` is a hash, the header must hash to exactly that.
pub fn fetch_header(rpc: &Rpc, id: &str) -> Result<VerifiedHeader, RunnerError> {
    let by_hash = id.len() == 66 && id.starts_with("0x");
    let v = if by_hash {
        rpc.call("eth_getBlockByHash", json!([id, false]))?
    } else {
        rpc.call("eth_getBlockByNumber", json!([id, false]))?
    };
    if v.is_null() {
        return Err(RunnerError::Other(format!("no block {id}")));
    }
    let h: alloy_rpc_types_eth::Header = serde_json::from_value(v)
        .map_err(|e| RunnerError::Other(format!("bad header json: {e}")))?;
    let raw = Bytes::from(alloy_rlp::encode(&h.inner));
    let hash = keccak256(&raw);
    let claimed = if by_hash {
        id.parse::<B256>()
            .map_err(|e| RunnerError::Other(e.to_string()))?
    } else {
        h.hash
    };
    if hash != claimed {
        return Err(RunnerError::HeaderHash(claimed));
    }
    Ok(VerifiedHeader {
        hash,
        raw,
        header: h.inner,
    })
}

pub fn anchor_of(chain_id: u64, h: &VerifiedHeader) -> L1Anchor {
    L1Anchor {
        chainId: U256::from(chain_id),
        blockNumber: h.header.number,
        blockHash: h.hash,
        stateRoot: h.header.state_root,
    }
}

/// Settlement evidence for the receipt of `tx` (PROJECT.md §7.3): everything but the request
/// and outcome, which the caller has.
pub struct ReceiptEvidence {
    pub block_hash: B256,
    pub header: Bytes,
    pub tx_index: usize,
    pub receipt: Bytes,
    pub proof: Vec<Bytes>,
    pub receipts_root: B256,
    pub block_number: u64,
}

pub fn receipt_evidence(rpc: &Rpc, tx: B256) -> Result<ReceiptEvidence, RunnerError> {
    let r: TransactionReceipt =
        serde_json::from_value(rpc.call("eth_getTransactionReceipt", json!([tx]))?)
            .map_err(|e| RunnerError::Other(format!("bad receipt json: {e}")))?;
    let block_hash = r
        .block_hash
        .ok_or_else(|| RunnerError::Other("receipt not in a block".into()))?;
    let tx_index =
        r.transaction_index
            .ok_or_else(|| RunnerError::Other("no transaction index".into()))? as usize;
    let header = fetch_header(rpc, &block_hash.to_string())?;
    let all: Vec<TransactionReceipt> =
        serde_json::from_value(rpc.call("eth_getBlockReceipts", json!([block_hash]))?)
            .map_err(|e| RunnerError::Other(format!("bad receipts json: {e}")))?;
    let mut encoded = vec![Bytes::new(); all.len()];
    for rc in all {
        let i = rc
            .transaction_index
            .ok_or_else(|| RunnerError::Other("no transaction index".into()))?
            as usize;
        if rc.block_hash != Some(block_hash) || i >= encoded.len() || !encoded[i].is_empty() {
            return Err(RunnerError::Other("inconsistent block receipts".into()));
        }
        encoded[i] = Bytes::from(rc.inner.into_primitives_receipt().encoded_2718());
    }
    let root = channel_receipts::receipts_root(&encoded);
    if root != header.header.receipts_root {
        return Err(RunnerError::ReceiptsRoot(block_hash));
    }
    let proof = channel_receipts::receipt_proof(&encoded, tx_index)
        .map_err(|e| RunnerError::Other(e.to_string()))?;
    channel_receipts::verify_receipt(root, tx_index, &encoded[tx_index], &proof)
        .map_err(|e| RunnerError::Other(e.to_string()))?;
    Ok(ReceiptEvidence {
        block_hash,
        header: header.raw,
        tx_index,
        receipt: encoded[tx_index].clone(),
        proof,
        receipts_root: root,
        block_number: header.header.number,
    })
}

/// Confirmation evidence from an RPC node's `safe` / `finalized` tags.
///
/// skim answers these tags only with light-client-authenticated execution hashes
/// (`-32002 not_verified` until then), so [`RpcConfirmations::skim`] marks them authenticated:
/// that trusts the local skim's light client, which is the trust-minimized component this
/// project builds on. Any other node (anvil, a provider) is [`RpcConfirmations::unauthenticated`]
/// and never promotes an anchor under [`channel_witness::anchor::Mode::Authenticated`].
/// Each head's header is hash-checked; FCR is never reported.
pub struct RpcConfirmations {
    rpc: Rpc,
    authenticated: bool,
}

impl RpcConfirmations {
    pub fn skim(url: impl Into<String>) -> Self {
        Self {
            rpc: Rpc::new(url),
            authenticated: true,
        }
    }

    pub fn unauthenticated(url: impl Into<String>) -> Self {
        Self {
            rpc: Rpc::new(url),
            authenticated: false,
        }
    }

    pub fn rpc(&self) -> &Rpc {
        &self.rpc
    }
}

impl channel_witness::anchor::ConfirmationSource for RpcConfirmations {
    fn head(
        &self,
        level: channel_types::ConfirmationPolicy,
    ) -> Option<channel_witness::anchor::Confirmation> {
        use channel_types::ConfirmationPolicy as P;
        let (tag, authenticated) = match level {
            P::Latest => ("latest", false),
            P::Safe => ("safe", self.authenticated),
            P::Finalized => ("finalized", self.authenticated),
            P::FcrConfirmed => return None,
        };
        let h = fetch_header(&self.rpc, tag).ok()?;
        Some(channel_witness::anchor::Confirmation {
            level,
            number: h.header.number,
            hash: h.hash,
            authenticated,
        })
    }
}

/// Observes `count` headers into `book`, walking back by parent hash from `from` (so that a
/// confirmed head links to the anchors below it). Every header is hash-checked.
pub fn observe_back(
    book: &mut channel_witness::anchor::AnchorBook,
    rpc: &Rpc,
    from: B256,
    count: usize,
) -> Result<Vec<L1Anchor>, RunnerError> {
    let mut out = Vec::with_capacity(count);
    let mut cur = from;
    for _ in 0..count {
        let h = fetch_header(rpc, &cur.to_string())?;
        out.push(
            book.observe(&h.raw)
                .map_err(|e| RunnerError::Other(e.to_string()))?,
        );
        if h.header.number == 0 {
            break;
        }
        cur = h.header.parent_hash;
    }
    Ok(out)
}

/// Fast Confirmation Rule evidence (PROJECT.md §3.3) from a beacon node's standard
/// `fast_confirmation` SSE event (`GET /eth/v1/events?topics=fast_confirmation`, beacon-APIs
/// #598; Lighthouse `--enable-fast-confirmation`, Lodestar `--chain.fastConfirmation`).
///
/// Trust: FCR needs the full fork-choice view (every validator's latest vote), which light-client
/// data doesn't carry, so this trusts the configured **full beacon node**, typically the
/// operator's own. The event gives a beacon block root; the execution block hash is read from
/// that beacon block (pre-ePBS `execution_payload.block_hash`, ePBS
/// `signed_execution_payload_bid.message.block_hash`) and its header is hash-checked on the EL
/// endpoint. This is never derived from `safe`: a node may feed FCR into `safe`, but the
/// evidence used here is the explicit event.
pub struct FcrConfirmations {
    beacon: String,
    el: Rpc,
    agent: ureq::Agent,
}

impl FcrConfirmations {
    pub fn new(beacon_url: impl Into<String>, el_url: impl Into<String>) -> Self {
        Self {
            beacon: beacon_url.into().trim_end_matches('/').to_string(),
            el: Rpc::new(el_url),
            agent: ureq::AgentBuilder::new()
                .timeout(std::time::Duration::from_secs(30))
                .build(),
        }
    }

    /// Waits for the next `fast_confirmation` event and returns its beacon block root.
    pub fn next_confirmed_root(&self) -> Result<B256, RunnerError> {
        use std::io::BufRead;
        let resp = self
            .agent
            .get(&format!(
                "{}/eth/v1/events?topics=fast_confirmation",
                self.beacon
            ))
            .set("accept", "text/event-stream")
            .call()
            .map_err(|e| RunnerError::Rpc("events".into(), e.to_string()))?;
        let mut event = String::new();
        for line in std::io::BufReader::new(resp.into_reader()).lines() {
            let line = line.map_err(|e| RunnerError::Rpc("events".into(), e.to_string()))?;
            if let Some(e) = line.strip_prefix("event:") {
                event = e.trim().to_string();
            } else if let Some(d) = line.strip_prefix("data:")
                && event == "fast_confirmation"
            {
                let v: Value = serde_json::from_str(d.trim())
                    .map_err(|e| RunnerError::Other(e.to_string()))?;
                return v["block"]
                    .as_str()
                    .and_then(|s| s.parse().ok())
                    .ok_or_else(|| RunnerError::Other("fast_confirmation without block".into()));
            }
        }
        Err(RunnerError::Other("event stream ended".into()))
    }

    /// The execution block a beacon block commits to, hash-checked against the EL.
    pub fn execution_header(&self, beacon_root: B256) -> Result<VerifiedHeader, RunnerError> {
        let v: Value = self
            .agent
            .get(&format!(
                "{}/eth/v2/beacon/blocks/{beacon_root}",
                self.beacon
            ))
            .call()
            .map_err(|e| RunnerError::Rpc("beacon block".into(), e.to_string()))?
            .into_json()
            .map_err(|e| RunnerError::Rpc("beacon block".into(), e.to_string()))?;
        let body = &v["data"]["message"]["body"];
        let hash = body["execution_payload"]["block_hash"]
            .as_str()
            .or_else(|| body["signed_execution_payload_bid"]["message"]["block_hash"].as_str())
            .ok_or_else(|| {
                RunnerError::Other("beacon block without an execution block hash".into())
            })?;
        fetch_header(&self.el, hash)
    }

    /// One confirmation from the next event.
    pub fn next(&self) -> Result<channel_witness::anchor::Confirmation, RunnerError> {
        let h = self.execution_header(self.next_confirmed_root()?)?;
        Ok(channel_witness::anchor::Confirmation {
            level: channel_types::ConfirmationPolicy::FcrConfirmed,
            number: h.header.number,
            hash: h.hash,
            authenticated: true,
        })
    }
}

/// The latest FCR confirmation seen, as a [`ConfirmationSource`](channel_witness::anchor::ConfirmationSource)
/// for `FcrConfirmed` only (every other level: none).
pub struct FcrHead(pub Option<channel_witness::anchor::Confirmation>);

impl channel_witness::anchor::ConfirmationSource for FcrHead {
    fn head(
        &self,
        level: channel_types::ConfirmationPolicy,
    ) -> Option<channel_witness::anchor::Confirmation> {
        (level == channel_types::ConfirmationPolicy::FcrConfirmed)
            .then_some(self.0)
            .flatten()
    }
}

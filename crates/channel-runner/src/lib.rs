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
        Self { url: url.into(), agent: ureq::AgentBuilder::new().timeout(std::time::Duration::from_secs(30)).build() }
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
    let h: alloy_rpc_types_eth::Header =
        serde_json::from_value(v).map_err(|e| RunnerError::Other(format!("bad header json: {e}")))?;
    let raw = Bytes::from(alloy_rlp::encode(&h.inner));
    let hash = keccak256(&raw);
    let claimed = if by_hash { id.parse::<B256>().map_err(|e| RunnerError::Other(e.to_string()))? } else { h.hash };
    if hash != claimed {
        return Err(RunnerError::HeaderHash(claimed));
    }
    Ok(VerifiedHeader { hash, raw, header: h.inner })
}

pub fn anchor_of(chain_id: u64, h: &VerifiedHeader) -> L1Anchor {
    L1Anchor { chainId: U256::from(chain_id), blockNumber: h.header.number, blockHash: h.hash, stateRoot: h.header.state_root }
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
    let r: TransactionReceipt = serde_json::from_value(rpc.call("eth_getTransactionReceipt", json!([tx]))?)
        .map_err(|e| RunnerError::Other(format!("bad receipt json: {e}")))?;
    let block_hash = r.block_hash.ok_or_else(|| RunnerError::Other("receipt not in a block".into()))?;
    let tx_index = r.transaction_index.ok_or_else(|| RunnerError::Other("no transaction index".into()))? as usize;
    let header = fetch_header(rpc, &block_hash.to_string())?;
    let all: Vec<TransactionReceipt> = serde_json::from_value(rpc.call("eth_getBlockReceipts", json!([block_hash]))?)
        .map_err(|e| RunnerError::Other(format!("bad receipts json: {e}")))?;
    let mut encoded = vec![Bytes::new(); all.len()];
    for rc in all {
        let i = rc.transaction_index.ok_or_else(|| RunnerError::Other("no transaction index".into()))? as usize;
        if rc.block_hash != Some(block_hash) || i >= encoded.len() || !encoded[i].is_empty() {
            return Err(RunnerError::Other("inconsistent block receipts".into()));
        }
        encoded[i] = Bytes::from(rc.inner.into_primitives_receipt().encoded_2718());
    }
    let root = channel_receipts::receipts_root(&encoded);
    if root != header.header.receipts_root {
        return Err(RunnerError::ReceiptsRoot(block_hash));
    }
    let proof = channel_receipts::receipt_proof(&encoded, tx_index).map_err(|e| RunnerError::Other(e.to_string()))?;
    channel_receipts::verify_receipt(root, tx_index, &encoded[tx_index], &proof).map_err(|e| RunnerError::Other(e.to_string()))?;
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

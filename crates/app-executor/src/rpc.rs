//! Standard Ethereum JSON-RPC over the executor (what wallets, viem and the gateway use), plus
//! `executor_pin`, `executor_status`, `executor_evidence` and anvil-style `evm_snapshot` /
//! `evm_revert` for the operator's runtime. Never expose this directly to users: the gateway
//! filters it.

use alloy_primitives::{Address, B256, Bytes, U256};
use alloy_sol_types::SolValue;
use revm::Database;
use serde_json::{Value, json};

use crate::{
    db::Db,
    exec::{Block, Call, ExecError, Executor, TxRecord},
};

pub struct RpcError {
    pub code: i64,
    pub message: String,
    pub data: Option<Value>,
}

impl RpcError {
    fn invalid(m: impl Into<String>) -> Self {
        Self {
            code: -32602,
            message: m.into(),
            data: None,
        }
    }
}

impl From<ExecError> for RpcError {
    fn from(e: ExecError) -> Self {
        match e {
            ExecError::Reverted(data) => Self {
                code: 3,
                message: "execution reverted".into(),
                data: Some(json!(data)),
            },
            ExecError::Conflict(c) => Self {
                code: -32010,
                message: ExecError::Conflict(c.clone()).to_string(),
                data: Some(json!(c)),
            },
            e => Self {
                code: -32000,
                message: e.to_string(),
                data: None,
            },
        }
    }
}

fn hex(n: u64) -> String {
    format!("{n:#x}")
}

fn param<T: serde::de::DeserializeOwned>(p: &Value, i: usize) -> Result<T, RpcError> {
    serde_json::from_value(p.get(i).cloned().unwrap_or(Value::Null))
        .map_err(|e| RpcError::invalid(format!("param {i}: {e}")))
}

fn call_of(v: &Value) -> Result<Call, RpcError> {
    let addr = |k: &str| -> Result<Option<Address>, RpcError> {
        v.get(k)
            .filter(|x| !x.is_null())
            .map(|x| {
                serde_json::from_value(x.clone())
                    .map_err(|e| RpcError::invalid(format!("{k}: {e}")))
            })
            .transpose()
    };
    let data: Bytes = v
        .get("input")
        .or_else(|| v.get("data"))
        .filter(|x| !x.is_null())
        .map(|x| serde_json::from_value(x.clone()))
        .transpose()
        .map_err(|e| RpcError::invalid(format!("data: {e}")))?
        .unwrap_or_default();
    let value: U256 = v
        .get("value")
        .filter(|x| !x.is_null())
        .map(|x| serde_json::from_value(x.clone()))
        .transpose()
        .map_err(|e| RpcError::invalid(format!("value: {e}")))?
        .unwrap_or_default();
    let gas: Option<U256> = v
        .get("gas")
        .filter(|x| !x.is_null())
        .map(|x| serde_json::from_value(x.clone()))
        .transpose()
        .map_err(|e| RpcError::invalid(format!("gas: {e}")))?;
    Ok(Call {
        from: addr("from")?.unwrap_or_default(),
        to: addr("to")?,
        data,
        value,
        gas: gas.map(|g| g.saturating_to()),
    })
}

fn block_json(ex: &Executor, b: &Block, full: bool) -> Value {
    let txs: Vec<Value> =
        b.tx.iter()
            .filter_map(|h| ex.tx(*h))
            .map(|t| if full { tx_json(ex, t) } else { json!(t.hash) })
            .collect();
    json!({
        "number": hex(b.number), "hash": b.hash, "parentHash": b.parent, "timestamp": hex(b.timestamp),
        "gasLimit": hex(10_000_000_000), "gasUsed": hex(b.gas_used), "baseFeePerGas": "0x0",
        "miner": Address::ZERO, "difficulty": "0x0", "totalDifficulty": "0x0", "nonce": "0x0000000000000000",
        "mixHash": B256::ZERO, "sha3Uncles": B256::ZERO, "logsBloom": format!("0x{}", "0".repeat(512)),
        "transactionsRoot": B256::ZERO, "stateRoot": B256::ZERO, "receiptsRoot": B256::ZERO,
        "extraData": "0x", "size": "0x0", "uncles": [], "transactions": txs,
    })
}

fn tx_json(ex: &Executor, t: &TxRecord) -> Value {
    let b = ex.block(t.block).expect("tx block");
    json!({
        "hash": t.hash, "nonce": hex(t.nonce), "from": t.from, "to": t.to, "value": t.value, "input": t.input,
        "gas": hex(t.gas_limit), "gasPrice": "0x0", "maxFeePerGas": "0x0", "maxPriorityFeePerGas": "0x0",
        "type": hex(t.ty as u64), "chainId": hex(ex.chain_id), "v": "0x0", "r": "0x0", "s": "0x0", "yParity": "0x0",
        "blockHash": b.hash, "blockNumber": hex(b.number), "transactionIndex": "0x0", "accessList": [],
    })
}

fn logs_json(ex: &Executor, t: &TxRecord) -> Vec<Value> {
    let b = ex.block(t.block).expect("tx block");
    t.logs.iter().enumerate().map(|(i, l)| json!({
        "address": l.address, "topics": l.topics(), "data": l.data.data, "blockNumber": hex(b.number), "blockHash": b.hash,
        "transactionHash": t.hash, "transactionIndex": "0x0", "logIndex": hex(i as u64), "removed": false,
    })).collect()
}

fn receipt_json(ex: &Executor, t: &TxRecord) -> Value {
    let b = ex.block(t.block).expect("tx block");
    json!({
        "transactionHash": t.hash, "transactionIndex": "0x0", "blockHash": b.hash, "blockNumber": hex(b.number),
        "from": t.from, "to": t.to, "contractAddress": t.contract, "cumulativeGasUsed": hex(t.gas_used), "gasUsed": hex(t.gas_used),
        "effectiveGasPrice": "0x0", "status": if t.status { "0x1" } else { "0x0" }, "type": hex(t.ty as u64),
        "logs": logs_json(ex, t), "logsBloom": format!("0x{}", "0".repeat(512)),
        "l1BlockNumber": hex(t.l1.0), "l1BlockHash": t.l1.1,
    })
}

fn block_number(ex: &Executor, v: &Value) -> Result<u64, RpcError> {
    match v.as_str() {
        None | Some("latest" | "pending" | "safe" | "finalized") => Ok(ex.head().number),
        Some("earliest") => Ok(0),
        Some(s) => u64::from_str_radix(s.trim_start_matches("0x"), 16)
            .map_err(|e| RpcError::invalid(e.to_string())),
    }
}

pub fn dispatch(ex: &mut Executor, method: &str, p: &Value) -> Result<Value, RpcError> {
    Ok(match method {
        "eth_chainId" => json!(hex(ex.chain_id)),
        "net_version" => json!(ex.chain_id.to_string()),
        "net_listening" => json!(true),
        "web3_clientVersion" => json!("app-executor/0.1"),
        "eth_accounts" => json!([]),
        "eth_syncing" => json!(false),
        "eth_blockNumber" => json!(hex(ex.head().number)),
        "eth_gasPrice" | "eth_maxPriorityFeePerGas" | "eth_blobBaseFee" => json!("0x0"),
        "eth_feeHistory" => {
            let n: U256 = param(p, 0)?;
            let n = n.saturating_to::<u64>().clamp(1, 1024);
            let newest = block_number(ex, p.get(1).unwrap_or(&Value::Null))?;
            let oldest = newest.saturating_sub(n - 1);
            let count = (newest - oldest + 1) as usize;
            let pct = p
                .get(2)
                .and_then(|x| x.as_array())
                .map(|a| a.len())
                .unwrap_or(0);
            json!({"oldestBlock": hex(oldest), "baseFeePerGas": vec!["0x0"; count + 1], "gasUsedRatio": vec![0.0; count], "reward": vec![vec!["0x0"; pct]; count]})
        }
        "eth_getBlockByNumber" => {
            let n = block_number(ex, p.get(0).unwrap_or(&Value::Null))?;
            let full = p.get(1).and_then(|x| x.as_bool()).unwrap_or(false);
            ex.block(n)
                .map(|b| block_json(ex, &b.clone(), full))
                .unwrap_or(Value::Null)
        }
        "eth_getBlockByHash" => {
            let h: B256 = param(p, 0)?;
            let full = p.get(1).and_then(|x| x.as_bool()).unwrap_or(false);
            ex.block_by_hash(h)
                .cloned()
                .map(|b| block_json(ex, &b, full))
                .unwrap_or(Value::Null)
        }
        "eth_getBalance" | "eth_getTransactionCount" | "eth_getCode" => {
            let a: Address = param(p, 0)?;
            let info = Db(ex.db())
                .basic(a)
                .map_err(|e| ExecError::Unavailable(e.to_string()))?
                .unwrap_or_default();
            match method {
                "eth_getBalance" => json!(info.balance),
                "eth_getTransactionCount" => json!(hex(info.nonce)),
                _ => {
                    let code = Db(ex.db())
                        .code_by_hash(info.code_hash)
                        .map_err(|e| ExecError::Unavailable(e.to_string()))?;
                    json!(code.original_bytes())
                }
            }
        }
        "eth_getStorageAt" => {
            let a: Address = param(p, 0)?;
            let s: U256 = param(p, 1)?;
            let v = Db(ex.db())
                .storage(a, s)
                .map_err(|e| ExecError::Unavailable(e.to_string()))?;
            json!(B256::from(v))
        }
        "eth_call" => {
            let (out, _) = ex.call(&call_of(p.get(0).unwrap_or(&Value::Null))?)?;
            json!(out)
        }
        "eth_estimateGas" => {
            let (_, used) = ex.call(&call_of(p.get(0).unwrap_or(&Value::Null))?)?;
            json!(hex(used + used / 4 + 25_000))
        }
        "eth_sendRawTransaction" => {
            let raw: Bytes = param(p, 0)?;
            json!(ex.send_raw(&raw)?)
        }
        "eth_getTransactionByHash" => {
            let h: B256 = param(p, 0)?;
            ex.tx(h).map(|t| tx_json(ex, t)).unwrap_or(Value::Null)
        }
        "eth_getTransactionReceipt" => {
            let h: B256 = param(p, 0)?;
            ex.tx(h).map(|t| receipt_json(ex, t)).unwrap_or(Value::Null)
        }
        "eth_getLogs" => {
            let f = p.get(0).cloned().unwrap_or(Value::Null);
            let from = block_number(ex, f.get("fromBlock").unwrap_or(&json!("earliest")))?;
            let to = block_number(ex, f.get("toBlock").unwrap_or(&json!("latest")))?;
            let addrs: Vec<Address> = match f.get("address") {
                Some(Value::String(s)) => {
                    vec![s.parse().map_err(|_| RpcError::invalid("address"))?]
                }
                Some(Value::Array(a)) => {
                    a.iter().filter_map(|x| x.as_str()?.parse().ok()).collect()
                }
                _ => vec![],
            };
            let topics: Vec<Option<Vec<B256>>> = f
                .get("topics")
                .and_then(|t| t.as_array())
                .map(|ts| {
                    ts.iter()
                        .map(|t| match t {
                            Value::Null => None,
                            Value::String(s) => s.parse().ok().map(|x| vec![x]),
                            Value::Array(a) => {
                                Some(a.iter().filter_map(|x| x.as_str()?.parse().ok()).collect())
                            }
                            _ => None,
                        })
                        .collect()
                })
                .unwrap_or_default();
            let mut out = vec![];
            for t in ex.txs().iter().filter(|t| t.block >= from && t.block <= to) {
                for (l, j) in t.logs.iter().zip(logs_json(ex, t)) {
                    let addr_ok = addrs.is_empty() || addrs.contains(&l.address);
                    let topics_ok = topics.iter().enumerate().all(|(i, want)| {
                        want.as_ref()
                            .is_none_or(|w| l.topics().get(i).is_some_and(|x| w.contains(x)))
                    });
                    if addr_ok && topics_ok {
                        out.push(j);
                    }
                }
            }
            json!(out)
        }
        "evm_snapshot" => json!(hex(ex.snapshot() as u64)),
        "evm_revert" => {
            let id: U256 = param(p, 0)?;
            json!(ex.revert(id.saturating_to()))
        }
        "executor_pin" => {
            let id = p
                .get(0)
                .and_then(|x| x.as_str())
                .unwrap_or("latest")
                .to_string();
            ex.pin(&id)?
        }
        "executor_status" => ex.status(),
        "executor_evidence" => {
            let pkg = ex.db().evidence().map_err(|e| RpcError {
                code: -32000,
                message: e,
                data: None,
            })?;
            json!({
                "anchor": {"chainId": pkg.anchor.chainId, "number": pkg.anchor.blockNumber, "hash": pkg.anchor.blockHash, "stateRoot": pkg.anchor.stateRoot},
                "accounts": pkg.accounts.iter().map(|a| json!({"address": a.account, "exists": a.exists, "codeBytes": a.code.len()})).collect::<Vec<_>>(),
                "slots": pkg.slots.iter().map(|s| json!({"account": s.account, "slot": s.slot, "value": s.value})).collect::<Vec<_>>(),
                "package": Bytes::from(pkg.abi_encode()),
            })
        }
        _ => {
            return Err(RpcError {
                code: -32601,
                message: format!("method {method} not supported"),
                data: None,
            });
        }
    })
}

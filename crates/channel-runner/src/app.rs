//! App-channel runtime commands (docs/guide/app-channels.md): the MOCK prover that produces
//! checkpoints from the vault's queues, and recovery of every claim from L1 data alone.

use alloy_primitives::{Address, B256, Bytes, U256, hex, keccak256};
use alloy_sol_types::{SolCall, SolEvent};
use channel_app::{
    IAppChannelVault::{self, CheckpointAccepted},
    Ledger, mock_proof,
    recover::{Accepted, recover},
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{Rpc, RunnerError};

fn eth_call<C: SolCall>(rpc: &Rpc, to: Address, call: C) -> Result<C::Return, RunnerError> {
    let out = rpc.call(
        "eth_call",
        json!([{ "to": to, "data": Bytes::from(call.abi_encode()) }, "latest"]),
    )?;
    let bytes: Bytes =
        serde_json::from_value(out).map_err(|e| RunnerError::Other(e.to_string()))?;
    C::abi_decode_returns(&bytes)
        .map_err(|e| RunnerError::Other(format!("decode {}: {e}", C::SIGNATURE)))
}

/// One app action from the operator's batch.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Action {
    Transfer {
        from: Address,
        to: Address,
        token: Address,
        amount: U256,
    },
    Withdraw {
        who: Address,
        token: Address,
        amount: U256,
    },
}

/// Consumes every queued deposit and forced request, applies `actions`, and returns the
/// checkpoint (claim, data, MOCK proof) plus the ledger as it will be once L1 accepts it.
pub fn checkpoint(
    rpc: &Rpc,
    vault: Address,
    id: B256,
    mut ledger: Ledger,
    actions: &[Action],
    terminal: bool,
) -> Result<Value, RunnerError> {
    let n_dep: U256 = eth_call(rpc, vault, IAppChannelVault::depositCountCall { id })?;
    for i in ledger.deposit_cursor..n_dep.to::<u64>() {
        let d = eth_call(
            rpc,
            vault,
            IAppChannelVault::depositsCall {
                id,
                i: U256::from(i),
            },
        )?;
        ledger.consume_deposit(&d);
    }
    for a in actions {
        let r = match *a {
            Action::Transfer {
                from,
                to,
                token,
                amount,
            } => ledger.transfer(from, to, token, amount),
            Action::Withdraw { who, token, amount } => ledger.withdraw(who, token, amount),
        };
        r.map_err(|e| RunnerError::Other(format!("action {a:?}: {e}")))?;
    }
    let n_forced: U256 = eth_call(rpc, vault, IAppChannelVault::forcedCountCall { id })?;
    for i in ledger.forced_cursor..n_forced.to::<u64>() {
        let f = eth_call(
            rpc,
            vault,
            IAppChannelVault::forcedRequestCall {
                id,
                i: U256::from(i),
            },
        )?;
        ledger.consume_forced(&f);
    }
    let claim = ledger.claim(terminal);
    let data = ledger.data();
    let inputs = eth_call(
        rpc,
        vault,
        IAppChannelVault::inputsHashCall {
            id,
            claim: claim.clone(),
            dataHash: keccak256(&data),
        },
    )?;
    ledger.mark_published();
    Ok(json!({
        "claim": claim,
        "data": format!("0x{}", hex::encode(&data)),
        "proof": format!("0x{}", hex::encode(mock_proof(inputs))),
        "inputsHash": inputs,
        "nextState": ledger,
    }))
}

/// Rebuilds the channel's accepted state from `CheckpointAccepted` events and their
/// transactions' calldata, checks it against the vault's roots, and lists every claim:
/// exit and credit leaves with proofs, plus deposits outside the consumed prefix.
pub fn recover_channel(rpc: &Rpc, vault: Address, id: B256) -> Result<Value, RunnerError> {
    let logs = rpc.call(
        "eth_getLogs",
        json!([{ "address": vault, "fromBlock": "0x0", "toBlock": "latest", "topics": [CheckpointAccepted::SIGNATURE_HASH, id] }]),
    )?;
    let mut accepted = Vec::new();
    for l in logs
        .as_array()
        .ok_or_else(|| RunnerError::Other("bad logs".into()))?
    {
        let nonce = U256::from_str_radix(
            l["topics"][2]
                .as_str()
                .unwrap_or("0x0")
                .trim_start_matches("0x"),
            16,
        )
        .map_err(|e| RunnerError::Other(e.to_string()))?
        .to::<u64>();
        let data: Bytes = serde_json::from_value(l["data"].clone())
            .map_err(|e| RunnerError::Other(e.to_string()))?;
        let data_hash = B256::from_slice(&data[32..64]);
        let tx = rpc.call("eth_getTransactionByHash", json!([l["transactionHash"]]))?;
        let input: Bytes = serde_json::from_value(tx["input"].clone())
            .map_err(|e| RunnerError::Other(e.to_string()))?;
        accepted.push(Accepted {
            nonce,
            data_hash,
            calldata: input.to_vec(),
        });
    }
    let ch = eth_call(rpc, vault, IAppChannelVault::channelCall { id })?;
    let (_, out) = recover(id, accepted, ch.exitRoot, ch.creditRoot)
        .map_err(|e| RunnerError::Other(e.to_string()))?;
    let n_dep: U256 = eth_call(rpc, vault, IAppChannelVault::depositCountCall { id })?;
    let refunds: Vec<u64> = (ch.depositCursor..n_dep.to::<u64>()).collect();
    Ok(json!({ "status": ch.status, "recovered": out, "refundDeposits": refunds }))
}

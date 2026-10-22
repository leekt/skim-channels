//! `skim-channels`: JSON-out commands for the channel runtime and the e2e demo.
//!
//! - `header --rpc URL --block ID --chain-id N`: hash-checked raw header and its anchor.
//! - `witness --rpc URL --block-hash H --chain-id N --read ADDR:SLOT[:SLOT..] [--code ADDR]`:
//!   a verified witness package (abi-encoded) at that block's authenticated root.
//! - `evidence --rpc URL --tx HASH`: receipt inclusion evidence from an L2 block.

use std::collections::BTreeMap;

use alloy_primitives::{Address, B256, hex};
use alloy_sol_types::SolValue;
use channel_runner::{Rpc, anchor_of, fetch_header, receipt_evidence};
use channel_witness::{package_hash, source::{SkimRpc, collect_witness}};
use clap::{Parser, Subcommand};
use serde_json::json;

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    Header {
        #[arg(long)]
        rpc: String,
        #[arg(long)]
        block: String,
        #[arg(long)]
        chain_id: u64,
    },
    Witness {
        #[arg(long)]
        rpc: String,
        #[arg(long)]
        block_hash: B256,
        #[arg(long)]
        chain_id: u64,
        /// ADDRESS:SLOT[:SLOT...]
        #[arg(long)]
        read: Vec<String>,
        #[arg(long)]
        code: Vec<Address>,
    },
    Evidence {
        #[arg(long)]
        rpc: String,
        #[arg(long)]
        tx: B256,
    },
}

fn main() {
    if let Err(e) = run(Cli::parse()) {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> Result<(), Box<dyn std::error::Error>> {
    let out = match cli.cmd {
        Cmd::Header { rpc, block, chain_id } => {
            let h = fetch_header(&Rpc::new(rpc), &block)?;
            let a = anchor_of(chain_id, &h);
            json!({ "raw": h.raw, "hash": h.hash, "number": h.header.number, "stateRoot": h.header.state_root, "anchorId": a.id() })
        }
        Cmd::Witness { rpc, block_hash, chain_id, read, code } => {
            let h = fetch_header(&Rpc::new(rpc.clone()), &block_hash.to_string())?;
            let anchor = anchor_of(chain_id, &h);
            let mut reads: BTreeMap<Address, (Vec<B256>, bool)> = BTreeMap::new();
            for r in &read {
                let mut parts = r.split(':');
                let a: Address = parts.next().ok_or("empty --read")?.parse()?;
                let e = reads.entry(a).or_default();
                for s in parts {
                    e.0.push(s.parse()?);
                }
            }
            for a in code {
                reads.entry(a).or_default().1 = true;
            }
            let pkg = collect_witness(&SkimRpc::new(rpc), &anchor, &reads)?;
            json!({ "anchorId": anchor.id(), "rawHeader": h.raw, "package": hex::encode_prefixed(pkg.abi_encode()), "packageHash": package_hash(&pkg) })
        }
        Cmd::Evidence { rpc, tx } => {
            let e = receipt_evidence(&Rpc::new(rpc), tx)?;
            json!({
                "l2BlockHash": e.block_hash, "l2Header": e.header, "txIndex": e.tx_index, "receipt": e.receipt,
                "receiptProof": e.proof, "receiptsRoot": e.receipts_root, "blockNumber": e.block_number,
            })
        }
    };
    println!("{out}");
    Ok(())
}

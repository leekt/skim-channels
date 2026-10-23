//! `app-executor --l1 URL --chain-id 7001 --import 0x… [--import 0x…] [--pin latest] [--port 18902]`

use std::{
    collections::BTreeSet,
    net::TcpListener,
    sync::{Arc, Mutex},
};

use alloy_primitives::{Address, U256};
use app_executor::{exec::Executor, http::serve};
use clap::Parser;

#[derive(Parser)]
struct Args {
    /// L1 JSON-RPC (a skim node; any node with eth_getProof works).
    #[arg(long)]
    l1: String,
    /// The app network's chain id.
    #[arg(long, default_value_t = 7001)]
    chain_id: u64,
    /// L1 accounts the app imports. Every other address is app-local.
    #[arg(long = "import")]
    imports: Vec<Address>,
    /// The first pin: a tag (latest, safe, finalized), a number, or a block hash.
    #[arg(long, default_value = "latest")]
    pin: String,
    #[arg(long, default_value_t = 18902)]
    port: u16,
    /// Genesis ETH for an app-local account: ADDRESS=WEI (repeatable). Imported accounts
    /// can't be funded: their balances are L1's.
    #[arg(long = "alloc")]
    allocs: Vec<String>,
}

fn main() {
    let a = Args::parse();
    let fail = |e: String| -> ! {
        eprintln!("app-executor: {e}");
        std::process::exit(1)
    };
    let mut ex = Executor::new(
        &a.l1,
        a.chain_id,
        a.imports.into_iter().collect::<BTreeSet<_>>(),
        &a.pin,
    )
    .unwrap_or_else(|e| fail(e));
    for s in &a.allocs {
        let (addr, wei) = s
            .split_once('=')
            .unwrap_or_else(|| fail(format!("--alloc {s}: want ADDRESS=WEI")));
        let addr: Address = addr
            .parse()
            .unwrap_or_else(|e| fail(format!("--alloc {s}: {e}")));
        let wei: U256 = wei
            .parse()
            .unwrap_or_else(|e| fail(format!("--alloc {s}: {e}")));
        ex.alloc(addr, wei).unwrap_or_else(|e| fail(e));
    }
    let pin = ex.anchor().clone();
    let listener = TcpListener::bind(("127.0.0.1", a.port)).unwrap_or_else(|e| {
        eprintln!("app-executor: port {}: {e}", a.port);
        std::process::exit(1)
    });
    println!(
        "app-executor: chain {} on 127.0.0.1:{}, L1 chain {} pinned at {} {}",
        a.chain_id, a.port, pin.chainId, pin.blockNumber, pin.blockHash
    );
    serve(listener, Arc::new(Mutex::new(ex)));
}

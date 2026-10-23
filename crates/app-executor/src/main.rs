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
    /// L1 accounts the app imports read-only: no overlay writes, so reads are always L1's.
    #[arg(long = "import-readonly")]
    readonly: Vec<Address>,
    /// The first pin: a tag (latest, safe, finalized), a number, or a block hash.
    #[arg(long, default_value = "latest")]
    pin: String,
    #[arg(long, default_value_t = 18902)]
    port: u16,
    /// The L1 tag to follow (`latest`, `safe`, `finalized`), or `none` to stay where pinned.
    #[arg(long, default_value = "latest")]
    follow: String,
    /// How often to check the followed tag, in milliseconds.
    #[arg(long, default_value_t = 1000)]
    follow_ms: u64,
    /// Where the follower keeps its stream cursor across restarts.
    #[arg(long)]
    state_dir: Option<std::path::PathBuf>,
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
        a.readonly.into_iter().collect::<BTreeSet<_>>(),
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
    if a.follow != "none" {
        ex.set_follow(Some(a.follow.clone()));
    }
    let ex = Arc::new(Mutex::new(ex));
    if a.follow != "none" {
        let (ex, l1, tag) = (ex.clone(), a.l1.clone(), a.follow.clone());
        let every = std::time::Duration::from_millis(a.follow_ms);
        let dir = a.state_dir.clone();
        std::thread::spawn(move || app_executor::follow::run(ex, l1, tag, every, dir));
    }
    println!(
        "app-executor: chain {} on 127.0.0.1:{}, L1 chain {} pinned at {} {}",
        a.chain_id, a.port, pin.chainId, pin.blockNumber, pin.blockHash
    );
    serve(listener, ex);
}

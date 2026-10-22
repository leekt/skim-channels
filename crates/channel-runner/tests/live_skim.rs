//! Against a live skim node (`SKIM_RPC`, e.g. http://127.0.0.1:8545) on Sepolia: an anchor
//! promoted only by skim's light-client-authenticated `finalized` (and `safe`) head, and a
//! witness collected from skim at exactly that root and verified locally. Skipped unless
//! SKIM_RPC is set. Prints the measurements recorded in docs/HANDOFF.md.

use std::time::Instant;

use alloy_primitives::{Address, B256, address};
use channel_runner::{RpcConfirmations, observe_back};
use channel_types::ConfirmationPolicy;
use channel_witness::{
    ReadKey,
    anchor::{AnchorBook, ConfirmationSource, Mode},
    package_hash,
    source::{SkimRpc, collect_witness},
    testkit::reads,
};

/// WETH on Sepolia: slot 0 (name), slot 2 (decimals), and the contract's code.
const WETH: Address = address!("7b79995e5f793A07Bc00c21412e50Ecae098E7f9");

fn live(level: ConfirmationPolicy) {
    let Ok(url) = std::env::var("SKIM_RPC") else {
        eprintln!("skipped: SKIM_RPC not set");
        return;
    };
    let src = RpcConfirmations::skim(url.clone());
    let head = src
        .head(level)
        .expect("skim has no authenticated head at this level yet");
    assert!(head.authenticated);
    let mut book = AnchorBook::new(11155111, level, Mode::Authenticated).unwrap();
    let anchors = observe_back(&mut book, src.rpc(), head.hash, 3).unwrap();
    let anchor = anchors[0].clone();
    let slots = [B256::ZERO, B256::with_last_byte(2)];
    let t = Instant::now();
    let pkg =
        collect_witness(&SkimRpc::new(url), &anchor, &reads(&[(WETH, &slots, true)])).unwrap();
    let ms = t.elapsed().as_millis();
    book.attach(anchor.blockHash, &pkg).unwrap();
    let keys = [
        ReadKey::Storage(WETH, slots[0]),
        ReadKey::Storage(WETH, slots[1]),
        ReadKey::Code(WETH),
    ];
    assert!(
        book.executable(anchor.id(), &keys).is_err(),
        "not executable before promotion"
    );
    book.promote(&src);
    let w = book
        .executable(anchor.id(), &keys)
        .expect("authenticated anchor with a witness must be executable");
    // Older observed anchors are confirmed too (they link to the head).
    assert!(book.status(anchors[2].id()).is_some());
    let bytes = alloy_sol_types::SolValue::abi_encode(&pkg).len();
    println!(
        "{level:?} block {} ({}): decimals={} witness {} bytes, collected in {ms} ms, package {}",
        anchor.blockNumber,
        anchor.blockHash,
        w.storage(WETH, slots[1]).unwrap(),
        bytes,
        package_hash(&pkg)
    );
    assert_eq!(
        w.storage(WETH, slots[1]).unwrap(),
        alloy_primitives::U256::from(18)
    );
}

#[test]
fn live_skim_finalized_anchor() {
    live(ConfirmationPolicy::Finalized);
}

#[test]
fn live_skim_safe_anchor() {
    live(ConfirmationPolicy::Safe);
}

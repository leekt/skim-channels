//! Against a real beacon node running the Fast Confirmation Rule (Lighthouse
//! `--enable-fast-confirmation`) and its EL: the next `fast_confirmation` event promotes an
//! FCR anchor, with a witness collected at that exact root. Skipped unless BEACON_URL and
//! EL_URL are set. Prints how far the FCR block is ahead of `finalized`.

use std::time::Instant;

use alloy_primitives::B256;
use channel_runner::{
    FcrConfirmations, FcrHead, Rpc, RpcConfirmations, anchor_of, fetch_header, observe_back,
};
use channel_types::ConfirmationPolicy;
use channel_witness::{
    ReadKey,
    anchor::{AnchorBook, Mode},
    source::{SkimRpc, collect_witness},
    testkit::reads,
};

#[test]
fn live_fcr_anchor() {
    let (Ok(beacon), Ok(el)) = (std::env::var("BEACON_URL"), std::env::var("EL_URL")) else {
        eprintln!("skipped: BEACON_URL / EL_URL not set");
        return;
    };
    let chain_id: u64 = Rpc::new(el.clone())
        .call("eth_chainId", serde_json::json!([]))
        .ok()
        .and_then(|v| {
            v.as_str()
                .and_then(|s| u64::from_str_radix(s.trim_start_matches("0x"), 16).ok())
        })
        .expect("chain id");
    let fcr = FcrConfirmations::new(beacon, el.clone());
    let t = Instant::now();
    let c = fcr.next().expect("a fast_confirmation event");
    let waited = t.elapsed().as_millis();
    let head = fetch_header(&Rpc::new(el.clone()), &c.hash.to_string()).unwrap();
    let anchor = anchor_of(chain_id, &head);
    // The beacon deposit contract always exists on these devnets; any account works.
    let who = alloy_primitives::address!("4242424242424242424242424242424242424242");
    let pkg = collect_witness(
        &SkimRpc::new(el.clone()),
        &anchor,
        &reads(&[(who, &[B256::ZERO], false)]),
    )
    .unwrap();
    let mut book = AnchorBook::new(
        chain_id,
        ConfirmationPolicy::FcrConfirmed,
        Mode::Authenticated,
    )
    .unwrap();
    observe_back(&mut book, &Rpc::new(el.clone()), c.hash, 2).unwrap();
    book.attach(c.hash, &pkg).unwrap();
    let keys = [ReadKey::Storage(who, B256::ZERO)];
    // `safe` / `finalized` from the same node are not FCR evidence.
    book.promote(&RpcConfirmations::skim(el.clone()));
    assert!(book.executable(anchor.id(), &keys).is_err());
    book.promote(&FcrHead(Some(c)));
    assert!(book.executable(anchor.id(), &keys).is_ok());
    let fin = fetch_header(&Rpc::new(el.clone()), "finalized")
        .map(|h| h.header.number)
        .unwrap_or(0);
    let latest = fetch_header(&Rpc::new(el), "latest").unwrap().header.number;
    println!(
        "FCR block {} (latest {latest}, finalized {fin}): {} blocks ahead of finalized, {} behind latest; event after {waited} ms",
        c.number,
        c.number.saturating_sub(fin),
        latest.saturating_sub(c.number)
    );
}

//! Integration against a real node (anvil, if installed): header hashing, witnesses, receipt
//! evidence and confirmation handling. Skipped (with a message) when anvil isn't on PATH.

use std::{
    io::{BufRead, BufReader, Read, Write},
    net::TcpListener,
    process::{Child, Command, Stdio},
    time::Duration,
};

use alloy_primitives::{Address, B256, address};
use channel_runner::{
    Rpc, RpcConfirmations, RunnerError, anchor_of, fetch_header, observe_back, receipt_evidence,
};
use channel_types::ConfirmationPolicy;
use channel_witness::{
    ReadKey,
    anchor::{AnchorBook, Mode},
    source::{SkimRpc, collect_witness},
    testkit::reads,
};
use serde_json::{Value, json};

struct Anvil(Child, String);

impl Drop for Anvil {
    fn drop(&mut self) {
        let _ = self.0.kill();
    }
}

fn anvil(port: u16) -> Option<Anvil> {
    let child = Command::new("anvil")
        .args([
            "--port",
            &port.to_string(),
            "--hardfork",
            "prague",
            "--silent",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let a = Anvil(child, format!("http://127.0.0.1:{port}"));
    for _ in 0..50 {
        if Rpc::new(a.1.clone()).call("eth_chainId", json!([])).is_ok() {
            return Some(a);
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    None
}

const DEV: Address = address!("f39Fd6e51aad88F6F4ce6aB8827279cffFb92266");

/// Sends and waits until mined (anvil answers eth_sendTransaction before mining).
fn send_value(rpc: &Rpc) -> B256 {
    let tx = rpc
        .call("eth_sendTransaction", json!([{ "from": DEV, "to": "0x0000000000000000000000000000000000001234", "value": "0x1" }]))
        .unwrap();
    for _ in 0..100 {
        if !rpc
            .call("eth_getTransactionReceipt", json!([tx]))
            .unwrap()
            .is_null()
        {
            return tx.as_str().unwrap().parse().unwrap();
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("not mined");
}

#[test]
fn anvil_headers_witnesses_receipts_and_confirmations() {
    let Some(node) = anvil(18745) else {
        eprintln!("skipped: anvil not available");
        return;
    };
    let rpc = Rpc::new(node.1.clone());
    // anvil's genesis header claims the empty state root while its dev accounts hold ether:
    // a witness against that root must fail, not return the funded account.
    let genesis = fetch_header(&rpc, "0x0").unwrap();
    assert!(
        collect_witness(
            &SkimRpc::new(node.1.clone()),
            &anchor_of(31337, &genesis),
            &reads(&[(DEV, &[], false)])
        )
        .is_err()
    );

    let tx = send_value(&rpc);
    send_value(&rpc);

    // Header hashing + witness at the authenticated root.
    let head = fetch_header(&rpc, "latest").unwrap();
    let anchor = anchor_of(31337, &head);
    let pkg = collect_witness(
        &SkimRpc::new(node.1.clone()),
        &anchor,
        &reads(&[(DEV, &[B256::ZERO], false)]),
    )
    .unwrap();
    channel_witness::verify(&pkg, &anchor).unwrap();

    // Receipt evidence rebuilds the block's receipts root.
    let ev = receipt_evidence(&rpc, tx).unwrap();
    channel_receipts::verify_receipt(ev.receipts_root, ev.tx_index, &ev.receipt, &ev.proof)
        .unwrap();

    // anvil is not an authenticated source: a Finalized book never promotes from it ...
    let src = RpcConfirmations::unauthenticated(node.1.clone());
    let mut book =
        AnchorBook::new(31337, ConfirmationPolicy::Finalized, Mode::Authenticated).unwrap();
    observe_back(&mut book, src.rpc(), head.hash, 4).unwrap();
    book.attach(head.hash, &pkg).unwrap();
    book.promote(&src);
    let keys = [ReadKey::Storage(DEV, B256::ZERO)];
    assert!(book.executable(anchor.id(), &keys).is_err());
    // ... while a labeled optimistic experiment may use its latest head.
    let mut exp = AnchorBook::new(
        31337,
        ConfirmationPolicy::Latest,
        Mode::OptimisticExperiment,
    )
    .unwrap();
    observe_back(&mut exp, src.rpc(), head.hash, 1).unwrap();
    exp.attach(head.hash, &pkg).unwrap();
    exp.promote(&src);
    assert!(exp.executable(anchor.id(), &keys).is_ok());
}

/// Serves one JSON-RPC answer (the real block with a modified state root) and exits.
fn lying_server(body: Value) -> String {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    std::thread::spawn(move || {
        if let Ok((mut s, _)) = l.accept() {
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut len = 0usize;
            loop {
                let mut line = String::new();
                r.read_line(&mut line).unwrap();
                if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    len = v.trim().parse().unwrap();
                }
                if line == "\r\n" {
                    break;
                }
            }
            let mut buf = vec![0; len];
            r.read_exact(&mut buf).unwrap();
            let resp = json!({"jsonrpc": "2.0", "id": 1, "result": body}).to_string();
            write!(
                s,
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
                resp.len(),
                resp
            )
            .unwrap();
        }
    });
    url
}

#[test]
fn a_header_with_a_swapped_state_root_is_refused() {
    let Some(node) = anvil(18746) else {
        eprintln!("skipped: anvil not available");
        return;
    };
    let rpc = Rpc::new(node.1.clone());
    send_value(&rpc);
    let mut block = rpc
        .call("eth_getBlockByNumber", json!(["latest", false]))
        .unwrap();
    let hash = block["hash"].as_str().unwrap().to_string();
    block["stateRoot"] = json!(B256::repeat_byte(0x66));
    let liar = Rpc::new(lying_server(block));
    assert!(matches!(
        fetch_header(&liar, &hash),
        Err(RunnerError::HeaderHash(_))
    ));
}

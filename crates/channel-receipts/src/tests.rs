use alloy_consensus::proofs::calculate_receipt_root;
use alloy_primitives::Bytes;
use alloy_sol_types::SolEvent;
use proptest::prelude::*;

use crate::{fixtures::*, *};

fn block() -> (Vec<Bytes>, B256) {
    let enc = encoded_receipts();
    let root = receipts_root(&enc);
    (enc, root)
}

#[test]
fn root_matches_alloy_consensus() {
    let receipts: Vec<_> = (0..RECEIPT_COUNT).map(receipt).collect();
    let (_, root) = block();
    assert_eq!(root, calculate_receipt_root(&receipts));
}

#[test]
fn every_index_proves_and_decodes() {
    let (enc, root) = block();
    for i in 0..RECEIPT_COUNT {
        let p = receipt_proof(&enc, i).unwrap();
        verify_receipt(root, i, &enc[i], &p).unwrap();
        let r = decode_receipt(&enc[i]).unwrap();
        assert_eq!(r, receipt(i));
        assert_eq!(succeeded(&r), i % 7 != 3);
        if i % 5 != 0 {
            assert_eq!(
                enc[i][0],
                (i % 5) as u8,
                "typed receipts keep their type prefix"
            );
        }
    }
    assert!(receipt_proof(&enc, RECEIPT_COUNT).is_err());
}

#[test]
fn outcome_logs_are_where_expected() {
    let (enc, _) = block();
    for (i, emitter) in OUTCOME_AT {
        let r = decode_receipt(&enc[i]).unwrap();
        let log = &logs(&r)[1];
        assert_eq!(log.address, emitter);
        assert_eq!(log.topics()[0], ChannelOutcome::SIGNATURE_HASH);
        let ev = ChannelOutcome::decode_log_data(&log.data).unwrap();
        assert_eq!(ev.outcomeHash, keccak256(format!("outcome-{i}")));
    }
}

#[test]
fn wrong_index_or_receipt_is_rejected() {
    let (enc, root) = block();
    let p = receipt_proof(&enc, 2).unwrap();
    // Same proof, other index / other receipt.
    assert_eq!(
        verify_receipt(root, 3, &enc[2], &p),
        Err(ReceiptError::BadProof)
    );
    assert_eq!(
        verify_receipt(root, 2, &enc[3], &p),
        Err(ReceiptError::BadProof)
    );
    // A receipt from index 129 (also a ChannelOutcome) presented at index 2.
    assert_eq!(
        verify_receipt(root, 2, &enc[129], &p),
        Err(ReceiptError::BadProof)
    );
    // Another block's root.
    assert_eq!(
        verify_receipt(keccak256("other"), 2, &enc[2], &p),
        Err(ReceiptError::BadProof)
    );
}

#[test]
fn modified_trie_nodes_are_rejected() {
    let (enc, root) = block();
    let p = receipt_proof(&enc, 128).unwrap();
    for n in 0..p.len() {
        let mut bad = p.clone();
        let mut node = bad[n].to_vec();
        let last = node.len() - 1;
        node[last] ^= 1;
        bad[n] = node.into();
        assert!(
            verify_receipt(root, 128, &enc[128], &bad).is_err(),
            "node {n}"
        );
    }
    let mut short = p.clone();
    short.pop();
    assert!(verify_receipt(root, 128, &enc[128], &short).is_err());
    assert_eq!(
        verify_receipt(
            root,
            128,
            &enc[128],
            &vec![Bytes::new(); MAX_RECEIPT_PROOF_NODES + 1]
        ),
        Err(ReceiptError::TooLarge)
    );
}

#[test]
fn modified_type_or_status_is_rejected() {
    let (enc, root) = block();
    let i = 2; // EIP-1559, successful, ChannelOutcome
    let p = receipt_proof(&enc, i).unwrap();
    // Type prefix changed (1559 → 2930): still decodes, but no longer proves.
    let mut retyped = enc[i].to_vec();
    retyped[0] = 0x01;
    assert!(decode_receipt(&retyped).is_ok());
    assert_eq!(
        verify_receipt(root, i, &retyped, &p),
        Err(ReceiptError::BadProof)
    );
    // Type prefix dropped (presented as legacy).
    assert!(verify_receipt(root, i, &enc[i][1..], &p).is_err());
    // Unknown type.
    let mut unknown = enc[i].to_vec();
    unknown[0] = 0x7f;
    assert!(decode_receipt(&unknown).is_err());
    // Status flipped: a failed receipt re-encoded as successful.
    let failed = 3;
    let mut r = receipt(failed);
    assert!(!r.status());
    if let ReceiptEnvelope::Eip4844(rb) = &mut r {
        rb.receipt.status = true.into();
    }
    let flipped = r.encoded_2718();
    let pf = receipt_proof(&enc, failed).unwrap();
    assert_eq!(
        verify_receipt(root, failed, &flipped, &pf),
        Err(ReceiptError::BadProof)
    );
}

#[test]
fn trailing_bytes_are_not_a_receipt() {
    let (enc, _) = block();
    let mut long = enc[2].to_vec();
    long.push(0);
    assert!(decode_receipt(&long).is_err());
}

#[test]
fn header_commits_to_the_root() {
    let (_, root) = block();
    let raw = alloy_rlp::encode(header(root));
    let (hash, h) = decode_header(&raw).unwrap();
    assert_eq!(hash, keccak256(&raw));
    assert_eq!(h.receipts_root, root);
    let mut long = raw.clone();
    long.push(0);
    assert!(decode_header(&long).is_err());
}

#[test]
fn fixtures_are_current() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../fixtures/receipts/block-130.json"
    );
    let text = serde_json::to_string_pretty(&generate()).unwrap() + "\n";
    if std::env::var_os("UPDATE_FIXTURES").is_some() {
        std::fs::write(path, &text).unwrap();
    }
    let on_disk =
        std::fs::read_to_string(path).expect("missing fixture: run with UPDATE_FIXTURES=1");
    assert_eq!(
        on_disk, text,
        "fixture is stale: rerun with UPDATE_FIXTURES=1"
    );
}

proptest! {
    #[test]
    fn random_receipt_sets_prove(n in 1usize..300, pick in any::<prop::sample::Index>(), gas in any::<u64>()) {
        let enc: Vec<Bytes> = (0..n).map(|i| {
            let mut r = receipt(i);
            let (ReceiptEnvelope::Legacy(rb) | ReceiptEnvelope::Eip2930(rb) | ReceiptEnvelope::Eip1559(rb)
                | ReceiptEnvelope::Eip4844(rb) | ReceiptEnvelope::Eip7702(rb)) = &mut r;
            rb.receipt.cumulative_gas_used = gas.wrapping_add(i as u64);
            Bytes::from(r.encoded_2718())
        }).collect();
        let root = receipts_root(&enc);
        let i = pick.index(n);
        let p = receipt_proof(&enc, i).unwrap();
        prop_assert!(verify_receipt(root, i, &enc[i], &p).is_ok());
        let j = (i + 1) % n;
        if j != i {
            prop_assert!(verify_receipt(root, j, &enc[i], &p).is_err());
        }
    }

    #[test]
    fn receipt_decode_never_panics(data in proptest::collection::vec(any::<u8>(), 0..512)) {
        if let Ok(r) = decode_receipt(&data) {
            prop_assert_eq!(r.encoded_2718(), data);
        }
    }
}

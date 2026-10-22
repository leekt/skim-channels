use super::*;
use crate::recover::{Accepted, recover};
use alloy_primitives::address;
use alloy_sol_types::SolCall;
use proptest::prelude::*;

const ETH: Address = Address::ZERO;
const USD: Address = address!("00000000000000000000000000000000000000d0");
const A: Address = address!("00000000000000000000000000000000000000a1");
const B: Address = address!("00000000000000000000000000000000000000b2");
const C: Address = address!("00000000000000000000000000000000000000c3");

fn verify(root: B256, exits: bool, p: &LeafProof) -> bool {
    let mut h = leaf(exits, p.recipient, p.token, p.value);
    for (i, s) in p.siblings.iter().enumerate() {
        h = if (p.index >> i) & 1 == 0 {
            keccak256([h.as_slice(), s.as_slice()].concat())
        } else {
            keccak256([s.as_slice(), h.as_slice()].concat())
        };
    }
    h == root
}

fn checkpoint(l: &mut Ledger, id: B256, nonce: u64, cps: &mut Vec<Accepted>) {
    let claim = l.claim(false);
    let data = l.data();
    let calldata = submitCheckpointCall {
        id,
        claim,
        data: data.clone().into(),
        proof: vec![].into(),
    }
    .abi_encode();
    cps.push(Accepted {
        nonce,
        data_hash: keccak256(&data),
        calldata,
    });
    l.mark_published();
}

#[test]
fn ledger_state_roundtrips_through_json() {
    let mut l = Ledger::default();
    l.consume_deposit(&Deposit {
        owner: A,
        token: USD,
        amount: U256::from(7),
    });
    l.withdraw(A, USD, U256::from(2)).unwrap();
    let back: Ledger = serde_json::from_str(&serde_json::to_string(&l).unwrap()).unwrap();
    assert_eq!(back, l);
}

#[test]
fn proofs_verify_and_empty_tree_is_zero() {
    let mut t = Table::default();
    assert_eq!(t.root(true), B256::ZERO);
    t.set(A, ETH, U256::from(5));
    t.set(B, USD, U256::from(7));
    t.set(C, ETH, U256::from(9));
    let root = t.root(true);
    for e in t.sorted() {
        let p = t.proof(true, e.recipient, e.token).unwrap();
        assert!(verify(root, true, &p));
        assert!(!verify(root, false, &p), "exit leaf is not a credit leaf");
    }
}

#[test]
fn recovery_replays_net_diffs_including_deletions() {
    let id = B256::repeat_byte(1);
    let mut l = Ledger::default();
    let mut cps = Vec::new();
    l.consume_deposit(&Deposit {
        owner: A,
        token: ETH,
        amount: U256::from(10),
    });
    l.consume_deposit(&Deposit {
        owner: B,
        token: USD,
        amount: U256::from(50),
    });
    checkpoint(&mut l, id, 1, &mut cps);
    l.transfer(A, C, ETH, U256::from(10)).unwrap(); // A's balance goes to zero: a deletion
    l.withdraw(B, USD, U256::from(20)).unwrap();
    checkpoint(&mut l, id, 2, &mut cps);
    l.transfer(C, A, ETH, U256::from(3)).unwrap(); // provisional: never accepted
    let accepted = (
        cps.len(),
        l.published_balances.root(true),
        l.published_credits.root(false),
    );
    let (rec, out) = recover(id, cps, accepted.1, accepted.2).unwrap();
    assert_eq!(out.nonce, 2);
    assert_eq!(rec.balances.get(A, ETH), U256::ZERO);
    assert_eq!(rec.balances.get(C, ETH), U256::from(10));
    assert_eq!(rec.credits.get(B, USD), U256::from(20));
    for p in &out.exits {
        assert!(verify(out.exit_root, true, p));
    }
}

#[test]
fn recovery_rejects_tampering() {
    let id = B256::repeat_byte(1);
    let mut l = Ledger::default();
    let mut cps = Vec::new();
    l.consume_deposit(&Deposit {
        owner: A,
        token: ETH,
        amount: U256::from(10),
    });
    checkpoint(&mut l, id, 1, &mut cps);
    let (er, cr) = (l.balances.root(true), l.credits.root(false));
    let mut bad = std::mem::take(&mut cps);
    bad[0].data_hash = B256::ZERO;
    assert!(recover(id, bad, er, cr).is_err(), "data hash");
    let mut l2 = Ledger::default();
    let mut cps2 = Vec::new();
    l2.consume_deposit(&Deposit {
        owner: A,
        token: ETH,
        amount: U256::from(10),
    });
    checkpoint(&mut l2, id, 1, &mut cps2);
    assert!(
        recover(B256::repeat_byte(2), cps2, er, cr).is_err(),
        "other channel"
    );
    assert!(recover(id, vec![], er, cr).is_err(), "missing checkpoints");
    let mut l3 = Ledger::default();
    let mut cps3 = Vec::new();
    l3.consume_deposit(&Deposit {
        owner: A,
        token: ETH,
        amount: U256::from(10),
    });
    checkpoint(&mut l3, id, 1, &mut cps3);
    let dup = Accepted {
        nonce: cps3[0].nonce,
        data_hash: cps3[0].data_hash,
        calldata: cps3[0].calldata.clone(),
    };
    let (er3, cr3) = (l3.balances.root(true), l3.credits.root(false));
    assert!(
        recover(
            id,
            vec![
                dup,
                Accepted {
                    nonce: 1,
                    data_hash: cps3[0].data_hash,
                    calldata: cps3[0].calldata.clone()
                }
            ],
            er3,
            cr3
        )
        .is_err(),
        "duplicated checkpoint events"
    );
    assert!(
        recover(id, cps3, B256::repeat_byte(7), cr).is_err(),
        "replay doesn't reach the vault's accepted root"
    );
}

/// `fixtures/app/tree.json`, checked by contracts/test/app/AppTreeFixture.t.sol.
#[test]
fn tree_fixture_is_current() {
    let mut l = Ledger::default();
    l.consume_deposit(&Deposit {
        owner: A,
        token: ETH,
        amount: U256::from(10u64.pow(18)),
    });
    l.consume_deposit(&Deposit {
        owner: B,
        token: USD,
        amount: U256::from(500_000_000u64),
    });
    l.consume_deposit(&Deposit {
        owner: C,
        token: ETH,
        amount: U256::from(2),
    });
    let d1 = l.data();
    l.mark_published();
    l.transfer(A, B, ETH, U256::from(10u64.pow(18))).unwrap();
    l.withdraw(B, USD, U256::from(200_000_000u64)).unwrap();
    let d2 = l.data();
    let exit_root = l.balances.root(true);
    let credit_root = l.credits.root(false);
    let p = l.balances.proof(true, B, ETH).unwrap();
    let out = serde_json::json!({
        "_comment": "Generated by channel-app (UPDATE_FIXTURES=1 cargo test -p channel-app). Do not edit.",
        "diffs": [format!("0x{}", alloy_primitives::hex::encode(&d1)), format!("0x{}", alloy_primitives::hex::encode(&d2))],
        "exitRoot": exit_root, "creditRoot": credit_root,
        "proof": { "recipient": p.recipient, "token": p.token, "value": B256::from(p.value), "index": p.index, "siblings": p.siblings },
        "stateRoot": l.claim(false).stateRoot,
    });
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/app/tree.json");
    let text = serde_json::to_string_pretty(&out).unwrap() + "\n";
    if std::env::var_os("UPDATE_FIXTURES").is_some() {
        std::fs::write(path, &text).unwrap();
    }
    assert_eq!(
        std::fs::read_to_string(path).expect("run with UPDATE_FIXTURES=1"),
        text,
        "stale fixture"
    );
}

proptest! {
    /// Any sequence of operations, checkpointed at random: replaying the published diffs
    /// rebuilds exactly the accepted state, and per-token value is conserved.
    #[test]
    fn replay_matches_and_conserves(ops in proptest::collection::vec((0u8..4, 0usize..3, 0usize..3, any::<bool>(), 1u64..100), 1..60)) {
        let users = [A, B, C];
        let id = B256::repeat_byte(9);
        let mut l = Ledger::default();
        let mut cps = Vec::new();
        let mut deposited = [U256::ZERO; 2];
        for (op, u, v, usd, amt) in ops {
            let t = if usd { USD } else { ETH };
            let ti = usd as usize;
            let amt = U256::from(amt);
            match op {
                0 => { l.consume_deposit(&Deposit { owner: users[u], token: t, amount: amt }); deposited[ti] += amt; }
                1 => { let _ = l.transfer(users[u], users[v], t, amt); }
                2 => { let _ = l.withdraw(users[u], t, amt); }
                _ => { let n = cps.len() as u64 + 1; checkpoint(&mut l, id, n, &mut cps); }
            }
        }
        let n = cps.len() as u64 + 1;
        checkpoint(&mut l, id, n, &mut cps);
        let (rec, _) = recover(id, cps, l.balances.root(true), l.credits.root(false)).unwrap();
        prop_assert_eq!(&rec.balances, &l.balances);
        prop_assert_eq!(&rec.credits, &l.credits);
        for (ti, t) in [ETH, USD].into_iter().enumerate() {
            let b: U256 = rec.balances.sorted().iter().filter(|e| e.token == t).map(|e| e.value).sum();
            let c: U256 = rec.credits.sorted().iter().filter(|e| e.token == t).map(|e| e.value).sum();
            prop_assert_eq!(b + c, deposited[ti], "sum(B) + sum(E) = D");
        }
    }
}

use std::collections::{BTreeMap, HashMap};

use alloy_primitives::{Address, B256, Bytes, U64, U256, address, b256, hex};
use alloy_sol_types::SolValue;
use channel_types::{ConfirmationPolicy, L1Anchor};
use proptest::prelude::*;

use crate::{
    anchor::{
        AnchorBook, AnchorError, Confirmation, ConfirmationSource, Invalidation, Mode, Status,
    },
    readiness::{CachedValue, LocalState, Provenance, readiness},
    source::{ProofResponse, ProofSource, SourceError, StorageProofResponse, collect_witness},
    testkit::{MockAccount, MockState, reads},
    *,
};

const CHAIN: u64 = 11155111;
const FIXTURE: Address = address!("a110ca7e00000000000000000000000000000001");
const SHARE_SLOT: B256 = B256::ZERO; // AllocationFixture.shareBps
const OTHER: Address = address!("0000000000000000000000000000000000000b0b");
const NOBODY: Address = address!("00000000000000000000000000000000deadbeef");

fn state(share_bps: u64) -> MockState {
    let mut s = MockState::default();
    s.accounts.insert(
        OTHER,
        MockAccount {
            nonce: 3,
            balance: U256::from(10u64).pow(U256::from(18u64)),
            ..Default::default()
        },
    );
    // Some filler so tries have branches and extensions.
    for i in 1..40u64 {
        s.accounts.insert(
            Address::left_padding_from(&i.to_be_bytes()),
            MockAccount {
                nonce: i,
                ..Default::default()
            },
        );
    }
    s.accounts.insert(
        FIXTURE,
        MockAccount {
            nonce: 1,
            code: Bytes::from_static(&hex!("6080604052")),
            ..Default::default()
        },
    );
    s.set_storage(FIXTURE, SHARE_SLOT, U256::from(share_bps));
    for i in 1..20u64 {
        s.set_storage(FIXTURE, B256::from(U256::from(i)), U256::from(i * 11));
    }
    s
}

fn split_reads() -> BTreeMap<Address, (Vec<B256>, bool)> {
    reads(&[(FIXTURE, &[SHARE_SLOT], true)])
}

const SPLIT_KEYS: [ReadKey; 1] = [ReadKey::Storage(FIXTURE, SHARE_SLOT)];

struct Evidence(HashMap<ConfirmationPolicy, Confirmation>);

impl Evidence {
    fn finalized(a: &L1Anchor) -> Self {
        Self::at(ConfirmationPolicy::Finalized, a, true)
    }
    fn at(level: ConfirmationPolicy, a: &L1Anchor, authenticated: bool) -> Self {
        Self(HashMap::from([(
            level,
            Confirmation {
                level,
                number: a.blockNumber,
                hash: a.blockHash,
                authenticated,
            },
        )]))
    }
}

impl ConfirmationSource for Evidence {
    fn head(&self, level: ConfirmationPolicy) -> Option<Confirmation> {
        self.0.get(&level).copied()
    }
}

/// H0 (shareBps 6000) → H1 (7000), observed and witnessed.
fn two_anchors() -> (AnchorBook, MockState, L1Anchor, MockState, L1Anchor) {
    let mut book =
        AnchorBook::new(CHAIN, ConfirmationPolicy::Finalized, Mode::Authenticated).unwrap();
    let s0 = state(6000);
    let (raw0, a0) = s0.header(CHAIN, 100, B256::repeat_byte(0x99));
    let s1 = state(7000);
    let (raw1, a1) = s1.header(CHAIN, 101, a0.blockHash);
    assert_eq!(book.observe(&raw0).unwrap(), a0);
    assert_eq!(book.observe(&raw1).unwrap(), a1);
    book.attach(a0.blockHash, &s0.package(&a0, &split_reads()))
        .unwrap();
    book.attach(a1.blockHash, &s1.package(&a1, &split_reads()))
        .unwrap();
    (book, s0, a0, s1, a1)
}

#[test]
fn honest_package_verifies_and_unwitnessed_reads_fail() {
    let s = state(6000);
    let (_, a) = s.header(CHAIN, 100, B256::ZERO);
    let pkg = s.package(
        &a,
        &reads(&[
            (
                FIXTURE,
                &[
                    SHARE_SLOT,
                    b256!("00000000000000000000000000000000000000000000000000000000000003e7"),
                ],
                true,
            ),
            (NOBODY, &[SHARE_SLOT], false),
        ]),
    );
    let w = verify(&pkg, &a).unwrap();
    assert_eq!(w.storage(FIXTURE, SHARE_SLOT).unwrap(), U256::from(6000));
    // A slot that is proven absent reads zero...
    assert_eq!(
        w.storage(FIXTURE, B256::from(U256::from(999))).unwrap(),
        U256::ZERO
    );
    // ...an absent account is proven absent...
    assert_eq!(w.account(NOBODY).unwrap(), None);
    assert_eq!(w.storage(NOBODY, SHARE_SLOT).unwrap(), U256::ZERO);
    assert_eq!(w.code(FIXTURE).unwrap().as_ref(), hex!("6080604052"));
    // ...but anything not covered is an error, never zero.
    assert!(matches!(
        w.storage(FIXTURE, B256::from(U256::from(5))),
        Err(WitnessError::NotWitnessed(..))
    ));
    assert!(matches!(
        w.account(OTHER),
        Err(WitnessError::NotWitnessed(..))
    ));
}

#[test]
fn channel_advances_from_h0_to_h1_without_reopening() {
    let (mut book, _, a0, _, a1) = two_anchors();
    book.promote(&Evidence::finalized(&a0));
    let w = book.latest_executable(&SPLIT_KEYS).unwrap();
    assert_eq!(w.anchor(), &a0);
    assert_eq!(w.storage(FIXTURE, SHARE_SLOT).unwrap(), U256::from(6000));
    assert!(matches!(
        book.executable(a1.id(), &SPLIT_KEYS),
        Err(AnchorError::NotConfirmed(_))
    ));
    book.promote(&Evidence::finalized(&a1));
    let w = book.latest_executable(&SPLIT_KEYS).unwrap();
    assert_eq!(w.anchor(), &a1);
    assert_eq!(w.storage(FIXTURE, SHARE_SLOT).unwrap(), U256::from(7000));
    // H0 stays executable too (it is still finalized history).
    assert!(book.executable(a0.id(), &SPLIT_KEYS).is_ok());
}

#[test]
fn proofs_from_two_roots_are_rejected() {
    let (_, s0, a0, s1, a1) = two_anchors();
    let p0 = s0.package(&a0, &split_reads());
    let p1 = s1.package(&a1, &split_reads());
    // H1's account proof, H0's storage proof (with H0's value).
    let mut mixed = p1.clone();
    mixed.slots = p0.slots.clone();
    assert!(matches!(
        verify(&mixed, &a1),
        Err(WitnessError::BadStorageProof(..))
    ));
    // H0's proofs relabeled with H1's anchor.
    let mut relabeled = p0.clone();
    relabeled.anchor = a1.clone();
    assert!(matches!(
        verify(&relabeled, &a1),
        Err(WitnessError::BadAccountProof(_))
    ));
    // H0's package presented for H1.
    assert!(matches!(
        verify(&p0, &a1),
        Err(WitnessError::AnchorMismatch { .. })
    ));
}

#[test]
fn unauthenticated_roots_are_rejected() {
    let (mut book, _, a0, _, _) = two_anchors();
    // A self-consistent fake state whose root is in no observed header.
    let fake = state(10_000);
    let fake_anchor = L1Anchor {
        stateRoot: fake.state_root(),
        ..a0.clone()
    };
    let pkg = fake.package(&fake_anchor, &split_reads());
    assert!(
        verify(&pkg, &fake_anchor).is_ok(),
        "self-consistent in isolation"
    );
    assert!(matches!(
        book.attach(a0.blockHash, &pkg),
        Err(AnchorError::Witness(WitnessError::AnchorMismatch { .. }))
    ));
    assert!(matches!(
        book.attach(B256::repeat_byte(7), &pkg),
        Err(AnchorError::Unknown(_))
    ));
    assert!(matches!(
        book.executable(fake_anchor.id(), &SPLIT_KEYS),
        Err(AnchorError::Unknown(_))
    ));
    // Unauthenticated "finalized" evidence promotes nothing.
    book.promote(&Evidence::at(ConfirmationPolicy::Finalized, &a0, false));
    assert_eq!(book.status(a0.id()), Some(Status::Candidate));
}

#[test]
fn bal_derived_value_is_state_ready_but_not_proof_ready() {
    struct Cache(B256, CachedValue);
    impl LocalState for Cache {
        fn storage_at(&self, block: B256, a: Address, s: B256) -> Option<CachedValue> {
            (block == self.0 && a == FIXTURE && s == SHARE_SLOT).then_some(self.1)
        }
    }
    let mut book =
        AnchorBook::new(CHAIN, ConfirmationPolicy::Finalized, Mode::Authenticated).unwrap();
    let s0 = state(6000);
    let (raw0, a0) = s0.header(CHAIN, 100, B256::ZERO);
    let s2 = state(7000);
    let (raw2, a2) = s2.header(CHAIN, 102, B256::repeat_byte(1));
    book.observe(&raw0).unwrap();
    book.observe(&raw2).unwrap();
    // skim knows 7000 at H2 via BAL writes on top of a proof at H0.
    let cache = Cache(
        a2.blockHash,
        CachedValue {
            value: U256::from(7000),
            provenance: Provenance::BalDerived {
                proven_at: a0.stateRoot,
                through_block: a2.blockHash,
            },
        },
    );
    let r = readiness(&book, &cache, a2.id(), &SPLIT_KEYS).unwrap();
    assert!(r.state_ready);
    assert!(!r.proof_ready);
    assert!(matches!(
        r.proof_error,
        Some(AnchorError::MissingWitness(..))
    ));
    // Passing the cached (correct) value off with H0's proof fails.
    let mut forged = s0.package(&a0, &split_reads());
    forged.anchor = a2.clone();
    forged.slots[0].value = U256::from(7000);
    assert!(book.attach(a2.blockHash, &forged).is_err());
    // So does H0's proof as is, at H2.
    let mut stale = s0.package(&a0, &split_reads());
    stale.anchor = a2.clone();
    assert!(book.attach(a2.blockHash, &stale).is_err());
    book.promote(&Evidence::finalized(&a2));
    assert!(book.executable(a2.id(), &SPLIT_KEYS).is_err());
}

#[test]
fn reorg_invalidates_witnesses_and_replacement_needs_its_own() {
    let (mut book, _, a0, s1, a1) = two_anchors();
    let pkg1 = s1.package(&a1, &split_reads());
    // A child of H1 that will be dropped with it.
    let s2 = state(7100);
    let (raw2, a2) = s2.header(CHAIN, 102, a1.blockHash);
    book.observe(&raw2).unwrap();
    book.reorged(a1.blockHash);
    assert_eq!(
        book.status(a1.id()),
        Some(Status::Invalidated(Invalidation::Reorged))
    );
    assert_eq!(
        book.status(a2.id()),
        Some(Status::Invalidated(Invalidation::AncestorInvalid))
    );
    assert!(matches!(
        book.attach(a1.blockHash, &pkg1),
        Err(AnchorError::Invalidated(..))
    ));
    assert!(matches!(
        book.proof_ready(a1.id(), &SPLIT_KEYS),
        Err(AnchorError::Invalidated(..))
    ));
    // Even with "finalized" evidence for it, an invalidated anchor stays out.
    book.promote(&Evidence::finalized(&a1));
    assert!(book.executable(a1.id(), &SPLIT_KEYS).is_err());
    // The replacement at height 101 has another state; H1's package doesn't transfer.
    let s1b = state(6500);
    let (raw1b, a1b) = s1b.header(CHAIN, 101, a0.blockHash);
    book.observe(&raw1b).unwrap();
    assert!(matches!(
        book.attach(a1b.blockHash, &pkg1),
        Err(AnchorError::Witness(WitnessError::AnchorMismatch { .. }))
    ));
    let mut relabeled = pkg1.clone();
    relabeled.anchor = a1b.clone();
    assert!(book.attach(a1b.blockHash, &relabeled).is_err());
    book.attach(a1b.blockHash, &s1b.package(&a1b, &split_reads()))
        .unwrap();
    book.promote(&Evidence::finalized(&a1b));
    let w = book.latest_executable(&SPLIT_KEYS).unwrap();
    assert_eq!(
        (w.anchor(), w.storage(FIXTURE, SHARE_SLOT).unwrap()),
        (&a1b, U256::from(6500))
    );
}

#[test]
fn finalizing_a_competitor_invalidates_the_other_branch() {
    let (mut book, _, a0, _, a1) = two_anchors();
    let s1b = state(6500);
    let (raw1b, a1b) = s1b.header(CHAIN, 101, a0.blockHash);
    book.observe(&raw1b).unwrap();
    book.promote(&Evidence::finalized(&a1b));
    assert_eq!(
        book.status(a1.id()),
        Some(Status::Invalidated(Invalidation::FinalizedConflict))
    );
    assert!(book.executable(a1.id(), &SPLIT_KEYS).is_err());
}

#[test]
fn unknown_links_and_weaker_evidence_fail_closed() {
    let (mut book, _, _, _, a1) = two_anchors();
    // Finalized head two blocks ahead, but its header (and its parent) was never observed.
    let unseen = Confirmation {
        level: ConfirmationPolicy::Finalized,
        number: 103,
        hash: B256::repeat_byte(0x42),
        authenticated: true,
    };
    book.promote(&Evidence(HashMap::from([(
        ConfirmationPolicy::Finalized,
        unseen,
    )])));
    assert_eq!(book.status(a1.id()), Some(Status::Candidate));
    // `safe` evidence doesn't satisfy a `finalized` policy.
    book.promote(&Evidence::at(ConfirmationPolicy::Safe, &a1, true));
    assert_eq!(book.status(a1.id()), Some(Status::Candidate));
}

#[test]
fn policies_without_evidence_sources_are_refused() {
    assert!(matches!(
        AnchorBook::new(CHAIN, ConfirmationPolicy::FcrConfirmed, Mode::Authenticated),
        Err(AnchorError::Unsupported(..))
    ));
    assert!(matches!(
        AnchorBook::new(
            CHAIN,
            ConfirmationPolicy::FcrConfirmed,
            Mode::OptimisticExperiment
        ),
        Err(AnchorError::Unsupported(..))
    ));
    assert!(matches!(
        AnchorBook::new(CHAIN, ConfirmationPolicy::Latest, Mode::Authenticated),
        Err(AnchorError::Unsupported(..))
    ));
    // Optimistic only in an explicitly labeled experiment.
    let mut book = AnchorBook::new(
        CHAIN,
        ConfirmationPolicy::Latest,
        Mode::OptimisticExperiment,
    )
    .unwrap();
    assert_eq!(book.mode(), Mode::OptimisticExperiment);
    let s = state(6000);
    let (raw, a) = s.header(CHAIN, 100, B256::ZERO);
    book.observe(&raw).unwrap();
    book.attach(a.blockHash, &s.package(&a, &split_reads()))
        .unwrap();
    book.promote(&Evidence::at(ConfirmationPolicy::Latest, &a, false));
    assert!(book.executable(a.id(), &SPLIT_KEYS).is_ok());
}

#[test]
fn safe_anchor_stops_being_executable_when_safe_moves_to_another_branch() {
    let mut book = AnchorBook::new(CHAIN, ConfirmationPolicy::Safe, Mode::Authenticated).unwrap();
    let s0 = state(6000);
    let (raw0, a0) = s0.header(CHAIN, 100, B256::ZERO);
    let (raw1, a1) = state(7000).header(CHAIN, 101, a0.blockHash);
    let (raw1b, a1b) = state(6500).header(CHAIN, 101, a0.blockHash);
    for r in [&raw0, &raw1, &raw1b] {
        book.observe(r).unwrap();
    }
    book.promote(&Evidence::at(ConfirmationPolicy::Safe, &a1, true));
    assert_eq!(
        book.status(a1.id()),
        Some(Status::Executable(ConfirmationPolicy::Safe))
    );
    book.promote(&Evidence::at(ConfirmationPolicy::Safe, &a1b, true));
    assert_eq!(
        book.status(a1.id()),
        Some(Status::Candidate),
        "not invalidated (safe can move), but not executable"
    );
}

#[test]
fn missing_or_truncated_storage_proofs_fail_closed() {
    let (book, s0, a0, _, _) = two_anchors();
    let mut pkg = s0.package(&a0, &split_reads());
    pkg.slots[0].proof.clear();
    assert!(matches!(
        verify(&pkg, &a0),
        Err(WitnessError::BadStorageProof(..))
    ));
    let mut pkg = s0.package(&a0, &split_reads());
    pkg.slots[0].proof.pop();
    assert!(verify(&pkg, &a0).is_err());
    let mut pkg = s0.package(&a0, &split_reads());
    pkg.accounts[0].proof.clear();
    assert!(verify(&pkg, &a0).is_err());
    // A slot the package doesn't carry.
    let other = [ReadKey::Storage(FIXTURE, B256::from(U256::from(3)))];
    assert!(matches!(
        book.proof_ready(a0.id(), &other),
        Err(AnchorError::MissingWitness(_, Some(_)))
    ));
}

#[test]
fn tampered_packages_are_rejected() {
    let s = state(6000);
    let (_, a) = s.header(CHAIN, 100, B256::ZERO);
    let base = s.package(
        &a,
        &reads(&[
            (OTHER, &[SHARE_SLOT], false),
            (FIXTURE, &[SHARE_SLOT], true),
            (NOBODY, &[], false),
        ]),
    );
    verify(&base, &a).unwrap();
    let idx =
        |p: &WitnessPackage, x: Address| p.accounts.iter().position(|w| w.account == x).unwrap();
    type Tamper = Box<dyn Fn(&mut WitnessPackage)>;
    let cases: Vec<(&str, Tamper)> = vec![
        (
            "value",
            Box::new(|p| {
                p.slots
                    .iter_mut()
                    .find(|s| s.account == FIXTURE)
                    .unwrap()
                    .value = U256::from(9999)
            }),
        ),
        (
            "value to zero (claims absence)",
            Box::new(|p| {
                p.slots
                    .iter_mut()
                    .find(|s| s.account == FIXTURE)
                    .unwrap()
                    .value = U256::ZERO
            }),
        ),
        (
            "balance",
            Box::new(move |p| {
                let i = idx(p, OTHER);
                p.accounts[i].balance += U256::from(1);
            }),
        ),
        (
            "present account claimed absent",
            Box::new(move |p| {
                let i = idx(p, OTHER);
                let w = &mut p.accounts[i];
                (w.exists, w.nonce, w.balance, w.storageRoot, w.codeHash) =
                    (false, 0, U256::ZERO, B256::ZERO, B256::ZERO);
            }),
        ),
        (
            "absent account with fields",
            Box::new(move |p| {
                let i = idx(p, NOBODY);
                p.accounts[i].nonce = 1;
            }),
        ),
        (
            "absent account claimed present",
            Box::new(move |p| {
                let i = idx(p, NOBODY);
                p.accounts[i].exists = true;
            }),
        ),
        (
            "code",
            Box::new(move |p| {
                let i = idx(p, FIXTURE);
                p.accounts[i].code = Bytes::from_static(&[0x00]);
            }),
        ),
        (
            "empty-trie slot with value",
            Box::new(|p| {
                p.slots
                    .iter_mut()
                    .find(|s| s.account == OTHER)
                    .unwrap()
                    .value = U256::from(1)
            }),
        ),
        ("unsorted accounts", Box::new(|p| p.accounts.reverse())),
        (
            "duplicate account",
            Box::new(|p| {
                let d = p.accounts[0].clone();
                p.accounts.insert(0, d);
            }),
        ),
        (
            "duplicate slot",
            Box::new(|p| {
                let d = p.slots[0].clone();
                p.slots.insert(0, d);
            }),
        ),
        (
            "storage without account",
            Box::new(move |p| {
                let i = idx(p, FIXTURE);
                p.accounts.remove(i);
            }),
        ),
        (
            "oversized node",
            Box::new(|p| {
                p.accounts[0]
                    .proof
                    .push(Bytes::from(vec![0u8; MAX_NODE_BYTES + 1]))
            }),
        ),
        (
            "too many nodes",
            Box::new(|p| p.accounts[0].proof = vec![Bytes::new(); MAX_PROOF_NODES + 1]),
        ),
    ];
    for (name, f) in cases {
        let mut p = base.clone();
        f(&mut p);
        assert!(verify(&p, &a).is_err(), "{name} must be rejected");
    }
}

#[test]
fn header_must_be_canonical() {
    let mut book =
        AnchorBook::new(CHAIN, ConfirmationPolicy::Finalized, Mode::Authenticated).unwrap();
    let (raw, _) = state(1).header(CHAIN, 1, B256::ZERO);
    let mut long = raw.to_vec();
    long.push(0);
    assert!(matches!(
        book.observe(&long),
        Err(AnchorError::BadHeader(_))
    ));
    assert!(matches!(
        book.observe(&raw[..raw.len() - 1]),
        Err(AnchorError::BadHeader(_))
    ));
}

#[test]
fn package_encoding_is_strict_and_hash_stable() {
    let (_, s0, a0, _, _) = two_anchors();
    let pkg = s0.package(&a0, &split_reads());
    let enc = pkg.abi_encode();
    let back = decode_package(&enc).unwrap();
    assert_eq!(package_hash(&back), package_hash(&pkg));
    let mut long = enc.clone();
    long.extend_from_slice(&[0u8; 32]);
    assert!(decode_package(&long).is_err());
    assert!(decode_package(&enc[..enc.len() - 1]).is_err());
}

proptest! {
    #[test]
    fn package_decode_never_panics(data in proptest::collection::vec(any::<u8>(), 0..2048)) {
        let _ = decode_package(&data);
    }

    #[test]
    fn random_proof_nodes_never_verify(nodes in proptest::collection::vec(proptest::collection::vec(any::<u8>(), 0..600), 0..8), v in any::<u64>()) {
        let s = state(6000);
        let (_, a) = s.header(CHAIN, 100, B256::ZERO);
        let mut pkg = s.package(&a, &split_reads());
        pkg.slots[0].proof = nodes.into_iter().map(Bytes::from).collect();
        pkg.slots[0].value = U256::from(v);
        prop_assert!(verify(&pkg, &a).is_err());
    }
}

type Lie = fn(&mut ProofResponse);

/// An `eth_getProof` endpoint over [`MockState`]s, optionally lying.
struct MockRpc {
    states: HashMap<B256, (MockState, L1Anchor)>,
    lie: Option<Lie>,
}

impl ProofSource for MockRpc {
    fn get_proof(
        &self,
        address: Address,
        slots: &[B256],
        block_hash: B256,
    ) -> Result<ProofResponse, SourceError> {
        let (s, a) = self.states.get(&block_hash).ok_or(SourceError::Rpc {
            code: -32002,
            message: "unknown block".into(),
            data: None,
        })?;
        let p = s.package(a, &reads(&[(address, slots, false)]));
        let w = &p.accounts[0];
        let acct = s.accounts.get(&address).map(MockState::trie_account);
        let mut r = ProofResponse {
            address,
            account_proof: w.proof.clone(),
            balance: w.balance,
            code_hash: acct
                .map(|a| a.code_hash)
                .unwrap_or(alloy_trie::KECCAK_EMPTY),
            nonce: U64::from(w.nonce),
            storage_hash: acct
                .map(|a| a.storage_root)
                .unwrap_or(alloy_trie::EMPTY_ROOT_HASH),
            storage_proof: p
                .slots
                .iter()
                .map(|s| StorageProofResponse {
                    key: s.slot.into(),
                    value: s.value,
                    proof: s.proof.clone(),
                })
                .collect(),
        };
        if let Some(f) = self.lie {
            f(&mut r);
        }
        Ok(r)
    }

    fn get_code(&self, address: Address, block_hash: B256) -> Result<Bytes, SourceError> {
        Ok(self.states[&block_hash]
            .0
            .accounts
            .get(&address)
            .map(|a| a.code.clone())
            .unwrap_or_default())
    }
}

#[test]
fn collect_witness_verifies_every_answer() {
    let (mut book, s0, a0, s1, a1) = two_anchors();
    let honest = MockRpc {
        states: HashMap::from([
            (a0.blockHash, (s0.clone(), a0.clone())),
            (a1.blockHash, (s1.clone(), a1.clone())),
        ]),
        lie: None,
    };
    let r = reads(&[
        (FIXTURE, &[SHARE_SLOT], true),
        (NOBODY, &[SHARE_SLOT], false),
    ]);
    let pkg = collect_witness(&honest, &a1, &r).unwrap();
    assert_eq!(pkg, s1.package(&a1, &r));
    book.attach(a1.blockHash, &pkg).unwrap();

    let lies: [(&str, Lie); 5] = [
        ("value", |r| r.storage_proof[0].value = U256::from(1)),
        ("balance", |r| r.balance = U256::from(1)),
        ("key", |r| r.storage_proof[0].key = U256::from(77)),
        ("address", |r| r.address = OTHER),
        ("dropped slot", |r| {
            r.storage_proof.pop();
        }),
    ];
    for (name, lie) in lies {
        let liar = MockRpc {
            states: honest.states.clone(),
            lie: Some(lie),
        };
        assert!(collect_witness(&liar, &a1, &r).is_err(), "{name}");
    }
    // An endpoint answering with the previous block's state (stale) for H1's hash.
    let stale = MockRpc {
        states: HashMap::from([(a1.blockHash, (s0.clone(), a0.clone()))]),
        lie: None,
    };
    assert!(matches!(
        collect_witness(&stale, &a1, &r),
        Err(SourceError::Unverifiable(_))
    ));
}

#[test]
#[ignore = "needs a running skim: SKIM_RPC=http://127.0.0.1:8545 SKIM_ADDRESS=0x... cargo test -- --ignored"]
fn live_skim_finalized_proof() {
    let url = std::env::var("SKIM_RPC").expect("SKIM_RPC");
    let addr: Address = std::env::var("SKIM_ADDRESS")
        .expect("SKIM_ADDRESS")
        .parse()
        .unwrap();
    let rpc = crate::source::SkimRpc::new(url.clone());
    let agent = ureq::agent();
    let body = serde_json::json!({"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["finalized", false]});
    let blk: serde_json::Value = agent
        .post(&url)
        .send_json(body)
        .unwrap()
        .into_json()
        .unwrap();
    let b = &blk["result"];
    // NOTE: this trusts skim for the header (skim checks it against the light client's
    // finalized hash). The channel runtime will observe raw headers instead.
    let anchor = L1Anchor {
        chainId: U256::from(CHAIN),
        blockNumber: u64::from_str_radix(
            b["number"].as_str().unwrap().trim_start_matches("0x"),
            16,
        )
        .unwrap(),
        blockHash: b["hash"].as_str().unwrap().parse().unwrap(),
        stateRoot: b["stateRoot"].as_str().unwrap().parse().unwrap(),
    };
    let pkg = collect_witness(&rpc, &anchor, &reads(&[(addr, &[B256::ZERO], false)])).unwrap();
    println!(
        "verified {} at block {}: package {}",
        addr,
        anchor.blockNumber,
        package_hash(&pkg)
    );
}

/// `fixtures/witnesses/read-and-split.json`: H0/H1 packages for the Solidity reader
/// (`contracts/test/Witness.t.sol`). `UPDATE_FIXTURES=1` rewrites it.
#[test]
fn witness_fixtures_are_current() {
    use alloy_primitives::hex;
    let (_, s0, a0, s1, a1) = two_anchors();
    let (raw0, _) = s0.header(CHAIN, 100, B256::repeat_byte(0x99));
    let (raw1, _) = s1.header(CHAIN, 101, a0.blockHash);
    let r = reads(&[(OTHER, &[SHARE_SLOT], false), (FIXTURE, &[SHARE_SLOT, B256::from(U256::from(999))], true), (NOBODY, &[SHARE_SLOT], false)]);
    let p0 = s0.package(&a0, &r);
    let p1 = s1.package(&a1, &r);
    let mut mixed = p1.clone();
    mixed.slots = p0.slots.clone();
    let mut bad_value = p1.clone();
    bad_value.slots.iter_mut().find(|s| s.account == FIXTURE && s.slot == SHARE_SLOT).unwrap().value = U256::from(9999);
    let mut absent_claim = p1.clone();
    {
        let w = absent_claim.accounts.iter_mut().find(|w| w.account == OTHER).unwrap();
        (w.exists, w.nonce, w.balance, w.storageRoot, w.codeHash) = (false, 0, U256::ZERO, B256::ZERO, B256::ZERO);
    }
    let mut unsorted = p1.clone();
    unsorted.accounts.reverse();
    let enc = |p: &WitnessPackage| hex::encode_prefixed(p.abi_encode());
    let anchor = |a: &L1Anchor| serde_json::json!({
        "chainId": B256::from(a.chainId), "blockNumber": a.blockNumber, "blockHash": a.blockHash,
        "stateRoot": a.stateRoot, "id": a.id(),
    });
    let out = serde_json::json!({
        "_comment": "Generated by channel-witness (UPDATE_FIXTURES=1 cargo test -p channel-witness). Do not edit.",
        "fixture": FIXTURE, "shareSlot": SHARE_SLOT, "other": OTHER, "nobody": NOBODY,
        "h0": { "rawHeader": raw0, "anchor": anchor(&a0), "package": enc(&p0), "packageHash": package_hash(&p0), "shareBps": 6000 },
        "h1": { "rawHeader": raw1, "anchor": anchor(&a1), "package": enc(&p1), "packageHash": package_hash(&p1), "shareBps": 7000 },
        "bad": {
            "mixedRoots": enc(&mixed), "wrongValue": enc(&bad_value), "presentClaimedAbsent": enc(&absent_claim),
            "unsorted": enc(&unsorted),
        },
    });
    for k in ["mixedRoots", "wrongValue", "presentClaimedAbsent", "unsorted"] {
        let p = decode_package(&hex::decode(out["bad"][k].as_str().unwrap()).unwrap()).unwrap();
        assert!(verify(&p, &a1).is_err(), "{k}");
    }
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/witnesses/read-and-split.json");
    let text = serde_json::to_string_pretty(&out).unwrap() + "\n";
    if std::env::var_os("UPDATE_FIXTURES").is_some() {
        std::fs::write(path, &text).unwrap();
    }
    assert_eq!(std::fs::read_to_string(path).expect("run with UPDATE_FIXTURES=1"), text, "stale fixture");
}

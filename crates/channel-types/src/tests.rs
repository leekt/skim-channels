use super::*;
use alloy_primitives::{address, b256};
use proptest::prelude::*;

pub(crate) fn sample_anchor() -> L1Anchor {
    L1Anchor {
        chainId: U256::from(11155111u64),
        blockNumber: 12_000_000,
        blockHash: b256!("1111111111111111111111111111111111111111111111111111111111111111"),
        stateRoot: b256!("2222222222222222222222222222222222222222222222222222222222222222"),
    }
}

fn sample_request() -> FinalRequest {
    FinalRequest {
        channelId: B256::repeat_byte(0xc1),
        termsHash: B256::repeat_byte(0x7e),
        anchorId: sample_anchor().id(),
        policyHash: B256::repeat_byte(0x90),
        executionProfileHash: B256::repeat_byte(0xef),
        inputHash: keccak256(b"input"),
        nonce: 7,
    }
}

#[test]
fn anchor_id_binds_every_field() {
    let a = sample_anchor();
    let base = a.id();
    let mut b = a.clone();
    b.chainId = U256::from(1u64);
    assert_ne!(b.id(), base);
    let mut b = a.clone();
    b.blockNumber += 1;
    assert_ne!(b.id(), base);
    let mut b = a.clone();
    b.blockHash = B256::ZERO;
    assert_ne!(b.id(), base);
    let mut b = a;
    b.stateRoot = B256::ZERO;
    assert_ne!(b.id(), base);
}

#[test]
fn request_digest_is_domain_separated() {
    let r = sample_request();
    let s = address!("00000000000000000000000000000000000000aa");
    let h = r.signing_hash(1, s);
    assert_ne!(h, r.signing_hash(11155111, s), "other chain");
    assert_ne!(
        h,
        r.signing_hash(1, address!("00000000000000000000000000000000000000bb")),
        "other contract"
    );
    let mut other = r.clone();
    other.channelId = B256::repeat_byte(0xc2);
    assert_ne!(h, other.signing_hash(1, s), "other channel");
    // The struct hash alone is not what is signed.
    assert_ne!(h, r.eip712_hash_struct());
}

#[test]
fn strict_decode_rejects_malformed() {
    let r = sample_request();
    let enc = r.abi_encode();
    assert_eq!(decode_strict::<FinalRequest>(&enc).unwrap(), r);
    // Short.
    assert!(decode_strict::<FinalRequest>(&enc[..enc.len() - 1]).is_err());
    // Trailing bytes.
    let mut long = enc.clone();
    long.push(0);
    assert!(decode_strict::<FinalRequest>(&long).is_err());
    // Dirty padding in the uint64 nonce (last word, high bytes).
    let mut dirty = enc.clone();
    let n = dirty.len();
    dirty[n - 32] = 1;
    assert!(decode_strict::<FinalRequest>(&dirty).is_err());
    // Dirty padding in an address.
    let terms = ChannelTerms {
        channelId: B256::ZERO,
        rollupId: B256::ZERO,
        settlementContract: Address::repeat_byte(1),
        executor: Address::repeat_byte(2),
        moduleCodeHash: B256::ZERO,
        participantRoot: B256::ZERO,
        policyHash: B256::ZERO,
        closeDeadline: 1,
    };
    let mut enc = terms.abi_encode();
    enc[64] = 0xff; // settlementContract word, padding byte
    assert!(decode_strict::<ChannelTerms>(&enc).is_err());
}

#[test]
fn unknown_codes_rejected() {
    let p = ChannelPolicy {
        anchorConfirmation: 4,
        maxAnchorLag: 0,
        challengeWindow: 0,
    };
    assert!(p.confirmation().is_err());
    let prof = ExecutionProfile {
        rollupId: B256::ZERO,
        kind: 3,
        genesisHash: B256::ZERO,
        programHash: B256::ZERO,
        forkSchemaHash: B256::ZERO,
        daSchemaHash: B256::ZERO,
        executorCodeHash: B256::ZERO,
    };
    assert!(profile_hash(&prof).is_err());
}

#[test]
fn profile_kind_and_config_change_the_hash() {
    let base = ExecutionProfile {
        rollupId: B256::repeat_byte(1),
        kind: ExecutionProfileKind::MockLocal as u8,
        genesisHash: B256::repeat_byte(2),
        programHash: B256::repeat_byte(3),
        forkSchemaHash: B256::repeat_byte(4),
        daSchemaHash: B256::repeat_byte(5),
        executorCodeHash: B256::repeat_byte(6),
    };
    let h = profile_hash(&base).unwrap();
    assert!(!base.kind().unwrap().is_native());
    let mut native = base.clone();
    native.kind = ExecutionProfileKind::NativeProofDependencies as u8;
    assert_ne!(
        profile_hash(&native).unwrap(),
        h,
        "mock and native profiles must never share a hash"
    );
    for i in 0..5 {
        let mut p = base.clone();
        match i {
            0 => p.genesisHash = B256::ZERO,
            1 => p.programHash = B256::ZERO,
            2 => p.forkSchemaHash = B256::ZERO,
            3 => p.daSchemaHash = B256::ZERO,
            _ => p.executorCodeHash = B256::ZERO,
        }
        assert_ne!(profile_hash(&p).unwrap(), h);
    }
}

#[test]
fn participants_must_be_canonical() {
    let a = address!("00000000000000000000000000000000000000a1");
    let b = address!("00000000000000000000000000000000000000b2");
    assert!(participant_root(&[a, b]).is_ok());
    assert_eq!(
        participant_root(&[b, a]),
        Err(EncodingError::BadParticipants)
    );
    assert_eq!(
        participant_root(&[a, a]),
        Err(EncodingError::BadParticipants)
    );
    assert_eq!(participant_root(&[]), Err(EncodingError::BadParticipants));
    assert_eq!(
        participant_root(&[Address::ZERO, a]),
        Err(EncodingError::BadParticipants)
    );
}

#[test]
fn channel_id_binds_chain_contract_opener_salt() {
    let s = Address::repeat_byte(1);
    let o = Address::repeat_byte(2);
    let id = channel_id(1, s, o, B256::ZERO);
    assert_ne!(id, channel_id(2, s, o, B256::ZERO));
    assert_ne!(id, channel_id(1, o, o, B256::ZERO));
    assert_ne!(id, channel_id(1, s, s, B256::ZERO));
    assert_ne!(id, channel_id(1, s, o, B256::repeat_byte(9)));
}

proptest! {
    #[test]
    fn request_roundtrips_canonically(
        c in any::<[u8; 32]>(), t in any::<[u8; 32]>(), a in any::<[u8; 32]>(),
        p in any::<[u8; 32]>(), e in any::<[u8; 32]>(), i in any::<[u8; 32]>(), n in any::<u64>(),
    ) {
        let r = FinalRequest {
            channelId: c.into(), termsHash: t.into(), anchorId: a.into(), policyHash: p.into(),
            executionProfileHash: e.into(), inputHash: i.into(), nonce: n,
        };
        let enc = r.abi_encode();
        prop_assert_eq!(decode_strict::<FinalRequest>(&enc).unwrap(), r);
    }

    #[test]
    fn decode_never_panics_and_accepts_only_canonical(data in proptest::collection::vec(any::<u8>(), 0..300)) {
        if let Ok(r) = decode_strict::<FinalRequest>(&data) {
            prop_assert_eq!(r.abi_encode(), data);
        }
    }
}

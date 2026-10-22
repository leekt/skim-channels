//! Fork-tolerant header decoding. A block's identity is keccak256 of its raw RLP header; only a
//! few leading fields are needed here, and their positions are fixed since London. Later forks
//! append fields (Cancun, Prague, Amsterdam, and whatever a devnet adds), so this reads the
//! list generically instead of requiring a known header shape: unknown trailing fields are
//! carried by the bytes (and the hash), not interpreted.

use alloy_primitives::{B256, keccak256};
use alloy_rlp::{Decodable, Header as RlpHeader};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeaderFields {
    pub hash: B256,
    pub parent_hash: B256,
    pub state_root: B256,
    pub receipts_root: B256,
    pub number: u64,
    pub timestamp: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("malformed header: {0}")]
pub struct HeaderError(pub String);

fn err(s: impl Into<String>) -> HeaderError {
    HeaderError(s.into())
}

/// Decodes a raw RLP header: one list spanning the input exactly, at least the 15 London-era
/// fields, each item well-formed.
pub fn decode(raw: &[u8]) -> Result<HeaderFields, HeaderError> {
    let mut buf = raw;
    let h = RlpHeader::decode(&mut buf).map_err(|e| err(e.to_string()))?;
    if !h.list || h.payload_length != buf.len() {
        return Err(err("not a single list spanning the input"));
    }
    let mut items: Vec<&[u8]> = Vec::with_capacity(24);
    let mut rest = buf;
    while !rest.is_empty() {
        let start = rest;
        let ih = RlpHeader::decode(&mut rest).map_err(|e| err(e.to_string()))?;
        if ih.payload_length > rest.len() {
            return Err(err("item overruns the header"));
        }
        rest = &rest[ih.payload_length..];
        items.push(&start[..start.len() - rest.len()]);
        if items.len() > 64 {
            return Err(err("too many fields"));
        }
    }
    if items.len() < 15 {
        return Err(err("fewer than 15 fields"));
    }
    let b256 =
        |i: usize| B256::decode(&mut &items[i][..]).map_err(|e| err(format!("field {i}: {e}")));
    let u = |i: usize| u64::decode(&mut &items[i][..]).map_err(|e| err(format!("field {i}: {e}")));
    Ok(HeaderFields {
        hash: keccak256(raw),
        parent_hash: b256(0)?,
        state_root: b256(3)?,
        receipts_root: b256(5)?,
        number: u(8)?,
        timestamp: u(11)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_consensus::Header;

    #[test]
    fn matches_alloy_and_tolerates_unknown_trailing_fields() {
        let h = Header {
            number: 77,
            state_root: B256::repeat_byte(3),
            receipts_root: B256::repeat_byte(5),
            timestamp: 9,
            ..Default::default()
        };
        let raw = alloy_rlp::encode(&h);
        let f = decode(&raw).unwrap();
        assert_eq!(
            (f.number, f.state_root, f.receipts_root, f.timestamp, f.hash),
            (77, h.state_root, h.receipts_root, 9, h.hash_slow())
        );
        // A future fork appends two fields: still decodes; the hash is of the new bytes.
        let mut b = &raw[..];
        let outer = RlpHeader::decode(&mut b).unwrap();
        let mut payload = b[..outer.payload_length].to_vec();
        payload.extend(alloy_rlp::encode(B256::repeat_byte(0xee)));
        payload.extend(alloy_rlp::encode(42u64));
        let mut extended = Vec::new();
        RlpHeader {
            list: true,
            payload_length: payload.len(),
        }
        .encode(&mut extended);
        extended.extend_from_slice(&payload);
        let g = decode(&extended).unwrap();
        assert_eq!((g.number, g.state_root), (77, h.state_root));
        assert_eq!(g.hash, keccak256(&extended));
    }

    #[test]
    fn rejects_malformed() {
        let raw = alloy_rlp::encode(Header::default());
        let mut long = raw.clone();
        long.push(0);
        assert!(decode(&long).is_err());
        assert!(decode(&raw[..raw.len() - 1]).is_err());
        assert!(
            decode(&alloy_rlp::encode(vec![1u64, 2, 3])).is_err(),
            "too few fields"
        );
        assert!(
            decode(&alloy_rlp::encode(B256::ZERO)).is_err(),
            "not a list"
        );
    }
}

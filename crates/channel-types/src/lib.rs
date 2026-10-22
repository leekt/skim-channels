//! Shared types and commitments for Skim Execution Channels (PROJECT.md §3.2, §5, §6.3).
//!
//! Every commitment is defined once, as Solidity ABI / EIP-712, so Rust, Solidity
//! (`contracts/src/libraries/ChannelTypes.sol`) and TypeScript (`ts/`) compute the same bytes.
//! The cross-language check is `fixtures/encodings/commitments.json` (written by
//! `cargo run -p channel-types --bin gen-fixtures`).
//!
//! - `anchorId`     = EIP-712 `hashStruct(L1Anchor)`; the L1 chain id is a field.
//! - `termsHash`    = `hashStruct(ChannelTerms)`.
//! - `policyHash`   = `hashStruct(ChannelPolicy)`.
//! - `profileHash`  = `hashStruct(ExecutionProfile)`.
//! - `requestHash`  = the EIP-712 signing digest of `FinalRequest` under [`domain`]: the
//!   settlement contract and its L1 chain. Participants sign exactly this digest.
//! - `channelId`    = [`channel_id`]: settlement chain, contract, opener and salt.
//!
//! Decoding is strict ([`decode_strict`]): bytes must re-encode to themselves, so trailing
//! data, short input, dirty padding and out-of-range enums are all rejected.

use alloy_primitives::{Address, B256, U256, keccak256};
use alloy_sol_types::{Eip712Domain, SolStruct, SolValue, eip712_domain, sol};

pub mod profile;
pub use profile::{ExecutionProfileKind, profile_hash};

sol! {
    /// One authenticated L1 state root. An execution uses exactly one (§3.2).
    #[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
    struct L1Anchor {
        uint256 chainId;
        uint64 blockNumber;
        bytes32 blockHash;
        bytes32 stateRoot;
    }

    /// What a channel is (§5.1). Fixed at open; bound into every request by `termsHash`.
    #[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
    struct ChannelTerms {
        bytes32 channelId;
        bytes32 rollupId;
        address settlementContract;
        address executor;
        bytes32 moduleCodeHash;
        bytes32 participantRoot;
        bytes32 policyHash;
        uint64 closeDeadline;
    }

    /// Execution policy, committed to by `policyHash`.
    #[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
    struct ChannelPolicy {
        /// [`ConfirmationPolicy`] as u8.
        uint8 anchorConfirmation;
        /// How far the anchor may trail the L1 head the executor sees, in blocks.
        uint32 maxAnchorLag;
        /// Emergency-exit challenge window, in seconds (EmergencyExit clamps it to
        /// [1 hour, 30 days], so no channel can make a stale request final instantly).
        uint32 challengeWindow;
    }

    /// The single request eligible for settlement (§5.2), signed by every participant.
    #[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
    struct FinalRequest {
        bytes32 channelId;
        bytes32 termsHash;
        bytes32 anchorId;
        bytes32 policyHash;
        bytes32 executionProfileHash;
        /// keccak256 of the module input (application-defined bytes).
        bytes32 inputHash;
        uint64 nonce;
    }

    /// The accepted-rollup execution configuration a request is bound to (§6.3).
    #[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
    struct ExecutionProfile {
        bytes32 rollupId;
        /// [`ExecutionProfileKind`] as u8.
        uint8 kind;
        bytes32 genesisHash;
        bytes32 programHash;
        bytes32 forkSchemaHash;
        /// The data-availability scheme blocks are accepted under (docs/guide/stage-2.md: L1 DA).
        bytes32 daSchemaHash;
        bytes32 executorCodeHash;
    }
}

pub const DOMAIN_NAME: &str = "SkimChannels";
pub const DOMAIN_VERSION: &str = "0";
/// Tag for [`channel_id`], so a channel id can't equal any other commitment's preimage.
pub const CHANNEL_ID_TAG: &str = "skim-channels/channel-id/v0";

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum EncodingError {
    #[error("abi decode failed: {0}")]
    Abi(String),
    #[error("non-canonical encoding (does not re-encode to the same bytes)")]
    NonCanonical,
    #[error("unknown {what} code {code}")]
    UnknownCode { what: &'static str, code: u8 },
    #[error("participants must be non-empty, strictly ascending and nonzero")]
    BadParticipants,
}

/// Decodes `data` as `T` and accepts it only if it re-encodes to exactly `data`.
pub fn decode_strict<T: SolValue + From<<T::SolType as alloy_sol_types::SolType>::RustType>>(
    data: &[u8],
) -> Result<T, EncodingError> {
    let v = T::abi_decode(data).map_err(|e| EncodingError::Abi(e.to_string()))?;
    if v.abi_encode() != data {
        return Err(EncodingError::NonCanonical);
    }
    Ok(v)
}

/// Anchor confirmation policies (§3.3). `Safe` is never treated as `FcrConfirmed`.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, serde::Serialize, serde::Deserialize,
)]
#[repr(u8)]
pub enum ConfirmationPolicy {
    /// Optimistic head. Local experiments only; never authenticated.
    Latest = 0,
    Safe = 1,
    Finalized = 2,
    /// Needs a real FCR evidence source; none is integrated yet (M4).
    FcrConfirmed = 3,
}

impl TryFrom<u8> for ConfirmationPolicy {
    type Error = EncodingError;
    fn try_from(code: u8) -> Result<Self, EncodingError> {
        Ok(match code {
            0 => Self::Latest,
            1 => Self::Safe,
            2 => Self::Finalized,
            3 => Self::FcrConfirmed,
            _ => {
                return Err(EncodingError::UnknownCode {
                    what: "confirmation policy",
                    code,
                });
            }
        })
    }
}

/// The signing domain: one settlement contract on one L1 chain.
pub fn domain(l1_chain_id: u64, settlement: Address) -> Eip712Domain {
    eip712_domain! {
        name: DOMAIN_NAME,
        version: DOMAIN_VERSION,
        chain_id: l1_chain_id,
        verifying_contract: settlement,
    }
}

impl L1Anchor {
    pub fn id(&self) -> B256 {
        self.eip712_hash_struct()
    }
}

impl ChannelTerms {
    pub fn hash(&self) -> B256 {
        self.eip712_hash_struct()
    }
}

impl ChannelPolicy {
    pub fn hash(&self) -> B256 {
        self.eip712_hash_struct()
    }

    pub fn confirmation(&self) -> Result<ConfirmationPolicy, EncodingError> {
        ConfirmationPolicy::try_from(self.anchorConfirmation)
    }
}

impl FinalRequest {
    /// The digest participants sign, bound to the settlement contract and its chain.
    pub fn signing_hash(&self, l1_chain_id: u64, settlement: Address) -> B256 {
        self.eip712_signing_hash(&domain(l1_chain_id, settlement))
    }
}

/// `keccak256(abi.encode(keccak256(CHANNEL_ID_TAG), l1ChainId, settlement, opener, salt))`.
pub fn channel_id(l1_chain_id: u64, settlement: Address, opener: Address, salt: B256) -> B256 {
    keccak256(
        (
            keccak256(CHANNEL_ID_TAG),
            U256::from(l1_chain_id),
            settlement,
            opener,
            salt,
        )
            .abi_encode_params(),
    )
}

/// `keccak256(abi.encode(address[]))` over participants in strictly ascending order.
pub fn participant_root(participants: &[Address]) -> Result<B256, EncodingError> {
    let ok = !participants.is_empty()
        && participants.iter().all(|a| *a != Address::ZERO)
        && participants.windows(2).all(|w| w[0] < w[1]);
    if !ok {
        return Err(EncodingError::BadParticipants);
    }
    Ok(keccak256(participants.to_vec().abi_encode()))
}

#[cfg(test)]
mod tests;

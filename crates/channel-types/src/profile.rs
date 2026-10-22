//! Execution profiles (§6.3). The kind is part of the committed profile, so a request bound
//! to a `mock-local` profile can never authorize settlement under a native profile, and
//! changing any configuration field changes the hash a request signed.

use alloy_primitives::B256;
use alloy_sol_types::SolStruct;

use crate::{EncodingError, ExecutionProfile};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[repr(u8)]
pub enum ExecutionProfileKind {
    /// Local development only. Block acceptance is an operator assertion, NOT native security.
    MockLocal = 0,
    NativeReexecutionDevnet = 1,
    NativeProofDependencies = 2,
}

impl ExecutionProfileKind {
    /// Whether this profile claims execution verification. Mocks never do.
    pub fn is_native(self) -> bool {
        !matches!(self, Self::MockLocal)
    }
}

impl TryFrom<u8> for ExecutionProfileKind {
    type Error = EncodingError;
    fn try_from(code: u8) -> Result<Self, EncodingError> {
        Ok(match code {
            0 => Self::MockLocal,
            1 => Self::NativeReexecutionDevnet,
            2 => Self::NativeProofDependencies,
            _ => {
                return Err(EncodingError::UnknownCode {
                    what: "execution profile kind",
                    code,
                });
            }
        })
    }
}

impl ExecutionProfile {
    pub fn kind(&self) -> Result<ExecutionProfileKind, EncodingError> {
        ExecutionProfileKind::try_from(self.kind)
    }
}

/// The profile's commitment; rejects unknown kinds rather than hashing them.
pub fn profile_hash(p: &ExecutionProfile) -> Result<B256, EncodingError> {
    p.kind()?;
    Ok(p.eip712_hash_struct())
}

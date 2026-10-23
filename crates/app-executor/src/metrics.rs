//! Counters for the L1 view: how much each block of following costs, and how many execution
//! reads were warm. `executor_metrics` returns them.

use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

use serde_json::{Value, json};

macro_rules! counters {
    ($($name:ident),* $(,)?) => {
        $(pub static $name: AtomicU64 = AtomicU64::new(0);)*
        pub fn snapshot() -> Value {
            json!({ $(stringify!($name).to_lowercase(): $name.load(Relaxed)),* })
        }
    };
}

counters!(
    // execution reads served from the warm working set, and dependencies proven on first use
    WARM_READS,
    COLD_FETCHES,
    // network: eth_getProof calls (one per account, all its slots), code fetches, headers
    PROOF_REQUESTS,
    PROOF_SLOTS,
    CODE_REQUESTS,
    HEADER_REQUESTS,
    // following: heads adopted, time spent proving the working set, stream events
    HEADS_ADOPTED,
    REFRESH_MS,
    LAST_REFRESH_MS,
    STREAM_APPLY,
    STREAM_REWIND,
    STREAM_GAP,
    // state-ready changes from the stream, and how many disagreed with the proofs
    STATE_READY_CHANGES,
    STATE_READY_MISMATCHES,
);

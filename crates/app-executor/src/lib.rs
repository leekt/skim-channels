//! The app network's executor: the app's Solidity runs on revm over its own state, with the
//! L1 accounts it imports read lazily from L1 (skim) at a pinned block, every value verified
//! against the pin's state root. See `db` (state layers), `guard` (write rules), `exec`
//! (transactions and pin moves) and `rpc` (the JSON-RPC surface).

pub mod db;
pub mod exec;
pub mod follow;
pub mod guard;
pub mod http;
pub mod metrics;
pub mod rpc;

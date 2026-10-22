#!/usr/bin/env bash
# Everything CI would run: Rust, fixture freshness, Solidity, TypeScript.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --locked
# Encoding fixtures must be reproducible byte for byte.
cargo run -q -p channel-types --bin gen-fixtures >/dev/null
git diff --exit-code -- fixtures/
(cd contracts && forge test)
(cd ts && npm ci --silent && npm run -s check-encodings)

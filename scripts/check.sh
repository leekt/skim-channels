#!/usr/bin/env bash
# Everything CI would run: Rust, fixture freshness, Solidity, TypeScript, and (with anvil) the
# two-chain e2e.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --locked
# Fixtures must be reproducible byte for byte.
cargo run -q -p channel-types --bin gen-fixtures >/dev/null
git diff --exit-code -- fixtures/
(cd contracts && forge fmt --check && forge test)
(cd ts && npm ci --silent && npm run -s check-encodings)
if command -v anvil >/dev/null; then
  cargo build -q -p channel-runner
  (cd ts && npm run -s e2e && npm run -s e2e-app && npm run -s e2e-predict && npm run -s e2e-clearing)
else
  echo "skipped e2e: anvil not installed"
fi
# Native execution verification (ethrex EXECUTE PoC): set ETHREX to a release build checkout.
if [ -n "${ETHREX:-}" ]; then
  (cd ts && npm run -s e2e-native)
else
  echo "skipped native e2e: ETHREX not set"
fi

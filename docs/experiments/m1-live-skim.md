# M1: live skim on Sepolia

**Date:** 2026-10-22. **skim:** `../skim/target/release/skim`, built from `df686b7` plus the owner's working-tree changes, run with `skim run --rpc 127.0.0.1:18545 --ephemeral`. **Test:** `crates/channel-runner/tests/live_skim.rs`.

## What was checked

- An `AnchorBook` with policy `Finalized` (then `Safe`), in `Mode::Authenticated`. Evidence came from `RpcConfirmations::skim`, which reads skim's light-client-authenticated tags.
- Headers observed back from the confirmed head, hash-checked.
- Witness: WETH on Sepolia (`0x7b79…E7f9`), with account, code and slots 0 and 2, collected through `eth_getProof` at the anchor's block hash and verified locally.
- Before promotion, the anchor was not executable. After promotion it was, and `decimals` (slot 2) read 18.

## Results

| Anchor | Block | Witness size | Collection time |
|---|---|---|---|
| finalized | 11,966,157 (about 19 min behind head) | 13,376 B | 1,208 ms |
| safe | 11,966,251 | 13,376 B | 965 ms |

skim served proofs at a ~19-minute-old finalized root. How far back peers keep serving roots was not measured.

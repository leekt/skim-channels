# Handoff: skim-channels

Status as of 2026-10-22: **M0 done, M1 foundation done** (witness packages, anchor lifecycle,
readiness, skim bridge). Receipt-trie fixtures are ready for M2. Nothing is on L2 yet. Block
acceptance exists only as a labeled mock.

Read first: [PROJECT](PROJECT.md) (spec v0.1), [STAGE2](STAGE2.md) (the design target since
2026-10-22).

## Baseline
- **skim:** `df686b70cd567210860582097e25a3f8b3fe6616`, used as a **JSON-RPC service**
  (`eth_getProof`, `eth_getCode` at `{blockHash, requireCanonical}`). There is no Rust
  dependency on skim crates: `skim-snap` pulls in reth through `skim-el`, and this layer only
  needs to *verify* proofs, which it does with `alloy-trie`. skim is unchanged.
- **Toolchain:** Rust 1.97.0 (same as skim). Alloy line as skim (`alloy-primitives` 1.6/1.7,
  `alloy-trie` 0.9.8, `alloy-consensus` 2.5). Solidity 0.8.28 (`prague`). forge-std 1.9.7 is
  vendored. Node 23, viem 2.30.0.

## Commands
| | |
|---|---|
| everything | `scripts/check.sh` |
| Rust | `cargo test --workspace` (37 tests, 1 ignored live test) |
| regenerate encodings | `cargo run -p channel-types --bin gen-fixtures` |
| regenerate receipts | `UPDATE_FIXTURES=1 cargo test -p channel-receipts` |
| Solidity | `cd contracts && forge test` (10 tests) |
| TypeScript | `cd ts && npm ci && npm run check-encodings` (9 commitments) |
| live skim | `SKIM_RPC=http://127.0.0.1:8545 SKIM_ADDRESS=0x… cargo test -p channel-witness -- --ignored` |

## Decisions (M0)
- **Commitments are EIP-712 struct hashes.** `anchorId`, `termsHash`, `policyHash`,
  `profileHash`. The signed `requestHash` is the EIP-712 digest under the domain
  `{name: "SkimChannels", version: "0", chainId: L1, verifyingContract: settlement}`.
- **`channelId` = `keccak256(abi.encode(keccak256("skim-channels/channel-id/v0"), l1ChainId, settlement, opener, salt))`.**
  The settlement contract derives it at open, which breaks the circularity of `ChannelTerms.channelId`.
- **`participantRoot` = `keccak256(abi.encode(address[]))`.** Participants must be strictly
  ascending and nonzero. Anything else is rejected, not sorted.
- **Strict decoding everywhere.** Bytes must re-encode to themselves. Solidity checks the
  exact length (the ABI decoder already rejects dirty padding).
- **`ExecutionProfile` commits to `kind` and `daSchemaHash`.** `kind` is
  mock / native-reexecution / native-proof. A mock-profile request can't authorize native
  settlement. `IAcceptedBlockRegistry.profileKind()` lets settlement compare the two.

## Decisions (M1)
- **`WitnessPackage` = `abi.encode(anchor, AccountWitness[], StorageWitness[])`.** Sorted, no
  duplicates, bounded: 256 accounts, 1,024 slots, 64 nodes per proof, 600 bytes per node.
  `package_hash` = keccak of that encoding. The field is `slots`, because `storage` is a
  Solidity keyword.
- **`verify(pkg, trusted_anchor)` is the only way to a `VerifiedWitness`.**
  - Absent accounts must carry zero fields and an exclusion proof.
  - Slots in an empty trie must be zero with an empty proof, so the package is canonical.
  - Reading anything uncovered is `NotWitnessed`, never zero.
- **`AnchorBook` derives anchors from raw headers.** It hashes the bytes and requires
  canonical RLP.
  - **Promotion:** only on authenticated evidence at exactly the channel's policy, and only if
    the confirmed head links back through observed headers. Promotion is recomputed on every
    `promote`.
  - **Invalidation:** reorgs and finalized conflicts invalidate an anchor and its descendants
    permanently, and drop their witnesses.
  - **Policies:** `FcrConfirmed` is refused outright. `Latest` needs `Mode::OptimisticExperiment`.
- **`readiness()` reports `state_ready` and `proof_ready` separately.** A BAL-derived cached
  value is state-ready but never proof-ready.
- **`collect_witness` decides account presence from the proof, not from the answer's fields.**
  It re-verifies everything against the authenticated anchor. There is no fallback RPC.

## Security tests (spec §12) covered so far
| Test | Where |
|---|---|
| Advance H0 → H1 without reopening | `channel_advances_from_h0_to_h1_without_reopening` |
| Mix proofs from two roots | `proofs_from_two_roots_are_rejected` |
| Unauthenticated state root | `unauthenticated_roots_are_rejected` |
| Cached value without a current proof | `bal_derived_value_is_state_ready_but_not_proof_ready` |
| Reorg during witness collection | `reorg_invalidates_witnesses_and_replacement_needs_its_own`, `finalizing_a_competitor_invalidates_the_other_branch` |
| Missing storage proof | `missing_or_truncated_storage_proofs_fail_closed` |
| Modified receipt trie nodes | `modified_trie_nodes_are_rejected` (receipts) |
| Modified receipt type or status | `modified_type_or_status_is_rejected` (receipts) |
| Mock registry vs native profile | encoded in profile kind; *enforcement* is M2 settlement |
| Changed native execution configuration | `profile_kind_and_config_change_the_hash` |
| Canonical encoding (property) | `request_roundtrips_canonically`, `decode_never_panics…`, `package_decode_never_panics` |

**Mutation-checked** (check disabled → a test fails), 2026-10-22: anchor equality in
`verify`; the empty-trie slot check; the absent-account fields check; the unauthenticated
evidence filter; finalized-conflict invalidation; recomputed (non-sticky) promotion.

## Known limitations
- **No authenticated header source yet.** `AnchorBook` takes raw headers and evidence through
  the `ConfirmationSource` trait. Wiring both to skim's light client (finalized/safe hashes
  plus raw headers) is not done. The ignored live test reads the header over RPC and trusts it.
- **The live skim path is unexercised in this session.** No skim instance was running. skim
  only serves `eth_getProof` for recent state roots, so a finalized anchor (~13 min old) may
  already be outside what peers serve. This needs measuring.
- **Witness updates from BALs are not attempted** (§13.1).
- **Untested at the boundary:** `AnchorBook` storage is unbounded (no pruning) and `promote`
  is O(n · depth).
- **No signatures yet.** Only digests. ECDSA recovery and participant-set checks come with M2
  settlement.
- **No Solidity MPT verifier yet.** The receipt fixtures exist for it.

## Next bounded task
**M2a: the L1 receipt verifier in Solidity.** An MPT inclusion verifier plus a strict
typed-receipt decoder (status, logs) and header decoding (`keccak(raw) == blockHash`,
extract `receiptsRoot`), all tested against `fixtures/receipts/block-130.json`. That covers
the valid cases and the tampered node, index, type and status cases, with bounded parsing
and fuzzing. It needs no L2 and no native verification, and it unblocks `ChannelSettlement`.
After that:
- M2b: `L1StateReader` on L2, consuming `abi.encode(WitnessPackage)`.
- M2c: the Read-and-Split demo against the mock registry.

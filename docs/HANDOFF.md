# Handoff: skim-channels

Status as of 2026-10-22:
- **M0, M1, M2 done.** M2 runs with **mocked** block acceptance.
- **M3 groundwork done.** Block acceptance is real except the transition verifier, which is
  external.
- **Stage 2 emergency-exit prototype done.**
- **M4 partly done:** measurements only; FCR is blocked.

Read first: [PROJECT](PROJECT.md) (spec v0.1) and [STAGE2](STAGE2.md) (the design target).

## Baseline
- **skim:** `df686b70cd567210860582097e25a3f8b3fe6616`, used as a JSON-RPC service
  (`eth_getProof`, `eth_getCode`, `eth_getBlockBy*`). There is no crate dependency on skim:
  `skim-snap` pulls in reth, and this layer only *verifies* proofs, using `alloy-trie`. skim is
  unchanged.
- **Toolchain:** Rust 1.97.0 (as skim), alloy as skim (primitives 1.6/1.7, trie 0.9.8,
  consensus 2.5).
- **Solidity:** 0.8.28, `prague`, via-IR, optimizer 200. forge-std 1.9.7 is vendored.
- **Node:** 23 with viem 2.30.0. The e2e needs anvil (Foundry 1.8.5 was used).

## Commands
| | |
|---|---|
| everything | `scripts/check.sh` (fmt, clippy, Rust, fixture freshness, forge, viem, e2e if anvil) |
| Rust | `cargo test --workspace`: 41 tests, plus 1 ignored live-skim test. The anvil tests skip if anvil is missing |
| Solidity | `cd contracts && forge test`: 64 tests |
| TypeScript | `cd ts && npm ci && npm run check-encodings`: 9 commitments |
| two-chain e2e | `cargo build -p channel-runner && cd ts && npm run e2e`. Writes `experiments/e2e-mock-local.json` |
| regenerate fixtures | `cargo run -p channel-types --bin gen-fixtures`; `UPDATE_FIXTURES=1 cargo test -p channel-receipts -p channel-witness` |
| live skim | `SKIM_RPC=… SKIM_ADDRESS=0x… cargo test -p channel-witness -- --ignored` |
| CLI | `target/debug/skim-channels {header,witness,evidence} --help` |

## What exists
| Layer | Pieces |
|---|---|
| Shared (M0) | `channel-types` (Rust), `ChannelTypes.sol`, `ts/check-encodings.ts`. EIP-712 commitments, strict decoding, profile kinds plus `daSchemaHash` |
| L1 witnesses (M1) | `channel-witness`: `WitnessPackage`, `verify`, `AnchorBook` (observe, attach, promote, reorg, prune), readiness, `collect_witness` |
| Runtime (M1/M2) | `channel-runner`: hash-checked headers, `RpcConfirmations` (skim `safe`/`finalized`), `observe_back`, receipt evidence. CLI `skim-channels` |
| L2 contracts | `L2AnchorInbox` (**mock feed**, labeled), `L1StateReader`, `ChannelExecutor`, `IChannelModule`, `SplitModule` |
| L1 contracts | `AnchorRegistry` (BLOCKHASH/EIP-2935), `ChannelSettlement` (open/fund/settle/refund plus emergency exit), `AllocationFixture` |
| Block acceptance | `CanonicalBlockRegistry` (permissionless; genesis, single-chain lineage, L1-recorded anchor, blob DA, `IStateTransitionVerifier`); `MockTransitionVerifier`, `MockAcceptedBlockRegistry` (both labeled mocks) |
| Proof libraries | `RLP.sol` (strict, bounded), `MerklePatricia.sol` (inclusion/exclusion, inline nodes, exact proofs), `EthTypes.sol` (header, typed receipts, logs, accounts), `WitnessLib.sol` (the Solidity twin of `channel-witness::verify`) |

## Key decisions
- **Commitments** are EIP-712 struct hashes. The signed `requestHash` uses the domain
  `{SkimChannels, 0, L1 chain, settlement}`.
  - `channelId` binds L1 chain, settlement, opener and salt.
  - Participants must be strictly ascending.
- **Strict decoding everywhere.** Bytes must re-encode to themselves (Rust and Solidity), and
  RLP must be canonical.
- **Anchor authentication happens twice.**
  - On L2, the inbox derives anchors from raw headers posted by the mock feed.
  - On L1, `AnchorRegistry` records an anchor only if `keccak(rawHeader)` is L1's own
    BLOCKHASH or EIP-2935 hash at that height.
  - Settlement and emergency exits accept only L1-recorded anchors, so a lying L2 feed can't
    get an outcome settled. An anchor from a block L1 later reorgs away can't be recorded on
    the chain where settlement happens.
- **Executor.** Terms, policy, request, input, executor, module code hash and execution
  profile are all bound. Every participant's signature is checked (low-s). The witness is
  verified against an inbox anchor within `maxAnchorLag`. The module runs via STATICCALL (a
  writing module reverts). The executor has no mutable storage (`vm.accesses` checks this).
- **Settlement.**
  1. The registry's profile kind must equal the deployment's, so a mock can't serve a native
     deployment.
  2. The block is accepted with the deployment's profile, the header hashes to it, and the
     receipts root matches.
  3. The receipt is included and succeeded.
  4. The log comes from the executor and binds the channel and request hash.
  5. The request binds the terms, policy and profile, and its anchor is L1-recorded.
  6. The outcome conserves the escrow.

  There is exactly one terminal transition: settle before the deadline, refund at or after it.
- **Emergency exit (prototype; design in STAGE2).**
  - `startExit` posts an all-signed request.
  - `challengeExit` replaces it with a higher nonce inside the window; the window is not
    extended.
  - `finalizeExit` re-executes the approved module **on L1** with a witness verified at the
    L1-recorded anchor.
  - During an exit, the normal path can only settle the pending request.
  - If nobody finalizes within a further window, refund reopens.
- **Canonical acceptance.**
  - The chain must extend the tip from a fixed genesis, so there are no forks.
  - The L1 anchor must be recorded.
  - `BLOBHASH(0)` must be present, so the block's data is on L1.
  - The verifier must accept.
  - Anyone may submit.
  - `profileKind()` comes from the verifier, so security is exactly the verifier's.

## Security tests (spec §12)
| Test | Where |
|---|---|
| H0 → H1 without reopening | Rust `channel_advances_from_h0_to_h1_without_reopening`; forge `test_readAndSplit_previewH0_settleH1_once`; e2e |
| Mixed roots | Rust `proofs_from_two_roots_are_rejected`; forge `test_badPackagesRevert`, executor mixed-root case |
| Unauthenticated root | Rust `unauthenticated_roots_are_rejected`, `a_header_with_a_swapped_state_root_is_refused`, anvil genesis case; forge `test_anchorNotOnL1Rejected` |
| Cached value without a proof | `bal_derived_value_is_state_ready_but_not_proof_ready` |
| Reorg during collection | `reorg_invalidates_witnesses_and_replacement_needs_its_own`, `finalizing_a_competitor_invalidates_the_other_branch` |
| Missing proof fails closed | `missing_or_truncated_storage_proofs_fail_closed`; forge `test_unwitnessedReadReverts` |
| Persistent write | `test_persistentWriteRejectedByStaticcall` (+ no executor storage writes) |
| Unauthorized module | `test_unapprovedModuleRejected`, `test_emergencyExitModuleMustBeApprovedOnL1` |
| Unaccepted L2 fork / block | `test_unacceptedBlockRejected`, `test_competingForkRejected` |
| Modified trie nodes | Rust `modified_trie_nodes_are_rejected`; forge `test_tamperedNodesRevert`, `test_truncatedAndPaddedProofsRevert` |
| Modified receipt type / status | Rust `modified_type_or_status_is_rejected`; forge `test_receiptTamperingRejected`, `test_failedReceiptRejected` |
| Forged outcome emitter | `test_forgedEmitterRejected` |
| Modified signed request | `test_signaturesAndBindingsEnforcedOnL2`, `test_modifiedOutcomeOrRequestRejected` |
| Cross-channel reuse | `test_crossChannelReuseRejected` |
| Double settlement | MVP test, e2e |
| Settle/refund at the deadline | `test_deadlineBoundaryExactlyOneTransition` |
| Withheld receipt → refund | `test_refundWithoutSequencerExactlyOnce`, e2e |
| Mock registry vs native profile | `test_mockRegistryRejectedUnderNativeProfile` |
| Changed native configuration | `profile_kind_and_config_change_the_hash` (all fields, including DA) |
| Stale state in an emergency exit | `test_emergencyExitStaleRequestIsReplaced`, `test_normalSettleDuringExitOnlyForPendingRequest` |
| **Properties** | payout conservation (`testFuzz_splitConserves`, `test_nonConservingOutcomeRejected`); canonical encoding and bounded parsing (Rust proptests, `testFuzz_rlpNeverPanics`, `testFuzz_randomProofsNeverProveMembership`) |

**Mutation-checked** (disable the check → a named test fails), 2026-10-22:
- **Rust (6):** anchor equality, empty-trie slot, absent-account fields, unauthenticated
  evidence, finalized conflict, non-sticky promotion.
- **Solidity, settlement and executor (16):** emitter, log binding, conservation, registry
  profile kind, L1 anchor recorded, settle deadline, terminal status, receipt status, input
  binding, signatures, module approval, canonical package, no trailing proof nodes.
- **Solidity, emergency exit (10):** challenge nonce, exit signatures, challenge-window end,
  finalize waits, pending-request match, exit anchor on L1, exit input, settle during exit,
  refund grace, L1 module approval.

## Measurements (anvil prague, `experiments/e2e-mock-local.json`; gas = receipt gasUsed)
| | gas / bytes |
|---|---|
| L2 `execute` (2 signatures, 1-slot witness, split) | 282,670 gas |
| L1 `settle`, receipt is tx 15 of a 31-tx L2 block (3-node proof) | 375,460 gas |
| L1 `settle`, 1-tx L2 block (earlier run, same build otherwise) | 306,323 gas |
| L1 `finalizeExit` (L1 re-execution, same witness) | 295,172 gas |
| L1 `startExit` | 102,881 gas |
| L1 anchor `record` | 111,062 gas |
| L1 `open` / `fund` / `refund` / `withdraw` | 301,793 / 45,947 / 72,199 / 28,501 gas |
| witness package (1 account with code, 1 slot) | 1,920 bytes |
| settlement evidence (31-tx block / 1-tx block) | 3,296 / 2,528 bytes |

Settlement cost grows with the L2 block, because the receipt proof grows with it: +69k gas
and +768 bytes from 1 to 31 transactions. Larger blocks are unmeasured. For this tiny module,
L1 re-execution (`finalizeExit`, 295k) costs about the same as receipt settlement. That
observation is from one module and not a general claim.

## Known limitations
- **Native verification (M3) is external and missing.** No compatible network or verifier
  was available. `CanonicalBlockRegistry` takes an `IStateTransitionVerifier`, and only the
  labeled mock exists. Next: target an EIP-8079 / EIP-8288 + EIP-8357 devnet when one is
  runnable; L2BEAT's demo uses mock proofs as of 2026-10.
- **The L2 anchor feed is a mock** (`L2AnchorInbox`, system key). L1 re-authentication makes
  this safe for settlement, but not for liveness or correct previews.
- **FCR (M4) is blocked.** There is no evidence source; `FcrConfirmed` is refused everywhere.
- **The emergency exit needs a witness at the request's anchor.** skim serves proofs only for
  recent roots, so finalization may need an archive node. The refund fallback covers a
  witness that can't be obtained.
  - Prototype choices (window length, no window extension, nonce = checkpoint version)
    await owner review (STAGE2).
- **Untested:**
  - the live skim path (no skim instance was running; the ignored test exists);
  - blob DA end to end (forge `vm.blobhashes` only).
- **Single-slot reads only in the demo.** Bounds: 256 accounts and 1,024 slots per package,
  64 proof nodes, 600 bytes per node, 256 logs per receipt.

## Next tasks
1. Owner review of the emergency-exit choices (STAGE2, "Prototype").
2. M3: a real `IStateTransitionVerifier` on the first runnable native-rollup devnet. Then
   replace the e2e's `MockAcceptedBlockRegistry` with `CanonicalBlockRegistry` and blob
   submissions.
3. Live skim run: finalized-anchor witness availability and latency (`--ignored` test, then
   the e2e against skim as L1).
4. M4: settlement gas vs. L2 block size beyond 31 transactions, witness prefetching, batching
   several channels' receipts.

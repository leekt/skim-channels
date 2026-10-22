# Handoff: skim-channels

Status as of 2026-10-22: M0–M3 done, M4 FCR done, and the Stage 2 prototype done (emergency exit,
governance, forced inclusion). Read first: [PROJECT](../PROJECT.md) (spec v0.1), the [guides](README.md), and [Stage 2](guide/stage-2.md).

| Milestone | State |
|---|---|
| M0 shared types | Rust, Solidity and viem agree; strict decoding everywhere |
| M1 witnesses | Exact-root packages, `AnchorBook`; **live against skim on Sepolia** (finalized and safe anchors) |
| M2 channels | Read-and-Split e2e on two anvil chains (mock acceptance), plus the full forge suite |
| M3 native verification | **`native-reexecution-devnet` on ethrex, no mocks anywhere in the e2e.** `ExecuteVerifier` (EXECUTE) behind the permissionless, governed `CanonicalBlockRegistry`; L1 messages, forced inclusion and calldata DA; anchors fed trustlessly via proven L1 messages. `native-proof-dependencies` (EIP-8288/8357) is not implementable yet (see [Stage 2](guide/stage-2.md)) |
| M4 | **FCR from Lighthouse v8.3.0's `fast_confirmation` event, live.** Measurements below |
| Stage 2 | Operator-free exit (L1 re-execution); 30-day upgrade timelock; fault-gated Security Council; forced inclusion; permissionless block submission (in `CanonicalBlockRegistry`) |

## Baseline
- **skim** `df686b70cd567210860582097e25a3f8b3fe6616`, used over JSON-RPC with no crate
  dependency. The live run used `../skim/target/release/skim`, built from that commit plus the
  owner's uncommitted working-tree changes (`git status` in `../skim`).
- **ethrex** at `0393eb8` (contains PR #6418, native rollups). Build it with
  `COMPILE_CONTRACTS=true cargo build --release --features l2,l2-sql`. It needs **solc 0.8.31
  exactly** on `PATH`.
- **Lighthouse** `sigp/lighthouse:v8.3.0` via Kurtosis `ethpandaops/ethereum-package`, with
  geth as the EL and `--enable-fast-confirmation`.
- **Rust** 1.97.0. **Solidity** 0.8.28, `prague`, via-IR, `optimizer_runs = 1`. **Node** 23
  with viem 2.30.0. **Foundry** 1.8.5.

## Commands
| | |
|---|---|
| everything | `scripts/check.sh`, plus `ETHREX=<checkout>` for the native e2e |
| Rust | `cargo test --workspace`: 50 tests. anvil tests skip without anvil; live tests skip without their env vars |
| Solidity | `cd contracts && forge test`: 88 tests |
| TypeScript | `cd ts && npm run check-encodings`: 9 |
| anvil e2e | `cargo build -p channel-runner && cd ts && npm run e2e` |
| native e2e | `ETHREX=… npm run e2e-native`. Starts ethrex L1 and L2 itself; writes `docs/experiments/data/e2e-native-ethrex.json` |
| live skim | `skim run --rpc 127.0.0.1:18545 --ephemeral`, then `SKIM_RPC=http://127.0.0.1:18545 cargo test -p channel-runner --test live_skim -- --nocapture` |
| live FCR | `kurtosis run --enclave fcr github.com/ethpandaops/ethereum-package --args-file <yaml>`, with `cl_image: sigp/lighthouse:v8.3.0` and `cl_extra_params: ["--enable-fast-confirmation"]`. Then `BEACON_URL=… EL_URL=… cargo test -p channel-runner --test live_fcr -- --nocapture` |

## Architecture as built
| Where | Contracts / crates |
|---|---|
| L1 | `ChannelSettlement` (escrow, receipt settlement, refund), `EmergencyExit` (operator-free exit, bound once), `AnchorRegistry` (BLOCKHASH/EIP-2935), block acceptance (`NativeRollupRegistry`, `CanonicalBlockRegistry` plus `RollupGovernance`, or the labeled mocks), `ReceiptVerifier`, `WitnessVerifier` |
| L2 | `ChannelExecutor`, `WitnessVerifier`, `L2AnchorInbox` (**mock feed**, labeled; anchors are re-authenticated on L1), `L1StateReader`, modules (`SplitModule`) |
| Rust | `channel-types`, `channel-witness` (plus `header`: fork-tolerant decoding), `channel-receipts`, `channel-runner` (CLI `skim-channels`; `RpcConfirmations` for skim; `FcrConfirmations`) |

**Deployability.** On Amsterdam chains, deploying code costs about **1,600 gas per byte**
(measured on ethrex: `SplitModule`, 981 B, cost 1.73M gas; it costs 265k on anvil Prague). The
EIP-7825 per-transaction cap is 16.7M gas. So every contract stays under ~9.7 KB: proof
verification lives in the shared `WitnessVerifier` and `ReceiptVerifier`, and the exit lives in
`EmergencyExit`. Largest today: `ChannelSettlement` at 9,741 B. It deploys on ethrex L1, but
check `forge build --sizes` when adding code.

**Headers on any fork.** The runtime hashes the node's raw header bytes
(`debug_getRawHeader`, by number, checked against the block hash) and parses only the leading
fields (`channel_witness::header`). Nodes without the debug API, such as skim, fall back to
rebuilding the header from JSON, which only works for fork shapes alloy knows. The same applies
to receipts (`debug_getRawReceipts`). ethrex's L1 runs LStar/Hegota header shapes that alloy 2.5
can't rebuild; the fallback correctly refused them before raw headers were added.

## Key decisions
These are unchanged from earlier and are in the code comments: commitments, strict decoding,
L1 re-authentication of anchors, executor bindings, settlement order, and exactly one terminal
transition. New:
- **Native acceptance** (`NativeRollupRegistry`) reads only EXECUTE-verified, final state
  roots. A block's hash comes either from the verified tip or from an EIP-2935 history-contract
  MPT proof against a later verified root. Its state root must equal the verified root at its
  height. Profile kind: `native-reexecution-devnet`.
- **FCR:** `AnchorBook` accepts `FcrConfirmed` (authenticated mode only). It is promoted only by
  evidence reported *at that level*, which today means only `FcrConfirmations`: the beacon SSE
  event, then the beacon block, then a hash-checked EL header. This trusts the configured full
  beacon node, because FCR needs the full vote view. `safe`/`finalized` are never FCR evidence,
  even on a Lighthouse node that feeds FCR into `safe`.
- **Governance and exits:** see [Stage 2](guide/stage-2.md). A verifier fault proven on chain freezes receipt
  settlement, while the L1 re-execution exit keeps working.

## Security tests (spec §12 and Stage 2), where
The table in the previous handoff revision still holds; see `git show 42fa0bc:docs/HANDOFF.md`.
Added since:

| Test | Where |
|---|---|
| Real execution verification; settlement before L1 re-execution | `ts/e2e-native.ts` (`settle before L1 re-executed the L2 block` reverts) |
| Forged / unverified / non-final native blocks | `NativeRollupRegistry.t.sol` `test_unverifiedOrForgedRejected`, `test_historicalBlockAcceptedFromVerifiedLaterState` |
| FCR not satisfied by safe/finalized; unauthenticated FCR | `fcr_needs_fcr_evidence_never_safe_or_finalized`, `fcr_event_promotes_an_fcr_anchor`, `live_fcr_anchor` |
| Headers on unknown forks; lying raw/JSON headers | `channel_witness::header` tests, `a_header_with_a_swapped_state_root_is_refused` |
| 30-day upgrade; fault-gated council; freeze | `test_ordinaryUpgradeWaitsThirtyDays`, `test_provenConflictFreezesAndOnlyThenCouncilActs`, `test_provenVerifierFaultHaltsReceiptsButNotEmergencyExit` |
| Forced inclusion | `test_overdueForcedTransactionMustBeIncluded`, `test_verifierSeesForcedAccumulator` |

**Mutation-checked** (disable the check, and a named test fails):
- Rust: 6.
- Settlement and executor: 16.
- Emergency exit: 10.
- Governance and forced inclusion: 8 (30-day delay, council needs a fault, frozen blocks
  submission, frozen hides acceptance, forced deadline, conflict needs different results,
  registry admin, verifier receives the forced accumulator).
- `NativeRollupRegistry`: 5 (header state root, history hash match, finality, tip match,
  history window).

## Measurements
The logs in [docs/experiments](experiments) are the source. Headline numbers:

| Setting | What | Value |
|---|---|---|
| skim, Sepolia, live | witness at a finalized anchor (~19 min old) / a safe anchor | 13,376 B in 1.2 s / 0.97 s ([M1](experiments/m1-live-skim.md)) |
| Lighthouse v8.3.0 FCR | FCR vs. finality | at the head; 69–77 blocks ahead of finality ([M4 FCR](experiments/m4-fcr.md)) |
| ethrex native (EXECUTE) | `CanonicalBlockRegistry.submit`, mean per L2 block | ~16.0M gas ([M3](experiments/m3-native-ethrex.md)) |
| ethrex native | L1 `settle` (canonical registry) | 506,777 gas |
| anvil | `settle` for 1 / 31 / 127 / 255-tx L2 blocks | 320,486 / 392,090 / 396,307 / 396,343 gas ([M4 cost](experiments/m4-settlement-cost.md)) |
| forge | `settle` vs. `settleFromBlock` (2 in one block) | 315,124 vs. 280,975 gas per channel |
| anvil | `startExit` / `finalizeExit` | 130,364 / 317,643 gas ([M2](experiments/m2-anvil-e2e.md)) |

## Known limitations
- **`native-proof-dependencies`:** `ProofDependencyVerifier` exists, but no network can carry a
  STARK dependency (EIP-8288 reserves the scheme), and no real EIP-8357 key exists. Evidence is
  in [Stage 2](guide/stage-2.md).
- **ethrex PoC specifics:**
  - its own `advance()` has a single advancer (our registry doesn't);
  - forced-inclusion deadlines start at `poke`, because ethrex records no message times;
  - EXECUTE costs about the L2 block gas limit per block, so one block per L1 transaction.
- **The EXECUTE ABI is ethrex's.** SSZ, schema 0x1501, fixed offsets mirrored from
  `NativeRollup.sol`. A schema change means a new `ExecuteVerifier` through the 30-day
  governance path.
- **FCR trusts a full beacon node**, as the FCR spec requires the full vote view.
- **The emergency exit needs a witness at the request's anchor**, and skim serves only recent
  roots. Older anchors may need an archive node; the refund fallback covers that.
- **The anvil e2e still uses the labeled mock feed and registry.** The native e2e uses none.
- **Owner decisions, 2026-10-22** ([Stage 2](guide/stage-2.md)):
  - per-channel exit window (`ChannelPolicy.challengeWindow`, clamped to [1 hour, 30 days]);
  - nonce as checkpoint, no window extension;
  - `FORCE_DELAY` = 1 day;
  - 30-day governance with a fault-gated council.

## Next tasks
1. When EIP-8288 defines `get_deps_hash` for STARKs and a network carries it: implement
   `IDependencySource` over EIP-8141 frame introspection, deploy `ProofDependencyVerifier`, and
   schedule it through `RollupGovernance`.

M4 items done: FCR, witness prefetching (`AnchorBook::prefetch`), batched settlement
(`BatchSettler`, best effort across blocks; `settleFromBlock`, all or nothing within one L2
block), cost and size measurements (above).

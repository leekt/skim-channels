# Stage 2 target

Owner's decision, 2026-10-22: the design target is a **Stage 2 Native Rollup with Ephemeral
Execution Channels**. The rollup provides L1 DA, verified state roots, and permissionless
execution and settlement. On top of it, application channels run without persistent
application storage.

Two claims are kept apart:
- **Trust-minimized L2:** what this project builds and can test.
- **An official L2BEAT Stage 2 rating:** an external classification. It also requires the
  system to qualify as a *rollup* (L1 DA, state reconstructable by nodes, verifiable
  transitions). A pure state channel, whose data only participants hold, does not qualify,
  however trustless it is.

## Requirements vs. the v0.1 design

| Requirement | v0.1 design | Needed for Stage 2 |
|---|---|---|
| L2 execution validity | Native Rollup verification planned (M3) | Real L1 verification and canonical block acceptance (§6.4 of PROJECT) |
| Data availability | Unspecified | Everything needed to rebuild L2 state and channel outcomes is posted to L1 |
| Permissionless operation | Unspecified | Anyone can submit and prove L2 blocks |
| Trustless exit | Cooperative close + timeout refund | Settle the latest valid channel state without the operator |
| Governance | Unspecified | ≥ 30-day exit window for ordinary upgrades; emergency powers limited |

## Two exit paths

```
Normal exit:     L2 execution → native-verified block → receipt proof → L1 settlement
Emergency exit:  sequencer/prover unavailable → user posts signed checkpoint on L1
                 → challenge window: anyone may post a newer valid checkpoint → L1 settlement
```

The current `refund()` returns principal only. It does **not** protect what a participant
earned inside the channel, so it is not the trustless exit.

The emergency path must:
- **Stop stale-state settlement.** A higher nonce alone doesn't help if the older outcome is
  settled first. Settlement has to wait out a challenge window in which a newer checkpoint
  replaces the posted one (§13.4 of PROJECT).
- **Check validity, not just signatures.** A checkpoint signed by every participant can still
  be invalid. It must be checkable on L1 against an authenticated anchor: native
  re-execution or a proof of the module's transition.
- **Not depend on the operator for data.** Checkpoints and inputs must be available from L1
  (the rollup's DA), not only from participants.

## What the structure buys

- **Native Rollup:** reuses Ethereum's EVM verification and upgrade process. Less
  dependence on a separate proof system and Security Council.
- **L1 escrow:** assets never leave L1, so there's no L2 asset recovery procedure.
- **Ephemeral channels:** little persistent L2 application state, so a forced exit has less
  state to recover.

It does **not** remove the cost of proving existing L1 state (witnesses) or the DA obligation.

## Prototype (implemented 2026-10-22, awaiting review)
`ChannelSettlement.startExit` / `challengeExit` / `finalizeExit`, plus `CanonicalBlockRegistry`.

- **Validity without the operator.** A channel's outcome is a pure function of
  (request, input, L1 state at the anchor). `finalizeExit` re-runs the approved module on L1
  (same code hash as on L2) with a witness verified against the request's **L1-recorded**
  anchor. There is no L2 state to reconstruct: the ephemeral design pays off here.
- **Stale state.** Any all-signed request can start an exit. During `challengeWindow`, anyone
  can replace it with an all-signed request with a **strictly higher nonce**. The window is
  not extended. During an exit, the normal receipt path can only settle the pending request.
- **Liveness.** If nobody can finalize (for example, no witness for that anchor is obtainable)
  within a further window, `refund` reopens. There is exactly one terminal transition.
- **Block acceptance.** `CanonicalBlockRegistry` is permissionless. It requires genesis and
  single-chain lineage, an L1-recorded anchor, the block's data in this L1 transaction's blob
  (`BLOBHASH(0)`), and the verifier's approval. Its security is exactly the verifier's, and
  only a labeled mock verifier exists.

**Choices to review** (owner decisions; implemented with these defaults):
1. The nonce acts as the checkpoint version. No separate checkpoint type exists: a checkpoint
   *is* a signed `FinalRequest`.
2. The window is fixed per deployment, and challenges don't extend it.
3. The refund grace is one more window.
4. Exits must start before the channel deadline.
5. L1 module copies are approved at deployment.

**Measured on anvil:** `finalizeExit` costs 295k gas; receipt-based `settle` costs 306k.

## Governance and censorship resistance (implemented 2026-10-22)
- **One upgrade path.** `RollupGovernance` is the only thing that can change the block
  registry's verifier. Settlement, anchors, escrow and exits have no admin at all.
  - The owner schedules a replacement that takes effect only after `EXIT_WINDOW = 30 days`.
    Users who disagree leave first: normal settle, or the operator-free exit.
  - Anyone may execute a matured upgrade.
- **Security Council, restricted.** It can act without delay only after a fault was proven
  on chain. `CanonicalBlockRegistry.proveConflict` lets anyone show two verifier-accepted
  transitions with identical inputs (parent state, DA, anchor, forced transactions, profile)
  and different results. That freezes the registry:
  - no new blocks;
  - no block is reported accepted, so receipt settlement halts;
  - the L1 re-execution exit keeps working, because it never touches the verifier.

  Only then may the council replace the verifier, which unfreezes the registry.
- **Forced inclusion.** `forceInclude(signedTx)` queues a transaction on L1. Every block must
  consume all entries older than `FORCE_DELAY` (1 day). The verifier is given the rolling
  accumulator of the consumed entries, so a block can't claim inclusion it didn't do.
- **Permissionless.** Anyone may submit blocks, prove conflicts, force-include and execute
  matured upgrades.

## Native execution verification (implemented 2026-10-22)
`NativeRollupRegistry` accepts L2 blocks only from state roots that L1 verified by
re-executing them with the EXECUTE precompile. It reads ethrex's `NativeRollup.sol`
(lambdaclass/ethrex PR #6418, an EIP-8079 PoC).
- A block's raw header is accepted if keccak(header) is the verified tip, or if the L2's
  EIP-2935 history contract holds it in a later verified, final state (MPT proof).
- The header's state root must equal the verified root at its height.
- Measured end to end (`ts/e2e-native.ts`). Profile: `native-reexecution-devnet`.

## The full native stack (implemented 2026-10-22, run end to end on ethrex)
- **Real verifier behind the governed registry.** `ExecuteVerifier` is an
  `IStateTransitionVerifier` that calls ethrex's EXECUTE precompile (0x0101, schema 0x1501)
  with the SSZ stateless input. It accepts only if the precompile validates the payload and
  the validated payload *is* the submitted block:
  - block hash = keccak(header), with the header's parent, number and state root equal to the
    payload's;
  - the payload's gas limit and chain id are the rollup's;
  - its L1-messages root equals the registry's root for the messages consumed;
  - the DA commitment is the input itself.
- **Permissionless advancement.** `CanonicalBlockRegistry.submit` is open to anyone. In the
  e2e, an unprivileged account replays the SSZ inputs that ethrex's advancer published in L1
  calldata. Anyone running an ethrex node can produce them, so ethrex's single-advancer
  restriction applies only to ethrex's own contract, not to this registry. Each submission
  re-executes the block with EXECUTE, and the accepted roots match ethrex's.
- **Data availability.** The registry has two modes: `blobDA` (BLOBHASH(0)) or calldata. In
  calldata mode the DA commitment is keccak(proof). The proof is the stateless input, which
  carries the whole block (transactions included), and EXECUTE executes exactly it. So an
  accepted block's data is necessarily on L1, and withholding can't produce an accepted block.
- **L1 messages and forced inclusion** run on one queue (`IL1MessageQueue`). Blocks commit to
  the messages they consume, and EXECUTE checks that root inside the block (ethrex puts it in
  `parent_beacon_block_root`). `NativeRollupMessageQueue` reads ethrex's own `sendL1Message`
  queue. ethrex records no message times, so deadlines start at a permissionless `poke`.
- **Trustless L2 anchor feed.**
  - `AnchorSender` (L1) forwards a header as an L1 message only after `AnchorRegistry`
    authenticated it against L1's BLOCKHASH.
  - On L2, anyone calls `L2AnchorInbox.postFromL1` with a Merkle proof of that message
    against the L2 block's L1-messages root, read from EIP-4788's beacon-roots contract.
  - The mock system key is disabled (`system = 0`).
- **Measured** (`experiments/e2e-native-ethrex.json`): `submit` with EXECUTE costs about
  16.0M gas per L2 block, which is the L2 gas limit. One block per L1 transaction is the
  ceiling under EIP-7825.

**Not achievable today, with evidence:**
- **`native-proof-dependencies` (EIP-8288 + EIP-8357).** EIP-8288's reference implementation
  is listed as forthcoming. On L2BEAT's bogota devnet the rollup uses `MockDependencyVerifier`
  (a trusted prover's signature) because LeanSTARK dependencies can't be proven yet. Any
  verifier built against it here would be a mock under a native name, which the spec forbids.
  The registry is ready for it: `IStateTransitionVerifier` behind the 30-day governance path.

## Effect on what is built now (M0/M1)

- `ExecutionProfile` commits to `daSchemaHash`. A request signed under one DA scheme cannot
  settle under another, and a profile without L1 DA is distinguishable.
- `ExecutionProfile.kind` separates `mock-local` from native kinds in the hash itself.
- `FinalRequest.nonce` serves as the checkpoint version in the emergency-exit prototype above.

## Status of Native Rollup verification (as of 2026-10)

L2BEAT's research moved from the early EIP-8079 `EXECUTE` design to verification based on
EIP-8288 and EIP-8357. Runnable demos exist but use mock proofs; real proof integration and
DA are still in progress. M3 must target whatever a compatible devnet actually provides.

## Open questions

1. Checkpoint format: what state it commits to (module input, anchor, outcome?), and how L1
   checks its validity without the operator.
2. Challenge window length relative to the 30-day exit window and L1 finality.
3. How channel inputs and checkpoints reach L1 DA (L2 calldata in rollup blocks?), and the
   cost of that per channel.
4. Whether an emergency exit may use an anchor older than the latest one, and how a stale
   anchor is bounded (`maxAnchorLag`).
5. Permissionless block production and proving: who can submit, and how data withholding
   is handled.

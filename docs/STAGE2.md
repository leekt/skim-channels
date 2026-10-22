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

## Effect on what is built now (M0/M1)

- `ExecutionProfile` commits to `daSchemaHash`. A request signed under one DA scheme cannot
  settle under another, and a profile without L1 DA is distinguishable.
- `ExecutionProfile.kind` separates `mock-local` from native kinds in the hash itself.
- `FinalRequest.nonce` is kept so that checkpoints can extend it later. **No checkpoint or
  challenge encoding is defined yet**: it waits for the stale-state model below.

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

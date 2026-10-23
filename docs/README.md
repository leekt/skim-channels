# skim-channels documentation

## Guide

1. [FAQ](guide/faq.md): the project in three lines; use cases; vs. other L2s; how skim is used; deployment; blobs; status; Stage 2
2. [Use cases](guide/use-cases.md): where channels fit, and where they don't
3. [Compared](guide/compared.md): optimistic and zk rollups, state channels, native rollups; costs and trust
4. [Getting started](guide/getting-started.md): build, test, the anvil and ethrex end-to-end demos
5. [How it works](guide/how-it-works.md): anchors, witnesses, execution, block acceptance, receipts, settlement
6. [Using skim](guide/using-skim.md): what skim provides, the trust boundary, limits
7. [Native verification](guide/native-verification.md): EXECUTE, block registries, profiles, data availability and blobs, EIP-8288/8357
8. [Deployment](guide/deployment.md): what to deploy once, order, contract sizes, Amsterdam deployment costs
9. [CLI reference](guide/cli.md): `skim-channels header | witness | evidence`
10. [Trust and correctness](guide/trust-and-correctness.md): what is verified, what is trusted, labeled mocks
11. [Stage 2](guide/stage-2.md): emergency exit, governance, forced inclusion, owner decisions
12. [Troubleshooting](guide/troubleshooting.md): failure modes found while building, and their causes
13. [App channels](guide/app-channels.md): apps on channels with proven checkpoints, L1-locked assets, withdraw any time, operator-free exit (accounting built behind a mock verifier)
14. [Future considerations](guide/future-considerations.md): proof systems (SP1, RISC Zero), zkEVMs, native proof verification; deferred on purpose
15. [App enforcement rules](guide/app-enforcement.md): prediction rounds, 1:1 games, OTC matching, shared AMM. What users sign, who disputes with what evidence, what L1 checks, where withdrawals come from
16. [Stateful runtime](guide/stateful-runtime.md): stateful apps (clearing): L1 read view, AppState on an untrusted executor, L1 settlement, reorg replay, evidence retention

## Examples

| Example | Shows |
|---|---|
| [Read-and-Split on anvil](../ts/e2e.ts) | open and fund, previews at H0 and H1, a real L2 receipt mid-block, settle once, refund, emergency exit (mock block acceptance) |
| [Read-and-Split on ethrex](../ts/e2e-native.ts) | the same flow under native verification: EXECUTE, permissionless submission, anchors via proven L1 messages, no mocks |
| [Split module](../contracts/src/examples/SplitModule.sol) | an approved, stateless channel module |
| [App-channel recovery](../ts/e2e-app.ts) | deposits, checkpoints, a credit claim, the operator vanishing, the late checkpoint refused, recovery from L1 data alone, vault drained exactly |

## Operations and development

- **Checks:** `scripts/check.sh` runs everything; set `ETHREX` for the native e2e
- **Development:** [specification and architecture](../PROJECT.md), [contributor handoff](HANDOFF.md), [open work](TODO.md)
- **Fixtures:** `fixtures/` (Rust-generated encodings, receipt tries, witnesses; one captured EXECUTE input)

## Experiment logs

Measurements of the builds named in each log. Use the guides for current behavior.

| Doc | What was measured |
|---|---|
| [M1 live skim](experiments/m1-live-skim.md) | finalized and safe anchors on Sepolia, witness size and latency |
| [M2 anvil e2e](experiments/m2-anvil-e2e.md) | Read-and-Split on two chains, gas, emergency exit |
| [M3 native on ethrex](experiments/m3-native-ethrex.md) | EXECUTE re-execution, permissionless submission, trustless anchors, gas |
| [M4 FCR](experiments/m4-fcr.md) | Lighthouse fast confirmation vs. finality |
| [M4 settlement cost](experiments/m4-settlement-cost.md) | settle gas vs. L2 block size, batching |
| [App channels: accounting](experiments/app-channels-accounting.md) | experiments 1, 2 and 4: operator death, adversarial accounting, the one-day fence |
| [Prediction round cost](experiments/prediction-round-cost.md) | optimistic prediction rounds: safety tests, dispute gas, cost vs. the same game on L1 |
| [Prediction review fixes](experiments/prediction-review-fixes.md) | f4aab62 review: challenge-period floors, request coverage, request queue deadlines, exits without a witness |
| [Clearing](experiments/clearing.md) | skim → stateful Solidity → optimistic L1 settlement: recovery, handover, forced orders, live skim reads; cost against batched and per-transaction controls |
| [Sessions](experiments/sessions.md) | Disposable sessions over a stable vault: close, delete the operator's state, restart from a passive recovery package without historical RPC; lifetime costs |

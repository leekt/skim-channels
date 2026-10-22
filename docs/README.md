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

## Examples

| Example | Shows |
|---|---|
| [Read-and-Split on anvil](../ts/e2e.ts) | open and fund, previews at H0 and H1, a real L2 receipt mid-block, settle once, refund, emergency exit (mock block acceptance) |
| [Read-and-Split on ethrex](../ts/e2e-native.ts) | the same flow under native verification: EXECUTE, permissionless submission, anchors via proven L1 messages, no mocks |
| [Split module](../contracts/src/examples/SplitModule.sol) | an approved, stateless channel module |

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

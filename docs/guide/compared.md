# skim-channels compared

## Against a typical L2

| | Typical L2 (optimistic or zk) | skim-channels |
|---|---|---|
| Where funds live | Bridged into the L2; withdrawal delays and bridge risk | In L1 escrow throughout; no bridge |
| Access to L1 state | Mostly async messages; the L2 can't read L1 contracts directly | Reads any L1 contract at a proven block (skim supplies the proofs) |
| Liquidity | Fragmented: bridged copies, separate pools | None to fragment; L1 contracts are the source of truth |
| Execution validity | A separate proof system or fault-proof game, usually with a Security Council | L1 re-executes the block (EXECUTE); the council acts only after a proven fault |
| Operator gone | Forced withdrawal of bridged L2 balances | L1 re-runs the channel's computation itself; little L2 state to recover |
| State to secure | A large, permanent L2 state | Ephemeral channels; almost no lasting application state |
| Cost per transaction | Low (proofs amortized over thousands of transactions) | High: ~16M gas per L2 block to verify, 0.3–0.5M per settlement |
| Throughput | High | One L2 block per L1 transaction under EXECUTE |
| Composability | Open apps, many users | Fixed participants, cooperative close |
| Maturity | In production | Depends on EXECUTE (ethrex prototype) |

## Against state channels (Lightning, generalized channels)

| | State channels | skim-channels |
|---|---|---|
| What the outcome can depend on | The channel's own state | Any L1 state at an authenticated anchor |
| Who verifies a disputed outcome | The L1 contract, from signed states | L1 re-execution, either of the L2 block or of the module on the exit path |
| Data availability | Participants only | L1 (calldata or blobs) for the rollup; the exit needs the signed request, the input and an L1 witness |
| Rollup status | Not a rollup | A native rollup with channels on top |

## Against a plain native rollup

A native rollup alone gives L1-verified execution. Channels add:
- **L1 state reads** as witnesses checked against authenticated L1 roots;
- **escrow-based settlement** with no bridged assets;
- an **exit that doesn't depend on the rollup**: L1 re-runs the channel module directly, even if the rollup's verifier is frozen.

## Bottom line

For a handful of parties whose logic depends on live L1 state and whose money should never leave L1, this is simpler and has fewer trust assumptions than any L2. For cheap general-purpose transactions or open DeFi, a normal L2 is better.

# FAQ

The questions asked while this project was built, with their answers.

## What is this project, in three lines?

**skim-channels** runs execution channels where Ethereum L1 holds all the state and funds, while computation happens in short-lived channels on a native rollup.
Each channel reads authenticated L1 state through skim's verified proofs, executes on L2, and settles exactly once on L1. L1 itself checks the L2 execution by re-executing it.
It targets Stage 2: anyone can submit blocks, block data is on L1, upgrades wait 30 days, and users can exit without the operator.

## What is it for?

A small group of parties (two to a handful) who want to run a computation that needs Ethereum L1 state, when running it on L1 would be too expensive or too complex. The money stays in an L1 escrow the whole time and the result settles back on L1. Nobody bridges assets or trusts an operator with them.

- **Settlement priced by L1 state:** escrow, options or bets that pay out by reading an L1 oracle or a Uniswap pool at an agreed block. Example: "split this escrow by the ETH/USDC TWAP at block N."
- **Heavier off-chain logic over L1 data:** auctions, games, insurance claims or OTC trades whose rules need many L1 reads or a lot of computation, where only the final payout touches L1.
- **Apps that don't want their own L2 state:** no separate L2 state, no bridged token copies, no fragmented liquidity.

Limits:
- A channel can *read* any L1 contract but can only *move* funds that were escrowed in it.
- Closes are cooperative: every participant signs the final request.
- Small computations cost more, not less. Native verification is about 16M gas per L2 block. It pays off when many channels share blocks, or when the computation would be expensive on L1.

See [Use cases](use-cases.md).

## Why is this better than other L2s?

It's better on a few specific axes and worse on others. See [Compared](compared.md) for the full table.

- **Better:**
  - Funds never leave L1, so there's no bridge or withdrawal delay.
  - Any L1 contract can be read at a proven block.
  - There's no liquidity fragmentation.
  - Execution is checked by L1 re-execution, not a separate proof system.
  - Channels are short-lived, so there's little state to secure or recover.
- **Worse:**
  - Higher per-transaction cost, and lower throughput: one L2 block per L1 transaction under EXECUTE.
  - Fixed small groups with cooperative closes, so not open composable DeFi.
  - Depends on EXECUTE, which today exists only as ethrex's prototype.
  - Latency includes anchor confirmation and L1 settlement.

## How is skim used?

skim is the L1 data source, consumed over JSON-RPC: no crate dependency, and skim's code is unchanged.

| Need | skim feature |
|---|---|
| L1 state proofs for witnesses | `eth_getProof` at an exact block hash, built from verified SNAP answers |
| Confirmed anchors | `safe` / `finalized`, which skim answers only from its light client |
| Headers | `eth_getBlockByHash`, rebuilt and hash-checked by the runtime |
| Contract code | `eth_getCode` |

Everything skim returns is re-verified locally against the anchor's state root; only skim's light client is trusted. Verified live on Sepolia. See [Using skim](using-skim.md).

## Do we need to deploy settlement every time?

No. `ChannelSettlement` is deployed once and serves every channel. A new channel is just `open` (~300k gas) plus one `fund` per participant (~46k). The e2e scripts redeploy only because each run starts from empty chains.

A new settlement contract is needed only if something fixed at deployment changes:
- the rollup;
- the execution profile;
- the block registry it trusts;
- the anchor registry or the receipt verifier.

Verifier upgrades don't need one: `RollupGovernance` swaps the verifier inside the governed registry after 30 days. See [Deployment](deployment.md).

## Are we using blobs?

Not on the native path. There, block data is in **calldata**: the SSZ stateless input (~15 KB per block, all transactions included) goes in the `submit` transaction, and EXECUTE re-executes exactly that, so the data is on L1 by construction.

`CanonicalBlockRegistry` supports blob mode (`BLOBHASH(0)`), tested in forge only. EXECUTE reads its input from calldata, and contracts can't read blob contents, so blobs would need an EXECUTE variant bound to a blob via KZG. Calldata costs roughly 0.25–0.6M gas per block (an estimate), which is small next to EXECUTE's ~16M. See [Native verification](native-verification.md#data-availability).

## Can this be Stage 2?

The owner's framing: Stage 2 needs code to take precedence over operators.
- L2 execution validity, L1 DA, permissionless operation, and a trustless exit that settles the latest valid state without the operator.
- Governance with at least a 30-day exit window and a restricted Security Council.
- Being an official L2BEAT Stage 2 rollup is a separate question from being trust-minimized. A pure state channel whose data only participants hold is not a rollup.

What's implemented ([Stage 2](stage-2.md)):
- **Validity:** L1 re-execution via EXECUTE, behind a registry anyone can submit to.
- **DA:** calldata (or blobs) for every block.
- **Forced inclusion:** on the L1 message queue.
- **Operator-free exit:** L1 re-runs the channel module on an L1-recorded anchor, with a challenge window in which a newer signed request replaces a stale one.
- **Governance:** upgrades wait 30 days, and the council acts only after a fault is proven on chain.

## Does an L2 verified by re-execution save cost?

**No.** ethrex's EXECUTE charges the L2 block's **gas limit** plus 16 gas per input byte. It charges the limit, not gas used, because `gas_used` is producer-claimed and unverified until re-execution finishes. Measured: ~15.5–16M gas per L2 block, **even for empty blocks**.

Re-execution means L1 pays at least the L2's full computation, so this path costs **more** than running the app on L1. It buys security properties (L1-verified execution, L1 DA, separate state), not cheaper execution.

An L2 only saves cost when L1 does less work than the L2 did: L1 verifies a **succinct proof** of the computation and receives the **net state diff**, and never re-runs anything. That's the [app channels](app-channels.md) design: proven checkpoints with recoverable state. A rough illustration (an estimate, not a benchmark) gives ~2.6k L1 gas per interaction, against ~100k on L1.

## What's the plan for apps (users join, lock assets on L1, use the app, withdraw any time)?

**App channels** ([design](app-channels.md)):
- The app's channel runs many interactions off-chain.
- A validity proof per **checkpoint** shows the transition from the last accepted checkpoint, and the complete net state diff goes on L1 as calldata.
- Users withdraw against accepted checkpoints.
- If the operator vanishes, a forced request that isn't served within one day **freezes** the channel. Everyone then exits from the last accepted checkpoint, reconstructed from L1 data alone, with no new proof.
- Apps read L1 state through skim witnesses and can never modify it.

The vault and checkpoint accounting are built behind a labeled mock verifier. A real proof system is the open decision.

## Why do we need the EIP-8288/8357 profile?

We don't. The spec names three verification profiles. `native-proof-dependencies` is the newer direction, where L1 checks a *proof* instead of re-executing, which would mainly make verification cheaper than ~16M gas per block.

The re-execution profile already gives everything the project needs, and it runs end to end with no mocks. The `ProofDependencyVerifier` adapter is kept ready behind governance, but it can't be deployed:
- EIP-8288 is a draft with a "TBD" reference implementation, and it reserves the STARK scheme as invalid.
- The only devnet with these EIPs uses a placeholder key for mock proofs.

The owner accepted this as blocked (2026-10-22).

## What is the status?

All milestones are done and verified:

| Milestone | Status |
|---|---|
| M0 encodings | Rust, Solidity and TypeScript agree |
| M1 witnesses | Live on Sepolia via skim |
| M2 channels | Two-chain e2e |
| M3 native verification | On ethrex, no mocks |
| M4 | FCR, prefetch, batching, measurements |
| Stage 2 | Exit, governance, forced inclusion, permissionless submission, L1 DA, trustless anchors |

**Owner decisions:**
- a per-channel exit window, clamped to between 1 hour and 30 days;
- nonce as the checkpoint version;
- a 1-day forced-inclusion deadline;
- 30-day governance.

**Not done, by decision:** deploying the EIP-8288/8357 profile.

**Practical limits:**
- contracts must stay under ~9.7 KB on Amsterdam chains;
- one L2 block per L1 transaction;
- old anchors may need an archive node for an emergency exit;
- ethrex's EXECUTE is a prototype.

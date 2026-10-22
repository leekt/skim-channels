# Future considerations

Directions that are deliberately **not** being built now. Each would change the trust or cost model, and each is waiting on either a decision or outside maturity.

## Proof systems for app checkpoints (SP1, RISC Zero, …)

App channels accept a checkpoint when an `IAppCheckpointVerifier` accepts its proof ([design](app-channels.md)). Today that verifier is the labeled `MockAppCheckpointVerifier`. A real one would wrap an existing zkVM's Ethereum verifier:

| System | On-chain verification | Notes |
|---|---|---|
| SP1 (Succinct) | `ISP1Verifier.verifyProof(vkey, publicValues, proof)`; ~270k gas Groth16, ~300k PLONK (their docs) | A Rust program proves the checkpoint; GPU proving in practice |
| RISC Zero | `IRiscZeroVerifier.verify(seal, imageId, journalDigest)` | Same shape |

**Deferred (owner, 2026-10-22).** Adopting either reopens the "no non-native verifier" position. That's decision 1 in [app channels](app-channels.md). The vault doesn't change: a new `IAppCheckpointVerifier` would be deployed for **new** channels only.

## zkEVM proofs of app logic

Apps stay in Solidity (the owner's decision: apps are their own contracts). A zkEVM is needed **only if** the settlement rule is chosen to be a validity proof of the app's EVM execution. Running Solidity apps off-chain doesn't require one by itself. Rewriting apps as zkVM programs would change the app development model, not just the prover, and claims about its cost need measurement on a real workload.

## Native proof verification (EIP-8288 / EIP-8357)

This is the "native" version of the same idea: L1 validators verify proof dependencies outside the EVM. That would lower the cost of **verification**. Proving, DA and settlement costs remain, and it is a different mechanism from EXECUTE's full re-execution, which doesn't become cheap by itself. It's blocked today: EIP-8288 reserves its STARK scheme, and only mock-proof devnets exist. `ProofDependencyVerifier` is ready behind governance ([native verification](native-verification.md)).

## zkEVM landscape

As far as this project knows (mid-2026, not re-verified):
- **Two families:**
  - **zkVM-based** provers run an existing Ethereum client inside a general-purpose zkVM, for example SP1 with reth (RSP), RISC Zero with zeth, ZisK and OpenVM. They're Ethereum-equivalent by construction.
  - **Circuit-based** zkEVMs (Scroll, Linea and others) hand-build circuits for the EVM.
- **Proving a full L1 block in real time** (under one slot) was demonstrated in 2025 on GPU clusters. Ethereum's roadmap is moving toward L1 validators verifying zkEVM proofs instead of re-executing, which is where EIP-8288/8357 come from.
- **Hardware:** proving practical workloads means GPUs. CPU-only proving of non-trivial EVM batches is too slow for interactive use.

**For app channels:**
- A checkpoint of thousands of app transactions is a zkEVM proving job.
- Its cost in GPU time and latency is **unmeasured** here; it's experiment 7 in [app channels](app-channels.md).
- Verification on L1 is cheap and constant (~300k gas). The open question is the off-chain proving cost per checkpoint.

## Other

- **Multi-state channels:** unilateral disputes over intermediate checkpoints.
- **Blob DA on the native path:** needs an EXECUTE variant that binds the block body to a blob.
- **Anchor ancestry proofs:** many L1 anchors proven as ancestors of one recorded header.

# Open work

0. **App channels:** experiments 5–8 that don't need a prover (positions and termination rules, old anchors and reorgs, upgrades). Real proofs (experiment 3) are deferred to [future considerations](guide/future-considerations.md).
   - **Prediction rounds (app 1): done**, optimistic, measured against L1 ([log](experiments/prediction-round-cost.md)).
   - **Next:**
     - OTC (app 3) and AMM (app 4) disputes on the same layer;
     - blob DA for tickets and leaves (disputes need the data within the window);
     - cheaper first deposits (119k now);
     - batching beyond ~1,800 users per commit or proposal transaction.
   - **Stateful clearing: built** (optimistic settlement, account root on L1, handover, forced orders, runtime recovery, an executor that follows L1, oracle segments, proxy sessions; [log](experiments/clearing.md)).
   - **Next for clearing:**
     - matching guarantees for forced orders (they must be published, not yet matched);
     - automatic rebuild after a discarded proposal;
     - partial fills;
     - more assets;
     - blob DA for fills;
     - authenticated state-ready updates (skim serving raw block access lists), so the follower stops re-proving each block;
     - re-run mutation testing over sessions and segments;


1. **EIP-8288 proof dependencies** (blocked; owner accepted 2026-10-22): when EIP-8288 defines
   `get_deps_hash` for STARKs and a network carries it, implement `IDependencySource` over
   EIP-8141 frame introspection, deploy `ProofDependencyVerifier`, and schedule it through
   `RollupGovernance`.
2. **Blob DA on the native path:** needs an EXECUTE variant that binds the block body to a blob
   (KZG). Calldata is used until then.
3. **An L2 anchor feed without ethrex's L1-message mechanism**, for native rollups that deliver
   L1 block hashes differently.
4. **Multi-state channels:** unilateral disputes over intermediate checkpoints (beyond
   nonce-replaced final requests).
5. **Old anchors for emergency exits:** measure how far back skim's peers serve state roots, and
   document an archive-node path.

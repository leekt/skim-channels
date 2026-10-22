# Open work

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

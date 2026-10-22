# Native verification

## Profiles

Every request signs an `ExecutionProfile`:
- rollup, kind, genesis and program;
- fork schema, DA schema and executor code hash.

A settlement contract is deployed for one profile, and it rejects a block registry of another kind.

| Kind | Block acceptance | Status |
|---|---|---|
| `mock-local` (0) | `MockAcceptedBlockRegistry` / `MockTransitionVerifier`: operator assertion | Local development only; labeled |
| `native-reexecution-devnet` (1) | L1 re-executes the block with EXECUTE | **Working** on ethrex's prototype |
| `native-proof-dependencies` (2) | An EIP-8288 proof dependency with an EIP-8357 key | Adapter only; can't be deployed (see below) |

## EXECUTE (ethrex, PR #6418)

ethrex's L1 has an EIP-8079-style precompile at `0x0101`. It takes an SSZ `StatelessInput`: a 2-byte schema id, then the payload and the execution witness. It returns a 43-byte `StatelessValidationResult`:
- `successful_validation` at byte 32;
- `chain_id` at byte 33 (8 bytes, little-endian);
- `schema_id` at byte 41 (2 bytes, little-endian).

`ExecuteVerifier` accepts a transition only if the precompile validates it, and the validated payload *is* the submitted block:
- block hash = keccak(header), with the header's parent, number and state root matching the payload's;
- the payload's gas limit and chain id are the rollup's;
- the payload's `parent_beacon_block_root` (ethrex's L1-messages root) equals the registry's root for the messages consumed;
- the DA commitment is the input itself.

**Cost:** about 16M gas per L2 block, about the L2 block gas limit. One L2 block per L1 transaction is the ceiling under EIP-7825.

## Block registries

- **`CanonicalBlockRegistry`** (permissionless, governed): `submit(rawHeader, l1AnchorId, newMessageCursor, proof)`:
  - extends the tip from genesis (one chain);
  - checks the optional L1 anchor is recorded;
  - checks DA;
  - consumes L1 messages, including every overdue one (forced inclusion);
  - runs the verifier.

  `proveConflict` freezes it on a proven verifier fault. `RollupGovernance` is its only upgrade path.
- **`NativeRollupRegistry`:** reads ethrex `NativeRollup`'s EXECUTE-verified, final state roots. A block hash comes from the verified tip, or from an EIP-2935 history-contract proof against a later verified root.

## Data availability

| Mode | Commitment | Used |
|---|---|---|
| Calldata | keccak(proof); the proof is the SSZ input carrying the whole block, which EXECUTE executes | **Native e2e on ethrex** |
| Blob | `BLOBHASH(0)` of the submission transaction | Implemented; forge tests only |

**Are we using blobs?** Not on the native path. EXECUTE reads its input from calldata, and contracts can't read blob contents (only versioned hashes and KZG point evaluations). Blob DA with EXECUTE would need a precompile that binds the block body to a blob via KZG; ethrex's prototype and EIP-8079 as drafted don't have one.

Calldata costs roughly 0.25–0.6M gas per ~15 KB block (an estimate, not measured on its own), small next to EXECUTE's ~16M. Blob mode is ready for a verifier that binds to a versioned hash, such as a proof-based one.

## L1 messages and forced inclusion

ethrex blocks commit to the L1 messages they consume (a Merkle root in `parent_beacon_block_root`, checked by EXECUTE). `NativeRollupMessageQueue` exposes ethrex's `sendL1Message` queue to the registry:
- ethrex records no message times, so forced-inclusion deadlines (`FORCE_DELAY` = 1 day) start at a permissionless `poke`;
- `ForcedInclusionQueue` is a standalone queue for other rollups.

## EIP-8288 / EIP-8357 (proof dependencies)

`ProofDependencyVerifier` fixes the binding:
- the verification key comes from the EIP-8357 registry (its exact call convention);
- an `IDependencySource` attestation must cover the transition's public input (profile, parent state, DA, anchor, L1 messages, header).

It is **not deployable**. As checked on 2026-10-22:
- EIP-8288 is a draft with a "TBD" reference implementation, and "`LEANSTARK_SCHEME` is reserved: a frame that uses it is invalid until `get_deps_hash` is defined for it".
- L2BEAT's devnet registers "a placeholder for the mock proofs".
- The public bogota devnet has no code at the registry address.

The owner accepted this as blocked. It's not needed: re-execution already gives L1-verified execution.

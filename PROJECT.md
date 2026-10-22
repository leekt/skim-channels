# Skim Execution Channels: Project Specification

Version 0.1, 2026-10-22. Base: `leekt/skim` at `df686b70cd567210860582097e25a3f8b3fe6616`.
Section numbers are referenced from code and other docs. Since 2026-10-22 the design target
is Stage 2 ([STAGE2](docs/guide/stage-2.md)).

## 1. Overview
Ethereum L1 is the canonical persistent state layer. Ephemeral **execution channels** on a
Native Rollup:
- read L1 state at authenticated block roots;
- compute with temporary state;
- produce verifiable outcomes on L2;
- settle through application-defined L1 contracts;
- end without persistent per-channel application state.

The L2 still keeps its protocol state, block history and execution commitments. Only the
separate durable application-storage model goes away.

Inspired by Lightning and generalized state channels, Native Rollups, EIP-7928 (BAL),
EIP-8288, EIP-8360 (TCREATE) and skim's selective state sync.

## 2. Architecture
L1 → skim (state sync + proofs) and the anchor provider (FCR/safe/finalized)
→ execution channels (stateless EVM modules) → Native Rollup (execution verification)
→ accepted L2 block (hash, receipts root) → receipt proof → L1 settlement → L1.

skim provides state availability and proofs. Its local simulation is **not** execution
validity: authoritative execution happens under a separately verified L2 transition.

## 3. State model
- **3.1** All persistent application state is on L1: balances, authorization, configuration,
  escrow, settlement records.
- **3.2 Dynamic anchors.** Each execution picks the latest eligible anchor
  `L1Anchor{chainId, blockNumber, blockHash, stateRoot}`.
  - One execution uses one authenticated root, and the anchor never changes mid-execution.
  - Later executions can advance to newer anchors without reopening the channel.
- **3.3 Confirmation policies.** `Latest`, `Safe`, `Finalized`, `FcrConfirmed`. FCR needs
  a real evidence source. skim authenticates `safe` and `finalized`, while its `latest` is
  optimistic.
  - **MVP:** finalized anchors for security tests; optimistic anchors only in labeled local
    experiments. FCR comes later.
  - Never equate `safe` with FCR.
- **3.4 Lifetimes.**

  | State | Lifetime |
  |---|---|
  | L1 canonical state, settlement | permanent |
  | skim cache | local |
  | memory, transient storage, TCREATE contracts | one transaction |
  | signed channel state | offchain |
  | L2 blocks and receipts | retained for verification |

  The MVP forbids **per-channel persistent application writes**, not every L2 `SSTORE`.
- **3.5 L1 reads.** Don't redefine `SLOAD`. Instead, an explicit
  `IL1StateReader.readStorage(anchorId, account, slot, accountProof, storageProof)`
  verifies proofs against the authenticated root. It runs on an ordinary EVM.

## 4. Why skim
Reuse:
- `skim-cl`: authenticated headers;
- `skim-el`: BALs, headers, SNAP;
- `skim-snap`: verified proofs;
- `skim-bal`, `skim-state`: selective, versioned state;
- `skim-sim`;
- `skim-chain`.

**Values versus witnesses.** A BAL-maintained value at N+2 has no proof at N+2's root. Keep
`stateReady(anchor, readSet)` separate from `proofReady(anchor, readSet)`. Trustless
execution needs `proofReady`, and a proof from N must never be attached to a value at N+2.

**Witness lifecycle.**
1. Observe a candidate block.
2. Fetch proofs at its exact root.
3. Verify and retain them.
4. Wait for the policy.
5. Promote the anchor to executable.
6. Supply the package.

A reorged block's package is never reused. The package (`anchor`, account and storage
witnesses, `package_hash`) must prove membership or absence, the account→storage-root
binding, and the code hash when code is needed, all against one root. Unknown is never zero.

## 5. Channels
- **5.1 Terms.** `ChannelTerms{channelId, rollupId, settlementContract, executor,
  moduleCodeHash, participantRoot, policyHash, closeDeadline}`. Authorization and settlement
  configuration live on L1; requests travel offchain.
- **5.2 Lifecycle.**
  - Funding → Open (or → Refunded on funding timeout).
  - Open ↔ Executing (previews).
  - Executing → Outcome → Settled (verified receipt).
  - Open → Refunded (closing timeout).
  - Exactly one final request settles.
- **5.3 Final execution.**
  1. Authenticate the terms.
  2. Verify signatures.
  3. Select an anchor.
  4. Verify the witnesses.
  5. Run the approved module.
  6. Emit a deterministic `ChannelOutcome`.
  7. Include the transaction in an L2 block that the native mechanism accepts.
- **5.4 Executor.** `execute(finalRequest, witnessPackage, signatures)` emits
  `ChannelOutcome(channelId indexed, requestHash indexed, anchorId, policyHash, outcomeHash)`.
  - Bind the terms and executor version to the request and the rollup configuration.
  - Run only immutable approved modules: no arbitrary `DELEGATECALL`, no mutable external
    modules, no per-channel storage mappings.
  - Use `STATICCALL` for computation, check the module code hash, and emit only
    authenticated results.

## 6. Native Rollup verification
- **6.1** A block hash alone is not enough. L1 must know the block:
  - belongs to the rollup;
  - extends its canonical history;
  - came from a valid transition;
  - used the intended program and fork;
  - has authenticated header and receipt commitments;
  - used an authenticated L1 anchor.
- **6.2** `IAcceptedBlockRegistry.isAcceptedBlock(rollupId, blockHash)` plus metadata
  `AcceptedBlock{parentHash, stateRoot, receiptsRoot, l1AnchorId, executionProfileHash,
  blockNumber, accepted}`.
- **6.3 Profiles.** `mock-local`, `native-reexecution-devnet`, `native-proof-dependencies`.
  EIP-8079 is early; EIP-8288 and EIP-8357 are the newer direction. Check them against a
  real devnet. A mock is never Native Rollup security.
- **6.4 Acceptance requires all of:** rollup, genesis, parent lineage, program, fork schema,
  L1 anchor, valid execution, data availability. Competing forks never settle.

## 7. L2 outcome verification
- **7.1 Receipts, not BALs.** EIP-7928 commits to the whole encoded BAL, so there's no small
  per-entry proof.
- **7.2 Proof chain.** Accepted block → header → `receiptsRoot` → receipt MPT proof →
  `ChannelOutcome` → channel rules → settlement.
- **7.3 Evidence.** `{rollup_id, l2_block_hash, raw_header, transaction_index,
  encoded_receipt, receipt_proof, receipt_log_index, final_request, outcome}`.
- **7.4 Settlement checks:**
  1. The channel is funded, open and not expired.
  2. The block is accepted, and the header hash matches.
  3. `receiptsRoot` is extracted from the header.
  4. The MPT proof verifies (key `RLP(index)`; typed receipts keep their type byte, and a
     JSON-RPC receipt object is not the encoding).
  5. The receipt succeeded.
  6. The exact log is selected, and its emitter is the executor.
  7. Channel, terms, request, anchor and policy commitments match.
  8. The outcome verifies; apply the rules; mark the channel consumed; credit withdrawals.
- **7.5 Builder.** Header → all receipts → encode → rebuild the trie → check the root →
  target proof. Keep the evidence until settlement or refund is final.

## 8. L1 settlement
- **8.1** Settlement rules are application-defined. Reading L1 state grants no right to move
  L1 assets: escrow or explicit authorization is required.
- **8.2 Interface.** `open(terms)`, `fund(channelId)`, `settle(channelId, evidence)`,
  `refund(channelId)`.
- **8.3 Invariants:**
  - unique ids;
  - domain-separated signatures;
  - rollup and executor identity;
  - escrow ownership;
  - payout conservation;
  - no double settlement;
  - no cross-channel or cross-chain replay;
  - atomic terminal transitions;
  - safe withdrawals;
  - deterministic deadlines.

  The MVP needs all signatures on the final request, with a timeout refund of deposits.
  That is not a unilateral Lightning-style dispute (see STAGE2 for the emergency exit).

## 9. MVP: L1 Read-and-Split
- **L1 contracts:** `AllocationFixture` (`shareBps`), `ChannelSettlement`, `AnchorRegistry`,
  `AcceptedBlockRegistry`.
- **L2 contracts:** `L1StateReader`, `ChannelExecutor`, `SplitModule`.

Alice and Bob deposit 1 ETH each.
1. Preview at H0 (`shareBps` 6000): Alice 1.2, Bob 0.8.
2. `shareBps` becomes 7000 at H1. The same channel previews Alice 1.4, Bob 0.6, with no
   reopen.
3. Both sign the final request at H1. The executor verifies the H1 proof and emits the
   outcome.
4. The native verifier accepts the block. L1 verifies the receipt and settles once; a second
   settle fails.

**Refund test:** withhold the evidence; after the deadline, both recover their deposits
exactly once.

**Success criteria:**
- H0 → H1 without reopening;
- provably correct L1 storage in both executions;
- no persistent per-channel writes;
- a real L2 transaction produces the receipt;
- an accepted, verified block authenticates it;
- settlement happens exactly once;
- the refund works without the sequencer.

The mock registry is allowed early but must be labeled. Real native verification is its own
milestone.

## 10. Repository and integration
This is a companion repo. Use skim as a JSON-RPC service first (`eth_getProof`,
`eth_getStorageAt`, `eth_getBlockByHash`, `eth_call`, `eth_simulateV1`, BAL subscriptions).
- Don't duplicate SNAP proof code.
- Keep skim independent of the channel protocol.
- Don't depend on skim-hub.

## 11. Milestones
| Milestone | Scope | Done when |
|---|---|---|
| **M0** | Types, encodings, signature domains, profile manifest, mock registry, cross-language fixtures | Rust, Solidity and TS agree; malformed encodings are rejected |
| **M1** | Root-specific witnesses, candidate anchors, confirmation promotion, reorgs, retention, stateReady vs proofReady | A cached value can't pass as a newer-root proof; missing witnesses fail closed |
| **M2** | Funding, signatures, L1 proof reader, immutable module, outcome event, receipt-proof builder, settlement, refunds (mocked acceptance) | The demo is reproducible, with no persistent per-channel writes and no double settlement |
| **M3** | Real native verification: validity, program/fork identity, ancestry, headers, anchor, rejection of invalid transitions | Settlement works end to end on real verification |
| **M4** | FCR evidence, faster anchors, prefetching, proof batching, retention, limits, benchmarks | Measured against a reproducible baseline |

## 12. Required security tests
- **Anchors:**
  - advancing H0 → H1;
  - mixed roots, rejected;
  - unauthenticated root, rejected;
  - cached value without a proof, rejected;
  - reorg during collection, invalidated;
  - missing proof, fails closed.
- **Execution:** persistent writes, rejected; unauthorized module, rejected.
- **Receipts and outcomes:**
  - an unaccepted fork's receipt;
  - modified trie nodes;
  - modified receipt type or status;
  - a forged outcome emitter;
  - a modified signed request;
  - cross-channel proof reuse;
  - double settlement

  are all rejected.
- **Terminal transitions:**
  - settle and refund at the deadline produce exactly one terminal transition;
  - a withheld receipt still allows refund.
- **Profiles:**
  - a mock result under a real-native profile is rejected;
  - a changed native configuration can't silently authorize.

**Property tests:** payout conservation, unique settlement, canonical encoding, bounded
parsing, replay prevention.

## 13. Limitations and open research
- **13.1** Witness updates from BALs can't be derived from values alone.
- **13.2** Native Rollup APIs are still immature.
- **13.3** TCREATE is not a channel protocol.
- **13.4** Multi-transaction channels need checkpoints, challenges, revocation or unilateral
  settlement. A higher sequence number alone doesn't stop an older outcome being settled
  first.
- **13.5** A read-only view doesn't guarantee assets exist at settlement.
- **13.6** Witnesses and settlement cost calldata and gas. Any advantage comes from
  amortization, not single small computations.

## 14. Boundaries (v0.1)
**In scope:**
- selective L1 access;
- dynamic anchors;
- stateless computation;
- native-verified outcomes;
- receipt settlement;
- escrow channels;
- skim witnesses.

**Out of scope:**
- transparent execution of unmodified L1 contracts;
- L1 writes;
- automatic liquidity transfer;
- custom opcodes;
- new BAL commitments;
- cross-transaction `TSTORE`;
- virtual channels;
- unilateral checkpoint disputes (now a Stage 2 goal, see STAGE2);
- production funds;
- mainnet.

## 15. Implementation rules
- Keep skim standalone and pinned.
- No fallback RPC for production witnesses.
- Don't reinterpret opcodes.
- Never accept unauthenticated roots, or receipt inclusion without block acceptance.
- Label every mock.
- Keep fixtures deterministic.
- Add a regression test for every security fix.
- Report only measured benchmarks.

**Definition of success:** a channel reads authenticated L1 state, computes through a
native-verified L2 execution, and settles exactly once on L1, without persistent per-channel
L2 application storage.

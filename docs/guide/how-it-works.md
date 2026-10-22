# How it works

## 1. Open and fund (L1)

`ChannelSettlement.open(terms, participants, deposits, salt)` commits to the `ChannelTerms`:
- rollup, settlement, executor and module code hash;
- participants (strictly ascending);
- policy hash and deadline.

The `channelId` binds the L1 chain, the settlement contract, the opener and the salt. Each participant then `fund`s their exact deposit. When all have, the channel is `Open`.

The `ChannelPolicy` sets the anchor confirmation policy, the maximum anchor lag, and the channel's emergency-exit challenge window.

## 2. Anchors: one authenticated L1 root per execution

An anchor is `(chainId, blockNumber, blockHash, stateRoot)`, derived from **raw header bytes** (hash = keccak of the bytes), never from fields a node reports. `AnchorBook`:
- observes headers;
- promotes an anchor only on evidence at exactly the channel's policy (skim's `safe`/`finalized`, or the beacon `fast_confirmation` event), and only if the confirmed head links back to it;
- invalidates reorged anchors and their descendants permanently;
- prunes old anchors and prefetches witnesses.

A channel advances to newer anchors as L1 changes, without reopening.

## 3. Witnesses: proofs of the L1 state a channel reads

A `WitnessPackage` holds EIP-1186 account and storage proofs, all against the anchor's one state root, in canonical order and within bounds. `verify` is the only way to read from it:
- absence needs a proof;
- uncovered reads are errors;
- proofs from another root fail.

skim supplies the proofs (`eth_getProof` at the anchor's block hash), and they're re-verified locally. A value skim keeps current from BALs is *state-ready* but not *proof-ready*: there's no proof at the newer root, so it can't be used for execution.

## 4. Execution on L2

`ChannelExecutor.execute(call)`:
1. Binds terms, policy, request, input, executor, module code hash and execution profile.
2. Checks every participant's EIP-712 signature (low-s).
3. Verifies the witness via `WitnessVerifier`, against an anchor the `L2AnchorInbox` holds and within `maxAnchorLag`.
4. Calls the approved module with `STATICCALL`, so the module can't write state.
5. Emits `ChannelOutcome(channelId, requestHash, anchorId, policyHash, keccak(outcome))`.

The executor has no mutable storage. `preview` runs the same computation without emitting.

Anchors reach L2 in one of two ways:
- **trustlessly:** `AnchorSender` on L1 forwards a BLOCKHASH-checked header as an L1→L2 message, and anyone proves it into the inbox against the EXECUTE-verified message root;
- **through a labeled mock system key**, on chains without that mechanism.

## 5. Block acceptance on L1

Settlement trusts one `IAcceptedBlockRegistry`:

| Registry | Acceptance |
|---|---|
| `CanonicalBlockRegistry` + `ExecuteVerifier` | Permissionless `submit`: lineage from genesis, optional L1 anchor, DA (calldata or blob), L1 messages and forced inclusion, then **L1 re-executes the block** (EXECUTE). Governed by `RollupGovernance` |
| `NativeRollupRegistry` | Reads ethrex `NativeRollup`'s EXECUTE-verified roots: the verified tip, or an EIP-2935 history proof |
| `MockAcceptedBlockRegistry` | Operator assertion. **Mock**, for local development only |

A settlement deployed for a native profile rejects a registry of another kind.

## 6. Settlement

`settle(channelId, evidence)` checks, in order:
1. the channel is open and not past its deadline;
2. the block is accepted under the deployment's profile, and the header hashes to it with the accepted receipts root;
3. the receipt is included and succeeded;
4. the log is the executor's `ChannelOutcome` for this channel and this signed request;
5. the request binds the channel's terms, policy and profile, with an L1-recorded anchor;
6. the outcome conserves the escrow.

Payouts are pulled with `withdraw`. `settleFromBlock` settles several channels from one L2 block with one block check, and `BatchSettler` settles many on a best-effort basis.

## 7. Refunds and the emergency exit

- **Refund:** after the deadline, anyone returns funded deposits.
- **Emergency exit** (`EmergencyExit`):
  1. Anyone posts an all-signed request.
  2. During the channel's challenge window, a request with a strictly higher nonce replaces it.
  3. Then L1 re-runs the module itself, on a witness verified at the request's L1-recorded anchor.
  4. If nobody can finalize within another window, refund reopens.

Exactly one terminal transition happens per channel. See [Stage 2](stage-2.md).

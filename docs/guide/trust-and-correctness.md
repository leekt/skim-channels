# Trust and correctness

skim-channels is built so that it can be **slow or unavailable, but not wrong** about funds, within the trust model below.

## What is verified

| Data | Check |
|---|---|
| L1 header | keccak(raw bytes) = block hash; fields are parsed from those bytes |
| L1 anchor (off-chain) | Promoted only by evidence at the channel's policy, linked to the confirmed head; reorgs invalidate permanently |
| L1 anchor (on L1) | `AnchorRegistry`: keccak(header) = BLOCKHASH or EIP-2935 at that height. Settlement and exits accept only recorded anchors |
| L1 state | Every account and slot Merkle-proven against the anchor's state root, absence included; code hash checked; one root per package |
| Signatures | Every participant, EIP-712 over (L1 chain, settlement contract), low-s |
| Module | Approved by code hash; run via `STATICCALL` |
| L2 execution | L1 re-execution (EXECUTE) of every accepted block, bound to the header |
| L2 receipt | Merkle-Patricia proof under the accepted block's receipts root; status and log checked |
| Outcome | Bound to the channel, the signed request digest, anchor and policy; payouts conserve the escrow |

## What is trusted

| Component | For | Why |
|---|---|---|
| skim's light client | `safe` / `finalized` anchors | The trust-minimized base this project builds on |
| A full beacon node | FCR anchors | FCR needs every validator's latest vote; light-client data can't evaluate it |
| ethrex's EXECUTE prototype | Native verification | Not production software |
| Participants | Signing the final request | Closes are cooperative; stale requests are handled by nonce in the exit |
| Watchers (prediction rounds, clearing) | Challenging within the window (commit challenges, settlement proposals, signatures) | Optimistic paths: an unchallenged bad result finalizes. Payouts stay capped by the escrow |
| Witness holders (prediction rounds) | Resolving a round after its proof is no longer served | Pinned by watchers and participants; otherwise an archive node ([details](../experiments/prediction-review-fixes.md#a4-losing-the-resolution-witness)) |
| The clearing app's executor | Liveness only | It holds AppState; L1 re-checks every fill it settles ([stateful runtime](stateful-runtime.md)) |

## Labeled mocks

`MockAcceptedBlockRegistry`, `MockTransitionVerifier` and the `L2AnchorInbox.post` system key exist for local development. Each reports itself as a mock (`profileKind` 0, `SECURITY_LABEL`). A settlement deployed for a native profile rejects a mock registry. The native e2e uses none of them.

## Tested failure modes

- Mixed roots; unauthenticated roots; cached values without proofs.
- Reorgs; missing or truncated proofs.
- Persistent writes from a module; unapproved modules.
- Unaccepted blocks; tampered trie nodes, receipt types or statuses.
- Forged emitters; modified requests; cross-channel reuse.
- Double settlement; the deadline boundary; non-conserving outcomes.
- Stale exit requests; verifier faults; overdue forced transactions; lying headers.

Each has a named test, and each check was mutation-checked: removing it makes the test fail. See the [handoff](../HANDOFF.md).

# Disposable sessions: open, run, close, forget, start again

**Date:** 2026-10-23. **Design:** [sessions](../guide/stateful-runtime.md#sessions-open-close-start-again). **Code:**
- L1: `contracts/src/clearing/` (`ClearingVault`, the session lifecycle in `ClearingChannel` and `ClearingDisputes`);
- runtime: `ts/runtime/recovery.ts`;
- tests: `ts/e2e-sessions.ts`, `contracts/test/clearing/ClearingSession.t.sol`.

The question: what does it cost to **open, operate, close, and later start again**? The bar: a closed session becomes permanently safe to forget operationally, without making every user cash out first.

## The run (`npm run e2e-sessions`)

| Step | What happened |
|---|---|
| Session 1 | Opened by the app's vault (a proxy of the session code). Four users deposit. Two batches at L1 pins 21 and 328 (price 2000, then 2100); AppState carries between them. Alice claims a released withdrawal while it runs |
| Outstanding at close | Bob's withdrawal request that no batch served. Dave's deposit that no batch applied. Carol's resting order |
| Close | `beginClose` then `close` (nothing pending). Deposits and requests are refused from Closing on |
| Recovery material | A 1,341 B session package (4 users) and one 1,545 B claim file per user. Also published on L1 in 2 chunks, each accepted only as part of the final root |
| Forget | The operator's executor, journal and evidence store are deleted. Thirty days pass. Nobody can propose to session 1 or reopen it |
| Session 2 | Opened by the vault (id 2, one transaction) with a fresh, empty executor. Nothing of session 1 is replayed |
| Without history | All user actions go through an L1 endpoint that refuses `eth_getLogs`, old transactions and old blocks. The package verifies against session 1's final root with current-state reads only; rebuilding from L1 history fails there |
| Rollover | Alice moves her session-1 entitlement (minus the 0.5 ETH she already claimed) into the vault, then funds session 2 herself. The operator can't do it for her. A second rollover, or a wallet redemption after it, fails |
| Races | Carol: a wallet redemption triggered by someone else, then her rollover: the rollover fails (one payout record) |
| Outstanding items covered | Dave's unapplied deposit and Bob's queued request come back in their redemptions. Carol's resting order didn't survive, by design: session 2 starts from settled funds only |
| Replay | An order Alice signed for session 1 is refused by session 2's book (session-salted EIP-712 domain). In forge, the same signatures in a session-2 fill are a provable fault (`challengeFill`) |
| Concurrency | Bob redeems session 1 to his wallet while session 2's batch is open; session 2's batch then finalizes |
| End state | Session 1 holds no ETH and no USD: every entitlement was redeemed or rolled over by its owner |

## Lifetime costs (anvil L1; gas per L1 receipt)

| Phase | L1 transactions | Gas | Notes |
|---|---|---|---|
| App setup (once) | 6 | 10.4M | AnchorRegistry, ChainlinkAdapter, ClearingCodec, ClearingVault, and the session code (`ClearingChannel` + `ClearingDisputes`, 23.6 KB): deployed once, every session is a proxy of it |
| Open a session | 1 | 0.50M | `vault.openSession`: a 45-byte EIP-1167 proxy of the session code plus its configuration. Before proxies, each session redeployed the 23.6 KB of code: 2.38M here (Prague pricing) and **~35.7M on Sepolia under Amsterdam's code pricing** (measured) |
| Operate: per batch | 2 | 1.26M propose + 89k finalize | 1 fill per batch; the price check is most of it (local feed here; Sepolia's witness costs ~2.18M, see [Chainlink rounds](chainlink-rounds.md)) |
| Operate: idle | 0 | 0 | But an Active session must still be watched: after `takeoverDelay` anyone may propose |
| Close | 2 | 55k + 39k | `beginClose`, `close` (configuration is read from storage now: a few cold reads more per call) |
| Monitoring after the last proposal | | | 1 challenge window here (3,600 s). Bounded in general by `takeoverDelay` + one window after Closing begins. After Closed is final on L1: nothing |
| Start the next session | 1 | 0.50M | About 0.2 s to a ready empty app executor. No replay of the previous session |
| User: redeem to wallet / to vault / `vault.fund` | 1 each | 126k / 161k / 128k | `claim` while active: 89k |

**Recovery data by session size** (`ClearingSession.t.sol`, `test_publishFinalCost`). This is optional on-chain publication of every final leaf in aligned chunks:

| Users | Execution gas | Calldata |
|---|---|---|
| 16 | 119k | 1.7 KB |
| 128 | 647k | 13.8 KB |
| 512 | 2.51M | 55.3 KB |
| 1024 | 5.13M | 110.6 KB |

- **It's linear,** about 5k gas plus 108 B per user, with each chunk bounded.
- **The first measurement looked quadratic:** it ran out of memory at 1024 users. That came from the test assembling its input with repeated `bytes.concat`, not from the contract. The tree library now hashes in scratch space anyway, which keeps long loops allocation-free.
- **The off-chain package** grows 216 hex characters per user plus addresses. **A claim file** is constant: one leaf and 16 siblings.

## What this does and doesn't show

- **Shown:**
  - Closed is terminal.
  - Every user's settled funds stay claimable with nothing running, and without historical RPC.
  - Settled funds move to the next session only by their owner, never twice.
  - Old signatures don't replay.
- **Not shown here:**
  - **L1 finality of the close transaction:** anvil has none. On a real chain, stop watching once `close` is in a finalized block.
  - **History retention:** publishing calldata isn't a promise that nodes keep serving it. The passive files are the recovery material; publication is a checked extra.
- **Pricing:** pinned-proof validation (the price at the batch's anchor, checked at proposal and kept for disputes). A `getRoundData(roundId)` check is [evaluated separately](chainlink-rounds.md); it needs explicit round-selection and freshness rules.
- **Stack:** clearing runs on the app executor (imported channel and feed, read-only) and L1 checks the price with `ChainlinkAdapter`; `e2e-sessions` passes on that stack.

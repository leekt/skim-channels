# M3: native verification on ethrex

**Setup:** ethrex at `0393eb8` (contains PR #6418, native rollups). L1 is `fixtures/genesis/l1_native.json` (EXECUTE at `0x0101`); L2 is ethrex's native L2 (`native_l2.json`). **Script:** `ts/e2e-native.ts`. **Data:** `data/e2e-native-ethrex.json`. Nothing in block acceptance, the anchor feed or settlement is mocked.

## Flow

1. ethrex's `NativeRollup.sol` is deployed; ethrex's L2 runs with its advancer re-executing blocks on L1.
2. Our L1 side:
   - `AnchorRegistry`, `AnchorSender`, `NativeRollupMessageQueue`, `ExecuteVerifier`;
   - `RollupGovernance`, plus `CanonicalBlockRegistry` (calldata DA, genesis = the L2's block 0);
   - `ChannelSettlement` under profile `native-reexecution-devnet`.
3. Our L2 side: `L2AnchorInbox` **with no system key**, `WitnessVerifier`, `SplitModule`, `ChannelExecutor`.
4. H1 reaches L2 trustlessly:
   - `AnchorSender.send` (L1) checks the header against BLOCKHASH and records it;
   - ethrex relays the L1 message;
   - anyone proves it into the inbox against that L2 block's L1-messages root (EIP-4788).
5. The channel executes on L2. Settlement reverts before L1 has verified the block.
6. An unprivileged account replays ethrex's published SSZ inputs into `CanonicalBlockRegistry.submit`, block by block (1..16). `ExecuteVerifier` re-runs EXECUTE on each. The accepted state roots equal ethrex's own `stateRootHistory`.
7. Settlement through the canonical registry: 1.4 / 0.6, exactly once.

## Gas

| Step | Gas |
|---|---|
| L1 `AnchorSender.send` (record and L1 message) | 829,633 |
| L2 `postFromL1` (message proof) | 295,909 |
| L2 `execute` | 317,319 |
| L1 `CanonicalBlockRegistry.submit` (EXECUTE), mean per L2 block | 16,040,219 |
| L1 `settle` (canonical registry) | 506,777 |

EXECUTE costs about the L2 block gas limit (15M) plus overhead, so one L2 block per L1 transaction is the ceiling under EIP-7825. Gas on ethrex is higher across the board than on anvil, because Amsterdam reprices state access and creation.

## Found while running

- Deploying code costs ~1,600 gas per byte on ethrex Amsterdam, so contracts were split to stay under ~9.7 KB.
- ethrex's L1 header shape can't be rebuilt by alloy, so raw headers (`debug_getRawHeader`) are used.
- Reusing ethrex's advancer key for our transactions caused nonce races; a separate key fixed it.

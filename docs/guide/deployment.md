# Deployment

## What is deployed once, and what per channel

**`ChannelSettlement` is deployed once and serves every channel.** A new channel is just:

| Step | Gas (anvil) |
|---|---|
| `open(terms, participants, deposits, salt)` | ~300k |
| `fund(channelId)` per participant | ~46k |

A new settlement contract is needed only if something fixed at its deployment changes:
- `rollupId`;
- the execution profile (`profileHash`, `profileKind`), e.g. moving from the mock profile to a native one;
- the block registry it trusts;
- the anchor registry or `ReceiptVerifier`.

`EmergencyExit` is bound to its settlement once (`bindExits`), so the two are deployed together.

**Verifier upgrades don't need a new settlement:** `RollupGovernance` replaces the verifier inside `CanonicalBlockRegistry` after the 30-day delay, and the same settlement keeps working. Channels open on a settlement contract stay there until they settle, exit or refund.

## Order

**L1:**
1. `AnchorRegistry`, `WitnessVerifier`, `ReceiptVerifier`, the module's L1 copy (same bytecode as on L2).
2. Block acceptance: `NativeRollupMessageQueue` (or `ForcedInclusionQueue`), `ExecuteVerifier`, `RollupGovernance`, then `CanonicalBlockRegistry` (genesis header, governance address); `RollupGovernance.bind(registry)`.
3. `ChannelSettlement(Config)`, then `EmergencyExit(settlement, witnessVerifier, l1Modules)`, then `settlement.bindExits(exit)`.
4. `AnchorSender(nativeRollup, anchorRegistry)`, for the trustless anchor feed.

**L2:**
1. `L2AnchorInbox(system = 0, l1Sender = AnchorSender, l1ChainId)`.
2. `WitnessVerifier`, the modules, then `ChannelExecutor(profileHash, l1ChainId, inbox, witnessVerifier, modules)`.

`ts/e2e-native.ts` is the executable version of this list.

## Contract sizes on Amsterdam chains

Deploying code costs about **1,600 gas per byte** on ethrex Amsterdam (`SplitModule`, 981 B: 1.73M gas, vs. 265k on anvil Prague), under EIP-7825's 16.7M per-transaction cap. So every contract stays under ~9.7 KB:

| Contract | Runtime size |
|---|---|
| `ChannelSettlement` | ~9.0 KB |
| `ReceiptVerifier` | ~7.4 KB (holds the stateless outcome checks) |
| `CanonicalBlockRegistry` | ~6.9 KB |
| `WitnessVerifier` | ~6.3 KB |
| `EmergencyExit` | ~6.9 KB |
| `ChannelExecutor` | ~5.4 KB |

Check `forge build --sizes` before adding code. A 10.3 KB settlement failed to deploy on ethrex.

**Gas limits:** set an explicit gas limit for large L1 deployments; estimates came out too tight on ethrex. Keep L2 deployments under the L2 block gas limit (15M on ethrex's native L2).

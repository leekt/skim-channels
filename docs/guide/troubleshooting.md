# Troubleshooting

Failure modes found while building this, and their causes.

| Symptom | Cause | Fix |
|---|---|---|
| `header for 0x… does not hash to it` | The node's fork has a header shape alloy doesn't know (ethrex L1 runs LStar/Hegota), so a header rebuilt from JSON can't match | Enable the debug API so raw headers are used (`--http.api eth,net,web3,debug` on ethrex). Never bypass the check |
| Witness at anvil's genesis fails | anvil's genesis header claims the empty state root while dev accounts hold ether | Expected: the proof doesn't match the root. Use a later block |
| Witness right after sending a transaction fails | anvil answers `eth_sendTransaction` before mining; "latest" is still the old block | Wait for the receipt |
| Deployment "succeeds" with no contract address on ethrex | Your deployer is ethrex's advancer key (`--native-rollups.l1-pk`), so nonces race and the advancer's transaction replaces yours | Use a different funded key for your transactions |
| Large deployment fails or runs out of gas on ethrex | Amsterdam charges ~1,600 gas per deployed byte under a 16.7M per-transaction cap | Keep contracts under ~9.7 KB; set an explicit gas limit |
| `Transaction gas limit exceeded` on the L2 | The gas limit is above the L2 block gas limit (15M) | Use the estimate, or stay under 15M |
| ethrex build: `Failed to compile … OnChainProposer.sol` | ethrex pins `solc =0.8.31` | Put solc 0.8.31 on `PATH` (Foundry can install it) |
| `record` reverts `NotCanonical` | `BLOCKHASH(n)` is only available from block n+1 | Record an anchor after its block |
| Settle reverts `block not accepted` | The L2 block isn't in the registry yet, or the registry is frozen after a proven fault | Submit or wait; if frozen, use the emergency exit |
| `fast_confirmation` never arrives | The beacon node runs without FCR | Lighthouse ≥ v8.3.0 with `--enable-fast-confirmation`, or Lodestar `--chain.fastConfirmation` |

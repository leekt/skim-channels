# M4: settlement cost and batching

**Setup:** anvil Prague, current build. The final execution is placed in the middle of an L2 block with `FILLER` transactions on each side (`FILLER=n npm run e2e`). **Data:** `data/e2e-mock-local-fill*.json`.

## Settlement vs. L2 block size

| L2 block | `settle` gas | Evidence | Receipt proof nodes |
|---|---|---|---|
| 1 tx | 320,486 | 2,528 B | 1 |
| 31 tx | 392,090 | 3,296 B | 3 |
| 127 tx | 396,307 | 3,520 B | 3 |
| 255 tx | 396,343 | 3,520 B | 3 |

Cost follows receipt-trie depth (base 16), so it flattens quickly.

## Batching (forge, `contracts/test/Channel.t.sol`)

| Path | Gas per channel |
|---|---|
| `settle`, one channel | 315,124 |
| `settleFromBlock`, two channels from one L2 block (one acceptance and header check) | 280,975 |
| `BatchSettler.settleAll`, four channels, two failing on purpose (best effort) | 248,884 per attempted channel |

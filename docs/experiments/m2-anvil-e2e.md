# M2: Read-and-Split on two anvil chains

**Setup:** anvil Prague as L1 (chain 900) and L2 (chain 901). Block acceptance is the labeled `MockAcceptedBlockRegistry`. Anchors use `Latest` (optimistic) with the mock inbox feed. **Script:** `ts/e2e.ts`. **Data:** `data/e2e-mock-local*.json`.

## Flow

1. Open and fund on L1: two participants, 1 ETH each.
2. Preview at H0 (`shareBps` 6000): 1.2 / 0.8.
3. `shareBps` → 7000; preview at H1: 1.4 / 0.6, on the same channel with no reopen.
4. Execute on L2 as a real transaction, placed mid-block among filler transactions.
5. Receipt evidence: the whole block's receipt trie rebuilds to its receipts root.
6. Settlement before acceptance reverts. After `mockAccept` it settles 1.4 / 0.6, a second settle reverts, and the withdrawal arrives.
7. A second channel refunds after its deadline (anyone may call), exactly once.
8. A third channel takes the emergency exit: `startExit`; finalizing inside the window reverts; after the window, L1 re-runs the split and credits 1.4 / 0.6.

## Gas (receipt `gasUsed`, current build)

| Step | Gas |
|---|---|
| L1 `open` / `fund` | 300,830 / 45,644 |
| L2 `execute` (2 signatures, 1-slot witness) | 286,820 |
| L1 anchor `record` | 111,953 |
| L1 `settle` (31-tx L2 block) | 392,090 |
| L1 `withdraw` / `refund` | 28,519 / 71,838 |
| L1 `startExit` / `finalizeExit` | 130,364 / 317,643 |
| Witness package (1 slot) | 1,824 B |
| Evidence (31-tx block) | 3,296 B |

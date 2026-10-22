# M4: fast confirmation (FCR) vs. finality

**Setup:** Kurtosis `ethpandaops/ethereum-package`: 2 × (geth + `sigp/lighthouse:v8.3.0` with `--enable-fast-confirmation`), 6-second slots. **Test:** `crates/channel-runner/tests/live_fcr.rs`. The FCR evidence is the standard beacon SSE event `fast_confirmation`, resolved through the beacon block to a hash-checked EL header.

## Checks

- An `AnchorBook` with policy `FcrConfirmed`.
- skim-style `safe`/`finalized` evidence from the same node did **not** promote the anchor.
- The `fast_confirmation` event did, with a witness collected from geth at that root.

## Results

| Devnet | FCR block | Behind latest | `finalized` block | FCR ahead of finality |
|---|---|---|---|---|
| first (finality not yet running) | 14 | 0 | 0 | — |
| first, ~9 min in | 93 | 0 | 0 (finality stalled) | — |
| second (finalized epoch 2) | 133 / 137 / 141 | 1 / 0 / 0 | 64 | 69–77 blocks (~7–8 min) |

The first event arrived within 0.1–5.5 s of subscribing.

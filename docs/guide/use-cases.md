# Use cases

Channels fit **a few known parties** whose logic depends on **live L1 state**, and whose money should **never leave L1**.

## Where it fits

| Pattern | Example | Why channels |
|---|---|---|
| Settlement priced by L1 state | Escrow, options or bets paid by an oracle or a pool price at block N (the Read-and-Split demo, generalized) | The price is read with a proof at an agreed anchor; the escrow never moves |
| Heavy logic over L1 data | Auctions, games, insurance claims, OTC trades with many reads or a lot of computation | Only the payout touches L1; the logic runs once on L2, verified by L1 re-execution |
| Previews that track L1 | Show participants the outcome as L1 changes, then close on the latest anchor | The same open channel previews against newer anchors without reopening |
| No L2 state wanted | Apps that don't want bridged tokens or a separate chain | L1 contracts stay the source of truth; channels are ephemeral |

## Where it doesn't fit

| Need | Why not | Use instead |
|---|---|---|
| Cheap transactions for many users | Native verification costs ~16M gas per L2 block, and settlement 0.3–0.5M per channel | A general-purpose rollup |
| Open, composable DeFi (AMMs, lending on L2) | Channels have fixed participants and no persistent L2 state | A general-purpose rollup |
| Moving L1 funds the channel doesn't hold | Reading an L1 contract grants no right to spend from it | Escrow the funds in the channel |
| Unilateral disputes over many intermediate states | The MVP signs one final request; the exit handles stale requests by nonce | Future work (multi-state channels) |

## Choosing the confirmation policy

| Policy | When | Source |
|---|---|---|
| `Finalized` | Funds at stake; tolerate ~13 minutes of latency | skim's light client |
| `Safe` | Lower latency, with a small reorg risk accepted | skim's light client |
| `FcrConfirmed` | Low latency with a confirmation rule: measured 69–77 blocks ahead of finality | A full beacon node with FCR (Lighthouse `--enable-fast-confirmation`) |
| `Latest` | Labeled local experiments only | Not authenticated |

Settlement re-authenticates every anchor on L1 regardless, so the policy decides how much off-chain work can be wasted by a reorg, not whether funds can be stolen.

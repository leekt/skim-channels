"""Generates the skim-channels banner, logo and concept diagram (same palette as skim).

python3 assets/gen.py   # writes assets/banner.svg, assets/logo.svg, assets/concept.svg
"""
import math
import random
from pathlib import Path

OUT = Path(__file__).parent
DEFS = """
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#111939"/><stop offset="1" stop-color="#070A16"/></linearGradient>
    <radialGradient id="halo" cx="0.72" cy="0.6" r="0.5"><stop offset="0" stop-color="#3FA8FF" stop-opacity="0.13"/><stop offset="1" stop-color="#3FA8FF" stop-opacity="0"/></radialGradient>
    <linearGradient id="word" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#C3D4FF"/></linearGradient>
    <linearGradient id="arc" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#7C5CFF"/><stop offset="0.55" stop-color="#3FA8FF"/><stop offset="1" stop-color="#2EE6C5"/>
    </linearGradient>
    <radialGradient id="pick"><stop offset="0" stop-color="#FFFFFF"/><stop offset="0.5" stop-color="#8FF7E4"/><stop offset="1" stop-color="#2EE6C5"/></radialGradient>
    <filter id="glow" x="-10%" y="-80%" width="120%" height="260%"><feGaussianBlur stdDeviation="7"/></filter>"""
FONT = "Inter, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"


def ground(x0, x1, y0, rows, step, r, base, rng):
    """L1: a dot grid fading downward and outward (the state that stays on L1)."""
    out = []
    for i, x in enumerate(range(x0, x1 + 1, step)):
        for j in range(rows):
            op = base * (1 - j / rows) * (0.55 + 0.45 * math.sin(math.pi * i / max(1, (x1 - x0) // step)))
            op *= 0.75 + 0.5 * rng.random()
            out.append(f'  <circle cx="{x}" cy="{y0 + j * step}" r="{r}" fill="#5A6AA0" opacity="{op:.2f}"/>')
    return "\n".join(out)


def channel_arcs(spans, y, h_scale, width):
    """Channels: arcs that lift off L1 and land back on it (open, compute, settle)."""
    paths, rings = [], []
    for a, b in spans:
        h = (b - a) * h_scale
        d = f"M {a} {y} Q {(a + b) / 2} {y - 2 * h}, {b} {y}"
        paths.append(d)
        for x, s in ((a, 0.8), (b, 1.0)):
            rings.append(f'  <ellipse cx="{x}" cy="{y}" rx="{22 * s:.1f}" ry="{6 * s:.1f}" fill="none" stroke="#2EE6C5" stroke-width="1.2" opacity="0.35"/>')
            rings.append(f'  <ellipse cx="{x}" cy="{y}" rx="{38 * s:.1f}" ry="{10 * s:.1f}" fill="none" stroke="#2EE6C5" stroke-width="0.8" opacity="0.14"/>')
    glow = "\n".join(f'  <path d="{d}" fill="none" stroke="url(#arc)" stroke-width="{width * 3.5}" stroke-linecap="round" opacity="0.35" filter="url(#glow)"/>' for d in paths)
    line = "\n".join(f'  <path d="{d}" fill="none" stroke="url(#arc)" stroke-width="{width}" stroke-linecap="round"/>' for d in paths)
    return glow + "\n" + line + "\n" + "\n".join(rings)


def banner():
    rng = random.Random(7)
    spans = [(700, 860), (800, 1010), (930, 1080), (1030, 1210)]
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="400" viewBox="0 0 1280 400" role="img" aria-label="skim-channels: compute off-chain, settle on L1">
  <defs>{DEFS}
  </defs>
  <rect width="1280" height="400" fill="url(#bg)"/>
  <rect width="1280" height="400" fill="url(#halo)"/>
{ground(670, 1250, 262, 5, 26, 2.4, 0.30, rng)}
  <line x1="660" y1="250" x2="1250" y2="250" stroke="#5A6AA0" stroke-width="1" opacity="0.35"/>
{channel_arcs(spans, 250, 0.42, 4.5)}
  <g font-family="{FONT}">
    <text x="84" y="170" font-size="112" font-weight="800" letter-spacing="-4" fill="url(#word)">skim</text>
    <text x="88" y="224" font-size="52" font-weight="700" letter-spacing="-1" fill="url(#word)">channels</text>
    <text x="90" y="270" font-size="28" font-weight="600" fill="#2EE6C5">Compute off-chain. Settle on L1.</text>
    <text x="90" y="310" font-size="19" fill="#9AA7C7">Ephemeral execution channels on a native rollup</text>
    <text x="90" y="337" font-size="19" fill="#9AA7C7">funds stay on L1 · verified L1 reads via skim · EXECUTE-verified</text>
  </g>
</svg>
"""
    (OUT / "banner.svg").write_text(svg)


def logo():
    rng = random.Random(3)
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512" role="img" aria-label="skim-channels">
  <defs>{DEFS}
  </defs>
  <rect width="512" height="512" rx="112" fill="url(#bg)"/>
{ground(72, 440, 330, 4, 46, 4, 0.5, rng)}
{channel_arcs([(96, 300), (212, 416)], 318, 0.45, 12)}
</svg>
"""
    (OUT / "logo.svg").write_text(svg)


def box(x, y, w, h, title, lines, accent):
    t = "\n".join(f'    <text x="{x + 18}" y="{y + 58 + 22 * i}" font-size="15" fill="#9AA7C7">{l}</text>' for i, l in enumerate(lines))
    return f"""  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="#0D1430" stroke="{accent}" stroke-opacity="0.55" stroke-width="1.5"/>
  <g font-family="{FONT}">
    <text x="{x + 18}" y="{y + 32}" font-size="19" font-weight="700" fill="#FFFFFF">{title}</text>
{t}
  </g>"""


def arrow(x1, y1, x2, y2, label="", dy=-10, dashed=False):
    dash = ' stroke-dasharray="6 6"' if dashed else ""
    lab = f'<text x="{(x1 + x2) / 2}" y="{(y1 + y2) / 2 + dy}" font-size="13" fill="#C3D4FF" text-anchor="middle" font-family="{FONT}">{label}</text>' if label else ""
    return f'  <line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="#3FA8FF" stroke-width="2.5"{dash} marker-end="url(#head)"/>\n  {lab}'


def concept():
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="560" viewBox="0 0 1280 560" role="img" aria-label="skim-channels in one picture: L1 holds state and escrow; skim proves L1 reads; the channel executes on L2; L1 re-executes the L2 block and settles">
  <defs>{DEFS}
    <marker id="head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#2EE6C5"/></marker>
  </defs>
  <rect width="1280" height="560" fill="url(#bg)"/>
  <rect width="1280" height="560" fill="url(#halo)"/>
  <g font-family="{FONT}">
    <text x="60" y="58" font-size="28" font-weight="800" fill="url(#word)">skim-channels in one picture</text>
    <text x="60" y="88" font-size="16" fill="#9AA7C7">Funds and state never leave L1. A channel only borrows computation, and L1 checks it.</text>
  </g>
{box(60, 130, 330, 170, "Ethereum L1", ["escrow (ChannelSettlement)", "app state (any contract)", "anchors: BLOCKHASH / EIP-2935", "settlement + emergency exit"], "#7C5CFF")}
{box(475, 130, 330, 170, "skim", ["follows L1 over P2P", "light-client safe / finalized", "eth_getProof at the anchor", "→ witness, re-verified locally"], "#3FA8FF")}
{box(890, 130, 330, 170, "Channel on L2", ["ChannelExecutor (stateless)", "verifies witness + signatures", "module via STATICCALL", "emits ChannelOutcome"], "#2EE6C5")}
{box(890, 360, 330, 150, "Native verification", ["L1 re-executes the L2 block", "(EXECUTE precompile)", "CanonicalBlockRegistry"], "#3FA8FF")}
{box(475, 360, 330, 150, "Receipt proof", ["header → receiptsRoot", "MPT proof of the receipt", "the ChannelOutcome log"], "#7C5CFF")}
{arrow(390, 200, 470, 200, "state roots")}
{arrow(805, 200, 885, 200, "witness")}
{arrow(1055, 300, 1055, 355, "")}
{arrow(885, 435, 810, 435, "")}
  <text x="848" y="470" font-size="13" fill="#C3D4FF" text-anchor="middle" font-family="{FONT}">accepted</text>
  <text x="848" y="487" font-size="13" fill="#C3D4FF" text-anchor="middle" font-family="{FONT}">block</text>
{arrow(475, 435, 230, 305, "settle once", dy=-16)}
{arrow(225, 300, 225, 470, "", dashed=True)}
  <g font-family="{FONT}">
    <text x="60" y="495" font-size="14" fill="#9AA7C7">operator gone? emergency exit:</text>
    <text x="60" y="515" font-size="14" fill="#9AA7C7">L1 re-runs the module on the same witness</text>
  </g>
</svg>
"""
    (OUT / "concept.svg").write_text(svg)


if __name__ == "__main__":
    banner()
    logo()
    concept()

// The depth-16 sparse tree used on L1 (contracts/src/predict/SparseTree16.sol), off-chain:
// roots, single paths, and the multiproof SparseTree16.transition consumes.
import { keccak256, concat, zeroHash, type Hex } from "viem";

export const Z: Hex[] = [zeroHash];
for (let i = 0; i < 16; i++) Z.push(keccak256(concat([Z[i], Z[i]])));

export function levels(leaves: Hex[]): Hex[][] {
  const L = [leaves];
  for (let l = 0; l < 16; l++) {
    const prev = L[l], next: Hex[] = [];
    for (let i = 0; i < prev.length; i += 2) next.push(keccak256(concat([prev[i], prev[i + 1] ?? Z[l]])));
    L.push(next);
  }
  return L;
}

export const rootOf = (L: Hex[][]) => L[16][0] ?? Z[16];

export function siblings(L: Hex[][], idx: number): Hex[] {
  const out: Hex[] = [];
  for (let l = 0; l < 16; l++, idx >>= 1) out.push(L[l][idx ^ 1] ?? Z[l]);
  return out;
}

export function multiproof(L: Hex[][], indices: number[]): Hex[] {
  const out: Hex[] = [];
  let idx = [...indices];
  for (let l = 0; l < 16; l++) {
    const up: number[] = [];
    for (let i = 0; i < idx.length;) {
      const x = idx[i];
      if (x % 2 === 0 && idx[i + 1] === x + 1) i += 2;
      else { out.push(L[l][x ^ 1] ?? Z[l]); i += 1; }
      up.push(x >> 1);
    }
    idx = up;
  }
  return out;
}

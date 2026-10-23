// Recovery material for a closed clearing session: what lets every user redeem, and a new
// session start from settled balances, after the operator, its executor and its journal are
// gone, without any historical RPC.
//
// - The **session package** is every final account leaf plus the user list. It is a passive
//   file: anyone checks it against the session's on-chain final root with current-state reads
//   only (`verify`), so whoever holds a copy holds the same thing.
// - A **claim package** is one user's leaf and path: enough for that user to redeem alone.
// - Neither replaces the root: a package that doesn't rebuild the on-chain root is refused.
//
// A new session starts from settled funds only (rolled over into the vault), never from the
// old session's order book, executor state or overlay.
import type { Address, Hex } from "viem";
import type { C, Chain } from "./executor.ts";
import { EMPTY, leafHash, packLeaf, unpackLeaf, type Account } from "./clearing.ts";
import { levels, rootOf, siblings } from "./tree.ts";

export type SessionPackage = {
  kind: "skim-clearing/session-package";
  version: 1;
  l1ChainId: number;
  vault: Address;
  session: Address;
  sessionId: string;
  finalRoot: Hex;
  users: Address[];
  leaves: Hex; // LEAF_BYTES (108) per user, in index order
};

export type ClaimPackage = {
  kind: "skim-clearing/claim-package";
  version: 1;
  l1ChainId: number;
  session: Address;
  finalRoot: Hex;
  idx: number;
  user: Address;
  leaf: Account;
  siblings: Hex[];
};

const LEAF_HEX = 108 * 2;
const PHASE_CLOSED = 2;

export function leavesOf(p: SessionPackage): Account[] {
  const raw = p.leaves.slice(2);
  if (raw.length !== p.users.length * LEAF_HEX) throw new Error("package: leaves don't match users");
  return p.users.map((_, i) => unpackLeaf(`0x${raw.slice(i * LEAF_HEX, (i + 1) * LEAF_HEX)}`));
}

const rootOfLeaves = (ls: Account[]) => rootOf(levels(ls.map(leafHash)));

/** At close, from the operator's finalized leaves; refuses unless they rebuild the final root. */
export async function buildSessionPackage(l1: Chain, channel: C, fin: Map<number, Account>): Promise<SessionPackage> {
  const st = await l1.read<any[]>(channel, "state");
  if (Number(st[5]) !== PHASE_CLOSED) throw new Error("session is not closed");
  const cfg = await l1.read<any>(channel, "config");
  const n = Number(await l1.read(channel, "userCount"));
  const users: Address[] = [];
  for (let i = 0; i < n; i++) users.push(await l1.read<Address>(channel, "users", [BigInt(i)]));
  const leaves = users.map((_, i) => fin.get(i) ?? EMPTY);
  if (rootOfLeaves(leaves) !== st[0]) throw new Error("these leaves don't rebuild the session's final root");
  return {
    kind: "skim-clearing/session-package", version: 1, l1ChainId: l1.chainId, vault: cfg.vault, session: channel.address,
    sessionId: cfg.sessionId.toString(), finalRoot: st[0], users, leaves: `0x${leaves.map((l) => packLeaf(l).slice(2)).join("")}`,
  };
}

/**
 * Checks a package against the chain using current state only (no logs, no old transactions,
 * no block other than latest): the session is closed, its final root is the package's, the
 * leaves rebuild it, and the user list matches.
 */
export async function verifySessionPackage(l1: Chain, channel: C, p: SessionPackage): Promise<Account[]> {
  if (p.session.toLowerCase() !== channel.address.toLowerCase() || p.l1ChainId !== l1.chainId) throw new Error("package is for another session");
  const st = await l1.read<any[]>(channel, "state");
  if (Number(st[5]) !== PHASE_CLOSED) throw new Error("session is not closed");
  if (st[0] !== p.finalRoot) throw new Error("package root isn't the session's final root");
  const leaves = leavesOf(p);
  if (rootOfLeaves(leaves) !== p.finalRoot) throw new Error("package leaves don't rebuild its root");
  const n = Number(await l1.read(channel, "userCount"));
  if (n !== p.users.length) throw new Error("user count differs");
  for (let i = 0; i < n; i++) {
    const u = await l1.read<Address>(channel, "users", [BigInt(i)]);
    if (u.toLowerCase() !== p.users[i].toLowerCase()) throw new Error(`user ${i} differs`);
  }
  return leaves;
}

export function claimPackage(p: SessionPackage, idx: number): ClaimPackage {
  const leaves = leavesOf(p);
  return {
    kind: "skim-clearing/claim-package", version: 1, l1ChainId: p.l1ChainId, session: p.session, finalRoot: p.finalRoot,
    idx, user: p.users[idx], leaf: leaves[idx], siblings: siblings(levels(leaves.map(leafHash)), idx),
  };
}

/**
 * Optional on-chain publication of a package, in aligned chunks of `size` (a power of two)
 * leaves: `publishFinal(start, leaves, path)` arguments. L1 accepts a chunk only if it is part
 * of the final root; chunking keeps each transaction bounded at any session size.
 */
export function publicationChunks(p: SessionPackage, size: number): [bigint, Hex, Hex[]][] {
  if (size < 1 || (size & (size - 1)) !== 0) throw new Error("chunk size must be a power of two");
  const leaves = leavesOf(p);
  const L = levels(leaves.map(leafHash));
  const k = Math.log2(size);
  const out: [bigint, Hex, Hex[]][] = [];
  for (let start = 0; start < Math.max(leaves.length, 1); start += size) {
    const chunk = Array.from({ length: size }, (_, i) => packLeaf(leaves[start + i] ?? EMPTY).slice(2)).join("");
    out.push([BigInt(start), `0x${chunk}`, siblings(L, start).slice(k)]);
  }
  return out;
}

/** `redeem` arguments from a claim package (L1 checks the path against the final root). */
export function redeemArgs(c: ClaimPackage, toVault: boolean): unknown[] {
  return [c.idx, c.leaf, c.siblings, toVault];
}

export const toJson = (x: unknown) => JSON.stringify(x, (_k, v) => (typeof v === "bigint" ? v.toString() : v));

export function claimFromJson(s: string): ClaimPackage {
  const c = JSON.parse(s);
  c.leaf = Object.fromEntries(Object.entries(c.leaf).map(([k, v]) => [k, k === "requests" ? Number(v) : BigInt(v as string)]));
  return c;
}

// A watcher for the clearing channel's pending proposal: it tries every challenge L1 offers
// (each account, each fill, each segment's round) as a simulation, against what L1 itself
// published: the proposal's fills, the `Segments` event, and proofs at each segment's head.
// A challenge counts as "nothing wrong" only when L1 answers NotWrong; any other failure (a
// stale ABI, a missing proof) is an error, so a broken watcher can't pass silently.
import type { Address, Hex } from "viem";
import type { Chain, C } from "./executor.ts";
import type { L1ReadView, Snapshot } from "./l1view.ts";
import { levels, siblings } from "./tree.ts";
import { AGG_HOT_SLOT, EMPTY, FILL_BYTES, PROXY_PHASE_SLOT, leafHash, type Account, type Feed } from "./clearing.ts";

export type Fault = { kind: "account" | "fill" | "round"; at: number };

export async function watchProposal(o: {
  l1: Chain; channel: C; view: L1ReadView; feed: Feed; from: Address;
  fin: Map<number, Account>; next: Map<number, Account>; fills: Hex; fromBlock?: bigint;
}) {
  const { l1, channel: ch } = o;
  const faults: Fault[] = [];
  const attempt = async (kind: Fault["kind"], at: number, functionName: string, args: unknown[]) => {
    try {
      await l1.pub.simulateContract({ account: o.from, address: ch.address, abi: ch.abi, functionName, args });
      faults.push({ kind, at });
    } catch (e: any) {
      const name = e?.cause?.data?.errorName ?? e?.cause?.cause?.data?.errorName;
      if (name !== "NotWrong") throw new Error(`watcher: ${functionName}(${at}) failed for another reason: ${name ?? e?.shortMessage ?? e}`);
    }
  };
  // Accounts: every user's leaf, replayed by L1 through the batch.
  const n = Number(await l1.read(ch, "userCount"));
  const finDense = Array.from({ length: n }, (_, i) => leafHash(o.fin.get(i) ?? EMPTY));
  const nextDense = finDense.map((h, i) => (o.next.has(i) ? leafHash(o.next.get(i)!) : h));
  for (let i = 0; i < n; i++) {
    await attempt("account", i, "challengeAccount", [
      i, o.fin.get(i) ?? EMPTY, siblings(levels(finDense), i), o.next.get(i) ?? o.fin.get(i) ?? EMPTY, siblings(levels(nextDense), i), o.fills,
    ]);
  }
  // Fills and rounds: the proposal's segments, as L1 emitted them.
  const nFills = (o.fills.length - 2) / 2 / FILL_BYTES;
  let segs = { firstFills: [] as number[], prices: [] as bigint[], heads: [] as bigint[], rounds: [] as bigint[] };
  if (nFills > 0) {
    const evs = await l1.pub.getContractEvents({ address: ch.address, abi: ch.abi, eventName: "Segments", fromBlock: o.fromBlock ?? 0n }) as any[];
    if (!evs.length) throw new Error("watcher: no Segments event for a batch with fills");
    segs = evs[evs.length - 1].args;
    for (let f = 0; f < nFills; f++) {
      await attempt("fill", f, "challengeFill", [o.fills, BigInt(f), segs.firstFills, segs.prices, segs.heads]);
    }
    for (let s = 0; s < segs.heads.length; s++) {
      const b = await l1.pub.getBlock({ blockNumber: segs.heads[s] });
      const snap: Snapshot = { chainId: o.view.chainId, number: b.number!, hash: b.hash!, parentHash: b.parentHash, stateRoot: b.stateRoot, policy: { kind: "latest" }, speculative: true };
      const w = o.view.witness(snap, [{ account: o.feed.proxy, slots: [PROXY_PHASE_SLOT] }, { account: o.feed.aggregator, slots: [AGG_HOT_SLOT] }]);
      await attempt("round", s, "challengeRound", [BigInt(s), segs.heads, segs.rounds, w.package]);
    }
  }
  return { faults, finDense, nextDense, checked: { accounts: n, fills: nFills, rounds: segs.heads.length } };
}

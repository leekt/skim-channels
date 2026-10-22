// Operator runtime for the clearing channel (ClearingChannel on L1, ClearingBook on the
// executor): docs/guide/stateful-runtime.md.
//
// Per batch: one L1 snapshot → proofs for exactly the slots ClearingBook reads (price; the
// channel's user list, queues, and the deposits of the users concerned) → pin → open the
// batch (deposits, withdrawal requests and forced orders applied first, as L1 replays them)
// → orders and fills → seal → propose: the packed fills, the changed accounts with a
// multiproof against the finalized root, the queue cursors, the forced-order statuses, a
// price-only witness, and a bond. Anyone finalizes after the window.
//
// `recover` rebuilds the finalized accounts from L1 alone (published proposals that
// finalized), so another operator can `adopt` them and continue after the takeover delay.
import {
  encodeAbiParameters, encodePacked, keccak256, toHex, zeroHash, decodeEventLog, decodeFunctionData, concat,
  type Abi, type Address, type Hex,
} from "viem";
import type { PrivateKeyAccount } from "viem/accounts";
import { L1ReadView, type Policy, type Snapshot, type Witness, type Read } from "./l1view.ts";
import { BatchRuntime, type JournalBatch } from "./batches.ts";
import { Chain, type C } from "./executor.ts";
import { EvidenceStore } from "./evidence.ts";
import { levels, multiproof, rootOf } from "./tree.ts";

export type Account = {
  eth: bigint; usd: bigint; ethIn: bigint; usdIn: bigint; ethOut: bigint; usdOut: bigint; nonce: bigint; requests: number;
};
export const EMPTY: Account = { eth: 0n, usd: 0n, ethIn: 0n, usdIn: 0n, ethOut: 0n, usdOut: 0n, nonce: 0n, requests: 0 };
export type Order = { trader: Address; sellToken: number; sellAmount: bigint; buyAmount: bigint; nonce: bigint; expiry: bigint };

const LEAF_TAG = keccak256(toHex("skim-clearing/account-leaf/v0"));
const accountT = {
  type: "tuple",
  components: [
    { name: "eth", type: "uint128" }, { name: "usd", type: "uint128" }, { name: "ethIn", type: "uint128" },
    { name: "usdIn", type: "uint128" }, { name: "ethOut", type: "uint128" }, { name: "usdOut", type: "uint128" },
    { name: "nonce", type: "uint64" }, { name: "requests", type: "uint32" },
  ],
} as const;
export const orderT = {
  type: "tuple",
  components: [
    { name: "trader", type: "address" }, { name: "sellToken", type: "uint8" }, { name: "sellAmount", type: "uint128" },
    { name: "buyAmount", type: "uint128" }, { name: "nonce", type: "uint64" }, { name: "expiry", type: "uint64" },
  ],
} as const;
export const eip712Order = { Order: orderT.components.map((c) => ({ name: c.name, type: c.type })) };
export const orderHash = (o: Order) => keccak256(encodeAbiParameters([orderT], [o as any]));

export function leafHash(a: Account): Hex {
  if (!a.eth && !a.usd && !a.ethIn && !a.usdIn && !a.ethOut && !a.usdOut && !a.nonce && !a.requests) return zeroHash;
  return keccak256(encodeAbiParameters([{ type: "bytes32" }, accountT], [LEAF_TAG, a as any]));
}
export const packLeaf = (a: Account) => encodePacked(
  ["uint128", "uint128", "uint128", "uint128", "uint128", "uint128", "uint64", "uint32"],
  [a.eth, a.usd, a.ethIn, a.usdIn, a.ethOut, a.usdOut, a.nonce, a.requests]);
export function unpackLeaf(h: Hex): Account {
  const b = h.slice(2);
  const n = (from: number, len: number) => BigInt(`0x${b.slice(from * 2, (from + len) * 2)}`);
  return {
    eth: n(0, 16), usd: n(16, 16), ethIn: n(32, 16), usdIn: n(48, 16), ethOut: n(64, 16), usdOut: n(80, 16),
    nonce: n(96, 8), requests: Number(n(104, 4)),
  };
}
const norm = (a: any): Account => ({
  eth: BigInt(a.eth), usd: BigInt(a.usd), ethIn: BigInt(a.ethIn), usdIn: BigInt(a.usdIn), ethOut: BigInt(a.ethOut),
  usdOut: BigInt(a.usdOut), nonce: BigInt(a.nonce), requests: Number(a.requests),
});

const word = (x: bigint): Hex => toHex(x, { size: 32 });
const arraySlot = (slot: bigint, i: bigint, width: bigint) => BigInt(keccak256(word(slot))) + i * width;
const cumInSlot = (idx: number) => keccak256(encodeAbiParameters([{ type: "uint32" }, { type: "uint256" }], [idx, 1n]));

export type Action = { kind: "order"; order: Order; sig: Hex } | { kind: "fill"; a: Hex; b: Hex };
/** Executor state a batch opens from (plans and recoveries start here). */
export type OpenState = { users: number; reqCursor: number; forcedCursor: number; scannedTo: bigint };
export type Prepared = {
  witness: Witness; l1Witness: Witness; forced: { orders: Hex[]; sigs: Hex[] }; depositUsers: number[]; scannedTo: bigint;
};


export function mergeAbi(core: C, half: C): C {
  const names = new Set(core.abi.filter((x: any) => x.type === "function").map((x: any) => x.name));
  return { address: core.address, abi: [...core.abi, ...half.abi.filter((x: any) => x.type !== "function" || !names.has(x.name))] as Abi };
}

export class ClearingOperator extends BatchRuntime<Action, OpenState> {
  book: C; l1view: C; readonly op: PrivateKeyAccount;
  readonly l1: Chain; readonly channel: C; readonly anchors: C; readonly priceFeed: Address; readonly priceSlot: Hex;
  readonly evidence: EvidenceStore; readonly bond: bigint;
  fin = new Map<number, Account>(); // finalized leaves (L1's committed state, as this operator knows it)
  pendingNext?: { no: bigint; next: Map<number, Account> };
  scannedTo = 0n; // last L1 block scanned for deposits

  constructor(o: {
    view: L1ReadView; exec: Chain; book: C; l1view: C; op: PrivateKeyAccount; l1: Chain; channel: C; anchors: C;
    priceFeed: Address; priceSlot: Hex; evidence: EvidenceStore; policy: Policy; bond: bigint;
    journal: string; maxAnchorAge: bigint; ageMargin: bigint;
  }) {
    super(o.view, o.exec, o.journal, o.policy, o.maxAnchorAge, o.ageMargin);
    this.book = o.book; this.l1view = o.l1view; this.op = o.op; this.l1 = o.l1;
    this.channel = o.channel; this.anchors = o.anchors; this.priceFeed = o.priceFeed; this.priceSlot = o.priceSlot;
    this.evidence = o.evidence; this.bond = o.bond;
    this.watched = [o.channel.address, o.priceFeed];
  }

  private async events(name: string, fromBlock: bigint, toBlock: bigint) {
    const logs = await this.l1.pub.getLogs({ address: this.channel.address, fromBlock, toBlock });
    const out: any[] = [];
    for (const log of logs) {
      try {
        const ev = decodeEventLog({ abi: this.channel.abi, data: log.data, topics: log.topics }) as any;
        if (ev.eventName === name) out.push({ ...ev.args, tx: log.transactionHash, block: log.blockNumber });
      } catch { /* other */ }
    }
    return out;
  }

  // ---- BatchRuntime hooks ------------------------------------------------------------------

  protected async openState(): Promise<OpenState> {
    return {
      users: Number(await this.exec.read(this.book, "userCount")),
      reqCursor: Number(await this.exec.read(this.book, "reqCursor")),
      forcedCursor: Number(await this.exec.read(this.book, "forcedCursor")),
      scannedTo: this.scannedTo,
    };
  }

  /**
   * The slots ClearingBook will read at `snap` when it opens from `from`, and the data it
   * needs alongside. Recoveries merge several batches: their deposit users are included.
   */
  protected async prepare(snap: Snapshot, from: OpenState, forBatches: JournalBatch<Action, OpenState>[]): Promise<Prepared> {
    const ch = this.channel.address;
    const nUsers = Number(await this.view.value(snap, ch, word(0n)));
    const nReq = Number(await this.view.value(snap, ch, word(2n)));
    const nForced = Number(await this.view.value(snap, ch, word(3n)));
    const slots: Hex[] = [word(0n), word(2n), word(3n)];
    for (let i = from.users; i < nUsers; i++) slots.push(word(arraySlot(0n, BigInt(i), 1n)));
    const users = new Set<number>();
    for (const b of forBatches) for (const u of (b.prepared as Prepared).depositUsers) users.add(u);
    for (const d of await this.events("Deposited", from.scannedTo + 1n, snap.number)) users.add(Number(d.idx));
    for (let p = from.reqCursor; p < nReq; p++) {
      const s0 = arraySlot(2n, BigInt(p), 2n);
      slots.push(word(s0), word(s0 + 1n));
      users.add(Number(BigInt(await this.view.value(snap, ch, word(s0))) & 0xffffffffn));
    }
    const forced = { orders: [] as Hex[], sigs: [] as Hex[] };
    if (nForced > from.forcedCursor) {
      const evs = (await this.events("ForcedOrder", 0n, snap.number)).sort((a, b) => Number(a.pos - b.pos));
      for (let p = from.forcedCursor; p < nForced; p++) {
        const s0 = arraySlot(3n, BigInt(p), 2n);
        slots.push(word(s0), word(s0 + 1n));
        const ev = evs.find((e) => Number(e.pos) === p);
        if (!ev) throw new Error(`forced order ${p}: no event`);
        forced.orders.push(ev.order);
        forced.sigs.push(ev.sig);
      }
    }
    const depositUsers = [...users].sort((a, b) => a - b);
    for (const u of depositUsers) slots.push(cumInSlot(u));
    const reads: Read[] = [{ account: this.priceFeed, slots: [this.priceSlot] }, { account: ch, slots }];
    const witness = this.view.witness(snap, reads); // throws ProofNotReady: nothing changed yet
    const l1Witness = this.view.witness(snap, [{ account: this.priceFeed, slots: [this.priceSlot] }]);
    return { witness, l1Witness, forced, depositUsers, scannedTo: snap.number };
  }

  protected async openWith(prepared: unknown): Promise<bigint> {
    const p = prepared as Prepared;
    await this.exec.send(this.l1view, "pin", [p.witness.rawHeader, p.witness.package], this.op);
    await this.exec.send(this.book, "openBatch", [p.witness.anchorId, p.depositUsers, p.forced.orders, p.forced.sigs], this.op);
    this.scannedTo = p.scannedTo;
    const no = BigInt(await this.exec.read(this.book, "current"));
    this.evidence.pin(`clearing:batch:${no}:${p.witness.anchorId.slice(2, 10)}`, {
      purpose: `clearing batch ${no}`, anchor: { chainId: this.view.chainId, blockNumber: `${p.scannedTo}`, blockHash: "0x" as Hex },
      rawHeader: p.witness.rawHeader, package: p.witness.package, reads: [], note: `l1Witness: ${p.l1Witness.package}`,
    });
    return no;
  }

  protected async run(action: Action) {
    if (action.kind === "order") await this.exec.send(this.book, "submitOrder", [action.order, action.sig], this.op);
    else await this.exec.send(this.book, "fill", [action.a, action.b], this.op);
  }

  protected async sealOne() {
    await this.exec.send(this.book, "seal", [], this.op);
  }

  /**
   * The executor lost its state (no checkpoint to return to): deploy a fresh book, adopt L1's
   * finalized accounts, and re-execute every batch that is proposed but not yet final, with
   * the proofs it used. Then the executor is where the first unproposed batch began.
   */
  protected async rebuild() {
    const view = await this.exec.deploy(ROOT_OF(this), this.op, "L1View.sol", "L1View", [BigInt(this.view.chainId)]);
    const [l1v, ch, feed, slot, band] = [view, this.channel.address, this.priceFeed, this.priceSlot, 100n];
    const book = await this.exec.deploy(ROOT_OF(this), this.op, "ClearingBook.sol", "ClearingBook", [l1v.address, ch, BigInt(this.view.chainId), feed, slot, band, this.op.address]);
    this.l1view = view;
    this.book = book;
    const fin = await ClearingOperator.recover(this.l1, this.channel);
    await this.adopt(fin);
    for (const b of this.batches) {
      if (b.state !== "proposed") continue;
      const no = await this.openWith(b.prepared);
      for (const l of b.log) if (l.ok) await this.run(l.action);
      await this.sealOne();
      // the fresh book numbers batches from 1 again
      if (this.pendingNext?.no === BigInt(b.no)) this.pendingNext.no = no;
      b.no = `${no}`;
      b.checkpoint = undefined;
    }
  }

  // ---- proposals -----------------------------------------------------------------------------

  /** The proposal for batch `no`, against the finalized state this operator knows. */
  async proposal(no: bigint, tamper?: (news: Map<number, Account>) => void) {
    const [anchorId, fills, idx, olds, news, reqTo, forcedTo, statuses] = await this.exec.read<any[]>(this.book, "proposal", [no]);
    const n = Number(await this.l1.read(this.channel, "userCount"));
    const next = new Map<number, Account>();
    const order = (idx as number[]).map((x, i) => i).sort((a, b) => Number(idx[a]) - Number(idx[b]));
    for (const i of order) {
      const k = Number(idx[i]);
      const known = this.fin.get(k) ?? EMPTY;
      if (leafHash(norm(olds[i])) !== leafHash(known)) throw new Error(`account ${k}: book and finalized state disagree`);
      next.set(k, norm(news[i]));
    }
    tamper?.(next);
    const dense = Array.from({ length: n }, (_, i) => leafHash(this.fin.get(i) ?? EMPTY));
    const changed = [...next.keys()].filter((k) => leafHash(next.get(k)!) !== dense[k]).sort((a, b) => a - b);
    const updates = changed.length
      ? concat(changed.map((k) => concat([encodePacked(["uint32"], [k]), packLeaf(this.fin.get(k) ?? EMPTY), packLeaf(next.get(k)!)])))
      : "0x";
    const proof = changed.length ? multiproof(levels(dense), changed) : [];
    return { anchorId: anchorId as Hex, fills: fills as Hex, updates: updates as Hex, proof, reqTo: BigInt(reqTo), forcedTo: BigInt(forcedTo), statuses: (statuses as Hex) || "0x", next };
  }

  /**
   * Propose batch `no`. Refuses unless its anchor is known canonical and young enough;
   * `tick()` re-pins a batch that isn't.
   */
  async propose(no: bigint, opts: { tamper?: (news: Map<number, Account>) => void; label?: string } = {}) {
    const b = this.batch(no);
    if (!b || b.state !== "sealed") throw new Error(`batch ${no}: not sealed (or already proposed)`);
    const status = await this.anchorStatus(b);
    if (status !== "canonical") throw new Error(`batch ${no}: anchor ${status}; run tick() first`);
    if ((await this.view.head()) - b.snap.number > this.maxAnchorAge) throw new Error(`batch ${no}: anchor too old; run tick() first`);
    const p0 = b.prepared as Prepared;
    if (!(await this.l1.read<boolean>(this.anchors, "recorded", [p0.l1Witness.anchorId]))) {
      await this.l1.send(this.anchors, "record", [p0.l1Witness.rawHeader], this.op, "AnchorRegistry.record");
    }
    const p = await this.proposal(no, opts.tamper);
    const r = await this.l1.send(this.channel, "propose",
      [p0.l1Witness.package, p.fills, p.updates, p.proof, p.reqTo, p.forcedTo, p.statuses], this.op, opts.label, this.bond);
    this.pendingNext = { no, next: p.next };
    if (!opts.tamper) this.markProposed(no, r.transactionHash, r.blockNumber);
    return { ...p, receipt: r };
  }

  /** After L1 finalizes (anyone can call finalize): the operator's view of the committed state. */
  async finalized() {
    if (!this.pendingNext) return;
    for (const [k, v] of this.pendingNext.next) this.fin.set(k, v);
    this.markFinal(this.pendingNext.no, "finalized");
    this.pendingNext = undefined;
  }

  /** Finalized accounts from L1 alone: every finalized proposal's published leaves, in order. */
  static async recover(l1: Chain, channel: C): Promise<Map<number, Account>> {
    const logs = await l1.pub.getLogs({ address: channel.address, fromBlock: 0n });
    const proposed = new Map<bigint, Hex>(); // batch → tx
    const finalizedBatches: bigint[] = [];
    for (const log of logs) {
      try {
        const ev = decodeEventLog({ abi: channel.abi, data: log.data, topics: log.topics }) as any;
        if (ev.eventName === "Proposed") proposed.set(ev.args.batch, log.transactionHash);
        if (ev.eventName === "Finalized") finalizedBatches.push(ev.args.batch);
      } catch { /* other */ }
    }
    const fin = new Map<number, Account>();
    for (const b of finalizedBatches) {
      const tx = await l1.pub.getTransaction({ hash: proposed.get(b)! });
      const { args } = decodeFunctionData({ abi: channel.abi, data: tx.input }) as any;
      const updates: Hex = args[2];
      const raw = updates.slice(2);
      for (let o = 0; o < raw.length; o += 440) {
        const u = raw.slice(o, o + 440);
        fin.set(Number(BigInt(`0x${u.slice(0, 8)}`)), unpackLeaf(`0x${u.slice(224)}`));
      }
    }
    return fin;
  }

  /** Start this executor's AppState from L1's finalized state. */
  async adopt(fin: Map<number, Account>) {
    const snap = await this.view.snapshot(this.policy);
    const n = Number(await this.view.value(snap, this.channel.address, word(0n)));
    const slots: Hex[] = [word(0n), word(4n), word(5n), word(6n)];
    for (let i = 0; i < n; i++) slots.push(word(arraySlot(0n, BigInt(i), 1n)));
    const w = this.view.witness(snap, [{ account: this.channel.address, slots }]);
    await this.exec.send(this.l1view, "pin", [w.rawHeader, w.package], this.op);
    const idx = [...fin.keys()].filter((k) => leafHash(fin.get(k)!) !== zeroHash).sort((a, b) => a - b);
    await this.exec.send(this.book, "adopt", [w.anchorId, idx, idx.map((k) => fin.get(k)!)], this.op);
    this.fin = new Map(fin);
    this.scannedTo = 0n; // re-scan deposits from the start: applying them again is a no-op
    return rootOf(levels(Array.from({ length: n }, (_, i) => leafHash(fin.get(i) ?? EMPTY))));
  }
}

/** The repository root, for artifacts (the runtime lives in ts/runtime). */
function ROOT_OF(_o: unknown) {
  return new URL("../../", import.meta.url).pathname;
}

// Operator runtime for the clearing channel (ClearingChannel on L1, ClearingBook on the
// executor): docs/guide/stateful-runtime.md.
//
// The executor is crates/app-executor: the channel (both halves) and the Chainlink feed (proxy
// and aggregator) are imported read-only, so ClearingBook reads them with ordinary calls. The
// executor follows L1's head: those reads are always current, and every value is verified at
// the head it was read at.
//
// Per batch: open the batch at the executor's current head (deposits, withdrawal requests and
// forced orders applied first, as L1 replays them) → orders and fills. Each fill runs at the
// executor's head then; a fill at a new head starts an execution segment, and if the feed's
// round changed there, the operator fetches L1's price witness at that block right away →
// seal → propose: the packed fills, the segments (each head recorded on L1, each price
// witnessed), the changed accounts with a multiproof against the finalized root, the queue
// cursors, the forced-order statuses, and a bond. Anyone finalizes after the window. Nothing ever needs an old block:
// a restart adopts the finalized and pending leaves instead of re-executing.
//
// `recover` rebuilds the finalized accounts from L1 alone (published proposals that
// finalized), so another operator can `adopt` them and continue after the takeover delay.
import {
  encodeAbiParameters, encodePacked, keccak256, toHex, zeroHash, decodeEventLog, decodeFunctionData, concat,
  type Abi, type Address, type Hex,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
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
const LOG_RANGE = 1000n;
/** Chainlink storage the adapter verifies: proxy phase (slot 2); aggregator round (0x2b) and answer. */
export const PROXY_PHASE_SLOT = word(2n);
export const AGG_HOT_SLOT = word(0x2bn);
export const transmissionSlot = (round: bigint): Hex => keccak256(encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [round, 0x2cn]));

/**
 * What the journal replays. `raw` is a user's own signed transaction, accepted through the
 * RPC gateway (runtime/gateway.ts); replaying the same bytes keeps nonces continuous.
 */
export type Action =
  | { kind: "order"; order: Order; sig: Hex }
  | { kind: "fill"; a: Hex; b: Hex }
  | { kind: "raw"; tx: Hex };
/** Executor state a batch opens from (plans and recoveries start here). */
export type OpenState = { users: number; reqCursor: number; forcedCursor: number; scannedTo: bigint };
export type Prepared = {
  forced: { orders: Hex[] }; depositUsers: number[];
  requests: number; // withdrawal requests queued on L1 that this batch will serve
  scannedTo: bigint;
  // The head the batch opened at (from openBatch's receipt).
  opened?: Snapshot;
  // The batch's execution segments as they happen: each fill head, its raw header (recorded
  // on L1 at proposal), and L1's price witness where the feed's round changed.
  segments?: Segment[];
  // Set at proposal: the leaves it commits (a restart adopts them while it's pending).
  proposed?: [number, Account][];
};
export type Segment = { number: bigint; hash: Hex; time: bigint; snap: Snapshot; priceBlock: bigint; rawHeader: Hex; witness?: Witness };
/** The Chainlink feed a session prices from: the proxy apps call, and its aggregator. */
export type Feed = { proxy: Address; aggregator: Address };


/** `propose` before oracle segments: one witness instead of witnesses and segment starts. */
const LEGACY_PROPOSE = [{
  type: "function", name: "propose", stateMutability: "payable", outputs: [],
  inputs: ["bytes", "bytes", "bytes", "bytes32[]", "uint64", "uint64", "bytes"].map((type, i) => ({ type, name: `a${i}` })),
}] as const;
/** `propose` with oracle segments as first fills only (174ecfc): witnesses, then firstFills. */
const SEGMENTS_PROPOSE = [{
  type: "function", name: "propose", stateMutability: "payable", outputs: [],
  inputs: ["bytes[]", "uint32[]", "bytes", "bytes", "bytes32[]", "uint64", "uint64", "bytes"].map((type, i) => ({ type, name: `a${i}` })),
}] as const;
/** The `Proposed` event before oracle segments (one price and anchor). */
const LEGACY_PROPOSED = [{
  type: "event", name: "Proposed", anonymous: false,
  inputs: [
    { name: "batch", type: "uint256", indexed: true }, { name: "root", type: "bytes32", indexed: false },
    { name: "proposer", type: "address", indexed: false }, { name: "price", type: "uint256", indexed: false },
    { name: "anchorBlock", type: "uint64", indexed: false }, { name: "reqCursor", type: "uint64", indexed: false },
    { name: "forcedCursor", type: "uint64", indexed: false },
  ],
}] as const;
/** A channel's events, in any layout its session code has used. */
const historyAbi = (channel: C) => [...channel.abi, ...LEGACY_PROPOSED] as any;

/** The packed account updates of a `propose` call, in any layout a session's code has used. */
function proposalUpdates(channel: C, input: Hex): Hex {
  try {
    const { args } = decodeFunctionData({ abi: channel.abi, data: input }) as any;
    return args[3]; // propose(witnesses, segments, fills, updates, …)
  } catch { /* an earlier layout */ }
  try {
    const { args } = decodeFunctionData({ abi: SEGMENTS_PROPOSE, data: input }) as any;
    return args[3]; // propose(witnesses, firstFills, fills, updates, …)
  } catch {
    const { args } = decodeFunctionData({ abi: LEGACY_PROPOSE, data: input }) as any;
    return args[2]; // propose(witness, fills, updates, …)
  }
}

/** A clearing session's code, deployed once per app: sessions are minimal proxies of it. */
export type SessionCode = { channel: C; disputes: C };

export async function deploySessionCode(l1: Chain, from: PrivateKeyAccount): Promise<SessionCode> {
  const disputes = await l1.deploy(ROOT_OF(l1), from, "ClearingDisputes.sol", "ClearingDisputes", [], "session code: ClearingDisputes");
  const channel = await l1.deploy(ROOT_OF(l1), from, "ClearingChannel.sol", "ClearingChannel", [disputes.address], "session code: ClearingChannel");
  return { channel, disputes };
}

/**
 * Open the app's next session: the vault creates a 45-byte proxy of the session code and
 * initializes it with `config` (it sets its own address, its token and the next id).
 * `imports` are the L1 accounts the app executor imports for it: the session, both halves of
 * its code (they run there by delegatecall), and whatever the caller adds (e.g. the feed).
 */
export async function openSession(l1: Chain, owner: PrivateKeyAccount, vault: C, code: SessionCode, config: Record<string, unknown>, label = "open session") {
  const full = { vault: "0x0000000000000000000000000000000000000000", usd: "0x0000000000000000000000000000000000000000", sessionId: 0n, ...config };
  const r = await l1.send(vault, "openSession", [code.channel.address, full], owner, label);
  const ev = r.logs.map((l) => { try { return decodeEventLog({ abi: vault.abi, data: l.data, topics: l.topics }) as any; } catch { return undefined; } })
    .find((e) => e?.eventName === "SessionOpened");
  const address = ev.args.session as Address;
  const channel = mergeAbi({ address, abi: code.channel.abi }, code.disputes);
  return { channel, id: BigInt(ev.args.id), startBlock: r.blockNumber, imports: [address, code.channel.address, code.disputes.address] as Address[] };
}

export function mergeAbi(core: C, half: C): C {
  const names = new Set(core.abi.filter((x: any) => x.type === "function").map((x: any) => x.name));
  return { address: core.address, abi: [...core.abi, ...half.abi.filter((x: any) => x.type !== "function" || !names.has(x.name))] as Abi };
}

export class ClearingOperator extends BatchRuntime<Action, OpenState> {
  book: C; readonly op: PrivateKeyAccount;
  readonly l1: Chain; readonly channel: C; readonly anchors: C; readonly feed: Feed; readonly maxStaleness: bigint;
  readonly evidence: EvidenceStore; readonly bond: bigint;
  fin = new Map<number, Account>(); // finalized leaves (L1's committed state, as this operator knows it)
  /** The pending proposal's new leaves (and its journal batch, if this journal has it). */
  pendingNext?: { b?: JournalBatch<Action, OpenState>; next: Map<number, Account> };
  readonly startBlock: bigint; // the channel's deployment block: no event of it is older
  readonly nextBlock: () => Promise<unknown>;
  scannedTo = 0n; // last L1 block scanned for deposits
  forcedScanFrom = 0n; // where unserved forced orders' events start

  constructor(o: {
    view: L1ReadView; exec: Chain; book: C; op: PrivateKeyAccount; l1: Chain; channel: C; anchors: C;
    feed: Feed; maxStaleness: bigint; evidence: EvidenceStore; policy: Policy; bond: bigint;
    journal: string; maxAnchorAge: bigint; ageMargin: bigint; startBlock?: bigint;
    /** How to get a new L1 block when a proposal must wait for one (tests mine; by default, wait). */
    nextBlock?: () => Promise<unknown>;
  }) {
    super(o.view, o.exec, o.journal, o.policy, o.maxAnchorAge, o.ageMargin);
    this.book = o.book; this.op = o.op; this.l1 = o.l1;
    this.channel = o.channel; this.anchors = o.anchors; this.feed = o.feed; this.maxStaleness = o.maxStaleness;
    this.evidence = o.evidence; this.bond = o.bond;
    this.startBlock = o.startBlock ?? 0n;
    this.nextBlock = o.nextBlock ?? (() => new Promise((r) => setTimeout(r, 1000)));
    this.watched = [o.channel.address, o.feed.proxy, o.feed.aggregator];
  }

  /**
   * Deploy a session's ClearingBook on an app executor (its session id from L1's config).
   * - **One address per session, on every executor:** users' transactions name the book,
   *   and the journal replays them byte for byte (after a restart, or on another operator's
   *   executor).
   * - **Not the operator's own key:** L1 and the app network share one address space, so a
   *   key that has deployed on L1 could CREATE onto an imported account's address here.
   * So the deployer key is derived from the session. It's public, but it only deploys on an
   * operator's own executor (the gateway refuses deployments), with fees 0.
   */
  static async deployBook(exec: Chain, l1: Chain, op: PrivateKeyAccount, channel: C, feed: Feed, maxStaleness: bigint, bandBps = 100n): Promise<C> {
    const { sessionId } = await l1.read<{ sessionId: bigint }>(channel, "config");
    const deployer = privateKeyToAccount(keccak256(encodeAbiParameters(
      [{ type: "string" }, { type: "address" }, { type: "uint64" }], ["skim-clearing/book-deployer", channel.address, sessionId])));
    return exec.deploy(ROOT_OF(exec), deployer, "ClearingBook.sol", "ClearingBook", [channel.address, feed.proxy, maxStaleness, bandBps, op.address, sessionId]);
  }

  /** The channel's events, from no earlier than its deployment, in bounded ranges (nodes cap log queries). */
  private async events(name: string, fromBlock: bigint, toBlock: bigint) {
    const logs = [];
    for (let f = fromBlock < this.startBlock ? this.startBlock : fromBlock; f <= toBlock; f += LOG_RANGE) {
      const t = f + LOG_RANGE - 1n < toBlock ? f + LOG_RANGE - 1n : toBlock;
      logs.push(...(await this.l1.pub.getLogs({ address: this.channel.address, fromBlock: f, toBlock: t })));
    }
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
   * What opening at `snap` needs besides the executor's own reads: the users whose new
   * deposits to apply, the forced orders' data (L1 keeps only their hashes), the block's
   * time, and the price witness L1's ChainlinkAdapter checks at that block. Recoveries merge
   * several batches: their deposit users are included.
   */
  protected async prepare(snap: Snapshot, from: OpenState, forBatches: JournalBatch<Action, OpenState>[]): Promise<Prepared> {
    const ch = this.channel.address;
    const users = new Set<number>();
    for (const b of forBatches) for (const u of (b.prepared as Prepared).depositUsers) users.add(u);
    for (const d of await this.events("Deposited", from.scannedTo + 1n, snap.number)) users.add(Number(d.idx));
    const nForced = Number(await this.view.value(snap, ch, word(3n)));
    const nReq = Number(await this.view.value(snap, ch, word(2n)));
    const forced = { orders: [] as Hex[] };
    if (nForced > from.forcedCursor) {
      // Forced orders are rare; scan from the last block a known one was in.
      const evs = (await this.events("ForcedOrder", this.forcedScanFrom, snap.number)).sort((a, b) => Number(a.pos - b.pos));
      if (evs.length) this.forcedScanFrom = evs[0].block;
      for (let p = from.forcedCursor; p < nForced; p++) {
        const ev = evs.find((e) => Number(e.pos) === p);
        if (!ev) throw new Error(`forced order ${p}: no event`);
        forced.orders.push(ev.order);
      }
    }
    return {
      forced, depositUsers: [...users].sort((a, b) => a - b), requests: Math.max(0, nReq - from.reqCursor), scannedTo: snap.number,
    };
  }

  /** The L1 price witness L1's ChainlinkAdapter checks, at exactly `snap`. */
  private async priceWitness(snap: Snapshot): Promise<Witness> {
    const round = (await this.view.value(snap, this.feed.aggregator, AGG_HOT_SLOT)) >> 176n & 0xffffffffn;
    return this.view.witness(snap, [
      { account: this.feed.proxy, slots: [PROXY_PHASE_SLOT] },
      { account: this.feed.aggregator, slots: [AGG_HOT_SLOT, transmissionSlot(round)] },
    ]);
  }

  protected async openWith(prepared: unknown): Promise<bigint> {
    const p = prepared as Prepared;
    await this.exec.rpc("executor_sync"); // catch up with L1's head now (it follows on its own too)
    const r = await this.exec.send(this.book, "openBatch", [p.depositUsers, p.forced.orders], this.op);
    this.scannedTo = p.scannedTo;
    const raw = await this.exec.rpc<any>("eth_getTransactionReceipt", [r.transactionHash]);
    p.opened = await this.snapAt(BigInt(raw.l1BlockNumber), raw.l1BlockHash);
    p.segments = []; // segments start at fills
    return BigInt(await this.exec.read(this.book, "current"));
  }

  private async snapAt(number: bigint, hash: Hex): Promise<Snapshot> {
    const blk = await this.l1.pub.getBlock({ blockHash: hash });
    return {
      chainId: this.view.chainId, number, hash, parentHash: blk.parentHash, stateRoot: blk.stateRoot,
      policy: this.policy, speculative: this.policy.kind === "latest",
    };
  }

  /**
   * The execution segment a fill started: the L1 head it ran against (from its receipt, checked
   * against the book), the head's raw header (L1 records it at proposal), and, where the feed's
   * round changed (`priceBlock == head`), L1's price witness at that block, fetched right
   * away while it's recent. The executor's evidence at that head is kept too.
   */
  private async segmentAt(tx: Hex, no: bigint, ev: { segment: bigint; head: bigint; priceBlock: bigint }): Promise<Segment> {
    const raw = await this.exec.rpc<any>("eth_getTransactionReceipt", [tx]);
    if (ev.head !== BigInt(raw.l1BlockNumber)) throw new Error(`segment of batch ${no}: book and receipt disagree on the L1 head`);
    const g = (await this.exec.read<any[]>(this.book, "segments", [no]))[Number(ev.segment)];
    if (g.hash !== raw.l1BlockHash) throw new Error(`segment of batch ${no}: book and receipt disagree on the L1 block`);
    const snap = await this.snapAt(ev.head, raw.l1BlockHash);
    const witness = ev.priceBlock === ev.head ? await this.priceWitness(snap) : undefined;
    const rawHeader = witness?.rawHeader ?? this.view.witness(snap, []).rawHeader;
    const evd = await this.exec.rpc<{ package: Hex }>("executor_evidence");
    this.evidence.pin(`clearing:batch:${no}:seg${ev.segment}`, {
      purpose: `clearing batch ${no}`, anchor: { chainId: this.view.chainId, blockNumber: `${ev.head}`, blockHash: raw.l1BlockHash },
      rawHeader, package: evd.package, reads: [], note: witness ? `price witness: ${witness.package}` : `price reused from block ${ev.priceBlock}`,
    });
    return { number: ev.head, hash: raw.l1BlockHash, time: BigInt(g.time), snap, priceBlock: ev.priceBlock, rawHeader, witness };
  }

  protected openedAt(prepared: unknown): Snapshot | undefined {
    return (prepared as Prepared).opened;
  }

  protected heads(b: JournalBatch<Action, OpenState>): Snapshot[] {
    return ((b.prepared as Prepared).segments ?? []).map((s) => s.snap);
  }

  /** L1 reorganized under the open batch (the book refuses to run at another branch's head). */
  protected transient(e: any): boolean {
    return e?.cause?.data?.errorName === "L1Rewound" || /L1Rewound/.test(String(e?.shortMessage ?? e?.message ?? ""));
  }

  protected async run(action: Action) {
    if (action.kind === "order") await this.exec.send(this.book, "submitOrder", [action.order, action.sig], this.op);
    else if (action.kind === "fill") {
      const r = await this.exec.send(this.book, "fill", [action.a, action.b], this.op);
      // A fill at a new L1 head starts a segment: record its head (and witness a new price) now.
      for (const l of r.logs) {
        let ev: any;
        try { ev = decodeEventLog({ abi: this.book.abi, data: l.data, topics: l.topics }); } catch { continue; }
        if (ev.eventName !== "SegmentStarted") continue;
        const p = this.current.prepared as Prepared;
        p.segments = [...(p.segments ?? []), await this.segmentAt(r.transactionHash, BigInt(this.current.no), ev.args)];
      }
    }
    else await this.sendRaw(action.tx);
  }

  /**
   * A user's signed transaction, as is (the executor charges no fee, whatever the wallet
   * signed). Included-but-reverted still counts as applied: it consumed the nonce, so
   * replays must send it again.
   */
  async sendRaw(tx: Hex) {
    const hash = await this.exec.rpc<Hex>("eth_sendRawTransaction", [tx]);
    await this.exec.pub.waitForTransactionReceipt({ hash });
    return hash;
  }

  protected async sealOne() {
    await this.exec.send(this.book, "seal", [], this.op);
  }

  /**
   * The executor lost its state (no checkpoint to return to): deploy a fresh book, adopt L1's
   * finalized accounts, and re-execute every batch that is proposed but not yet final, with
   * the proofs it used. Then the executor is where the first unproposed batch began.
   */
  /**
   * A fresh executor (the old one, or its checkpoints, are gone): deploy the book and adopt
   * L1's committed state. A batch in its challenge window isn't re-executed (that would need
   * its old block); its proposed leaves are adopted, checked against L1's pending root.
   */
  protected async rebuild() {
    // A book already on this executor that nothing has happened in yet is reused (its address is
    // the one wallets were given); otherwise a fresh one is deployed.
    const unused = (await this.exec.pub.getCode({ address: this.book.address }).catch(() => undefined))
      && BigInt(await this.exec.read(this.book, "current").catch(() => 1n)) === 0n
      && (await this.exec.read<Hex>(this.book, "stateDigest").catch(() => "0x1")) === zeroHash;
    if (!unused) this.book = await ClearingOperator.deployBook(this.exec, this.l1, this.op, this.channel, this.feed, this.maxStaleness);
    // The finalized leaves this operator kept (adopt checks them against L1's root), else L1's history.
    const fin = this.fin.size ? new Map(this.fin) : await ClearingOperator.recover(this.l1, this.channel, this.startBlock);
    const pend = await this.l1.read<any>(this.channel, "pending");
    const b = this.batches.findLast((x) => x.state === "proposed");
    if (pend.at !== 0n) {
      // Its leaves: from the journal, else from the proposal's own calldata on L1.
      const kept = (b?.prepared as Prepared | undefined)?.proposed;
      const next = kept ? new Map(kept) : await ClearingOperator.pendingLeaves(this.l1, this.channel, this.startBlock);
      const merged = new Map(fin);
      for (const [k, v] of next) merged.set(k, v);
      await this.adopt(merged, true);
      this.fin = fin;
      this.pendingNext = { b, next }; // also when the leaves came from L1: they become final
    } else {
      await this.adopt(fin);
    }
    for (const x of this.batches) x.checkpoint = undefined;
  }

  /**
   * Continue after the executor (or the whole process) was restarted: rebuild AppState on the
   * fresh executor from L1's finalized state plus the journal, then carry on from the first
   * batch not yet proposed.
   */
  async restart() {
    const b = this.batches.find((x) => x.state === "open" || x.state === "sealed");
    if (b) return this.recover(b.no, "restarted");
    await this.rebuild();
    this.save();
  }

  // ---- proposals -----------------------------------------------------------------------------

  /** The proposal for batch `no`, against the finalized state this operator knows. */
  async proposal(no: bigint, tamper?: (news: Map<number, Account>) => void) {
    const [segments, fills, idx, olds, news, reqTo, forcedTo, statuses] = await this.exec.read<any[]>(this.book, "proposal", [no]);
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
    return {
      segments: (segments as any[]).map((g) => ({
        head: BigInt(g.head), hash: g.hash as Hex, priceBlock: BigInt(g.priceBlock), firstFill: Number(g.firstFill), price: BigInt(g.price),
      })),
      fills: fills as Hex, updates: updates as Hex, proof, reqTo: BigInt(reqTo), forcedTo: BigInt(forcedTo), statuses: (statuses as Hex) || "0x", next };
  }

  /**
   * Propose batch `no`. Refuses unless every block it executed against (its opening head
   * and every segment's head) is known canonical and young enough; `tick()` recovers a batch
   * that isn't.
   */
  async propose(no: bigint, opts: { tamper?: (news: Map<number, Account>) => void; label?: string } = {}) {
    const b = this.batch(no);
    if (!b || b.state !== "sealed") throw new Error(`batch ${no}: not sealed (or already proposed)`);
    const status = await this.anchorStatus(b);
    if (status !== "canonical") throw new Error(`batch ${no}: an L1 block it executed against is ${status}; run tick() first`);
    if ((await this.view.head()) - this.oldest(b) > this.maxAnchorAge) throw new Error(`batch ${no}: anchor too old; run tick() first`);
    const segs = (b.prepared as Prepared).segments ?? [];
    const p = await this.proposal(no, opts.tamper);
    if (segs.length !== p.segments.length || segs.some((s, i) => s.number !== p.segments[i].head || s.hash !== p.segments[i].hash || s.priceBlock !== p.segments[i].priceBlock)) {
      throw new Error(`batch ${no}: the journal's segments don't match the book's`);
    }
    // L1 records a block only once a later block exists (BLOCKHASH covers past blocks).
    for (let i = 0; segs.length && (await this.l1.height()) <= segs[segs.length - 1].number; i++) {
      if (i > 120) throw new Error(`batch ${no}: L1 hasn't moved past its last segment's head`);
      await this.nextBlock();
    }
    for (const s of segs) {
      if ((await this.l1.read<Hex>(this.anchors, "anchorIdAt", [s.number])) === zeroHash) {
        await this.l1.send(this.anchors, "record", [s.rawHeader], this.op, "AnchorRegistry.record");
      }
    }
    // One witness per new price, in order; each segment names the witness it was priced by.
    const witnesses: Hex[] = [];
    const refs = segs.map((s, i) => {
      if (s.witness) witnesses.push(s.witness.package);
      else if (i === 0) throw new Error(`batch ${no}: its first segment has no price witness`);
      return { firstFill: p.segments[i].firstFill, price: witnesses.length - 1, head: s.number };
    });
    const r = await this.l1.send(this.channel, "propose",
      [witnesses, refs, p.fills, p.updates, p.proof, p.reqTo, p.forcedTo, p.statuses],
      this.op, opts.label, this.bond);
    if (!opts.tamper) {
      (b.prepared as Prepared).proposed = [...p.next];
      this.markProposed(no, r.transactionHash, r.blockNumber);
    }
    this.pendingNext = { b, next: p.next };
    return { ...p, receipt: r };
  }

  /**
   * After L1 finalizes (anyone can call finalize): the operator's view of the committed state.
   * Checked against L1's finalized root; if the proposal was discarded instead (or anything
   * else differs), the finalized leaves are taken from L1's history.
   */
  async finalized() {
    if (!this.pendingNext) return;
    const fin = new Map(this.fin);
    for (const [k, v] of this.pendingNext.next) fin.set(k, v);
    const [root] = await this.l1.read<any[]>(this.channel, "state");
    const n = Number(await this.l1.read(this.channel, "userCount"));
    const mine = rootOf(levels(Array.from({ length: n }, (_, i) => leafHash(fin.get(i) ?? EMPTY))));
    if (mine === root) {
      this.fin = fin;
      if (this.pendingNext.b) this.pendingNext.b.state = "finalized";
    } else {
      this.fin = await ClearingOperator.recover(this.l1, this.channel, this.startBlock);
      if (this.pendingNext.b) this.pendingNext.b.state = "discarded";
    }
    this.save();
    this.pendingNext = undefined;
  }

  /** The pending proposal's new leaves, from its calldata on L1 (the latest Proposed event). */
  static async pendingLeaves(l1: Chain, channel: C, fromBlock = 0n): Promise<Map<number, Account>> {
    const head = await l1.height();
    let tx: Hex | undefined;
    for (let f = fromBlock; f <= head; f += LOG_RANGE) {
      for (const log of await l1.pub.getLogs({ address: channel.address, fromBlock: f, toBlock: f + LOG_RANGE - 1n < head ? f + LOG_RANGE - 1n : head })) {
        try {
          const ev = decodeEventLog({ abi: historyAbi(channel), data: log.data, topics: log.topics }) as any;
          if (ev.eventName === "Proposed") tx = log.transactionHash;
        } catch { /* other */ }
      }
    }
    const out = new Map<number, Account>();
    if (!tx) return out;
    const t = await l1.pub.getTransaction({ hash: tx });
    const raw = proposalUpdates(channel, t.input).slice(2);
    for (let o = 0; o < raw.length; o += 440) {
      const u = raw.slice(o, o + 440);
      out.set(Number(BigInt(`0x${u.slice(0, 8)}`)), unpackLeaf(`0x${u.slice(224)}`));
    }
    return out;
  }

  /** Finalized accounts from L1 alone: every finalized proposal's published leaves, in order. */
  static async recover(l1: Chain, channel: C, fromBlock = 0n): Promise<Map<number, Account>> {
    const head = await l1.height();
    const logs = [];
    for (let f = fromBlock; f <= head; f += LOG_RANGE) {
      logs.push(...(await l1.pub.getLogs({ address: channel.address, fromBlock: f, toBlock: f + LOG_RANGE - 1n < head ? f + LOG_RANGE - 1n : head })));
    }
    const proposed = new Map<bigint, Hex>(); // batch → tx
    const finalizedBatches: bigint[] = [];
    for (const log of logs) {
      try {
        const ev = decodeEventLog({ abi: historyAbi(channel), data: log.data, topics: log.topics }) as any;
        if (ev.eventName === "Proposed") proposed.set(ev.args.batch, log.transactionHash);
        if (ev.eventName === "Finalized") finalizedBatches.push(ev.args.batch);
      } catch { /* other */ }
    }
    const fin = new Map<number, Account>();
    for (const b of finalizedBatches) {
      const tx = await l1.pub.getTransaction({ hash: proposed.get(b)! });
      const updates = proposalUpdates(channel, tx.input);
      const raw = updates.slice(2);
      for (let o = 0; o < raw.length; o += 440) {
        const u = raw.slice(o, o + 440);
        fin.set(Number(BigInt(`0x${u.slice(0, 8)}`)), unpackLeaf(`0x${u.slice(224)}`));
      }
    }
    return fin;
  }

  /** Start this executor's AppState from L1's finalized state (checked against L1's root). */
  async adopt(fin: Map<number, Account>, pending = false) {
    await this.exec.rpc("executor_sync").catch(() => undefined); // catch up with L1's head first
    const n = Number(await this.l1.read(this.channel, "userCount"));
    const idx = [...fin.keys()].filter((k) => leafHash(fin.get(k)!) !== zeroHash).sort((a, b) => a - b);
    await this.exec.send(this.book, "adopt", [idx, idx.map((k) => fin.get(k)!), pending], this.op);
    this.fin = new Map(fin);
    this.scannedTo = 0n; // re-scan deposits from the start: applying them again is a no-op
    return rootOf(levels(Array.from({ length: n }, (_, i) => leafHash(fin.get(i) ?? EMPTY))));
  }
}

/** The repository root, for artifacts (the runtime lives in ts/runtime). */
function ROOT_OF(_o: unknown) {
  return new URL("../../", import.meta.url).pathname;
}

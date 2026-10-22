// The clearing operator's runtime: skim (L1ReadView) → AppState (ClearingApp, Solidity on the
// local executor) → L1Settlement (ClearingSettlement).
//
// Per batch:
//   open   — take ONE L1 snapshot under the confirmation policy; fetch proofs for exactly the
//            slots the app may read (price; settlement's finalizedBatches; each trader's
//            account words); pin them on the executor's L1View; checkpoint the executor; open
//            the batch on that anchor. The witness is also pinned in the evidence store until
//            L1 finalizes the batch.
//   act    — relay orders and fills to ClearingApp. Every action is logged with its outcome.
//   seal   — close the batch; AppState carries on into the next one.
//   check  — before proposing: the snapshot must still be canonical, and L1 must accept the
//            batch as of now. If not, `rebase`: roll the executor back to the batch's
//            checkpoint, take a new snapshot, and replay the logged actions; actions that no
//            longer hold are dropped (and reported), never forced.
//   propose— record the anchor on L1 if needed and submit the fills (both signed orders each)
//            with the witness. L1 re-checks every fill; only signatures stay challengeable.
import { encodeAbiParameters, keccak256, decodeEventLog, type Address, type Hex } from "viem";
import type { PrivateKeyAccount } from "viem/accounts";
import { L1ReadView, mappingSlot, type Policy, type Snapshot, type Witness, type Read } from "./l1view.ts";
import { Chain, type C } from "./executor.ts";
import { EvidenceStore } from "./evidence.ts";

export type Order = { trader: Address; sellToken: number; sellAmount: bigint; buyAmount: bigint; nonce: bigint; expiry: bigint };
export type Action = { kind: "order"; order: Order; sig: Hex } | { kind: "fill"; a: Hex; b: Hex };
export type Outcome = { action: Action; ok: boolean; error?: string };

export type Batch = {
  no: bigint;
  snap: Snapshot;
  witness: Witness; // everything the app reads (price, finalizedBatches, accounts)
  l1Witness: Witness; // the price slot only, at the same block: what L1 settlement checks
  checkpoint: Hex;
  log: Outcome[];
  traders: Address[];
  sealed: boolean;
};

export const orderT = {
  type: "tuple",
  components: [
    { name: "trader", type: "address" }, { name: "sellToken", type: "uint8" },
    { name: "sellAmount", type: "uint128" }, { name: "buyAmount", type: "uint128" },
    { name: "nonce", type: "uint64" }, { name: "expiry", type: "uint64" },
  ],
} as const;
export const fillT = {
  type: "tuple[]",
  components: [
    { name: "a", ...orderT }, { name: "b", ...orderT }, { name: "sigA", type: "bytes" }, { name: "sigB", type: "bytes" },
  ],
} as const;

export const orderHash = (o: Order) => keccak256(encodeAbiParameters([orderT], [o as any]));

export const eip712Order = {
  Order: [
    { name: "trader", type: "address" }, { name: "sellToken", type: "uint8" }, { name: "sellAmount", type: "uint128" },
    { name: "buyAmount", type: "uint128" }, { name: "nonce", type: "uint64" }, { name: "expiry", type: "uint64" },
  ],
};

function why(e: any): string {
  return e?.cause?.data?.errorName ?? e?.cause?.reason ?? e?.shortMessage ?? String(e);
}

export class ClearingOperator {
  readonly view: L1ReadView;
  readonly exec: Chain;
  readonly app: C;
  readonly l1view: C;
  readonly op: PrivateKeyAccount;
  readonly settlement: Address;
  readonly priceFeed: Address;
  readonly priceSlot: Hex;
  readonly evidence: EvidenceStore;
  policy: Policy;
  batches: Batch[] = [];

  constructor(o: {
    view: L1ReadView; exec: Chain; app: C; l1view: C; op: PrivateKeyAccount; settlement: Address;
    priceFeed: Address; priceSlot: Hex; evidence: EvidenceStore; policy: Policy;
  }) {
    this.view = o.view; this.exec = o.exec; this.app = o.app; this.l1view = o.l1view; this.op = o.op;
    this.settlement = o.settlement; this.priceFeed = o.priceFeed; this.priceSlot = o.priceSlot;
    this.evidence = o.evidence; this.policy = o.policy;
  }

  get current(): Batch {
    return this.batches[this.batches.length - 1];
  }

  async reads(traders: Address[]): Promise<Read[]> {
    const slots: Hex[] = [`0x${"0".repeat(64)}`]; // finalizedBatches
    for (const t of traders) slots.push(await mappingSlot(t, 1n), await mappingSlot(t, 1n, 1n));
    return [{ account: this.priceFeed, slots: [this.priceSlot] }, { account: this.settlement, slots }];
  }

  /** Pin a snapshot on the executor and open the next batch on it. */
  async open(traders: Address[], snap?: Snapshot, witness?: Witness): Promise<Batch> {
    snap ??= await this.view.snapshot(this.policy);
    witness ??= this.view.witness(snap, await this.reads(traders));
    // Fetched now, while the block is recent: L1 settlement needs only the price.
    const l1Witness = this.view.witness(snap, [{ account: this.priceFeed, slots: [this.priceSlot] }]);
    const checkpoint = await this.exec.checkpoint();
    await this.exec.send(this.l1view, "pin", [witness.rawHeader, witness.package], this.op, "executor: L1View.pin");
    await this.exec.send(this.app, "openBatch", [witness.anchorId], this.op);
    const no = BigInt(await this.exec.read(this.app, "currentBatch"));
    this.evidence.pin(`clearing:batch:${no}`, {
      purpose: `clearing batch ${no} L1 reads`, anchor: { chainId: snap.chainId, blockNumber: `${snap.number}`, blockHash: snap.hash, stateRoot: snap.stateRoot },
      rawHeader: witness.rawHeader, package: witness.package, reads: [],
      note: `kept until L1 finalizes the batch; l1Witness: ${l1Witness.package}`,
    });
    const b: Batch = { no, snap, witness, l1Witness, checkpoint, log: [], traders, sealed: false };
    this.batches.push(b);
    return b;
  }

  async apply(action: Action): Promise<Outcome> {
    let out: Outcome;
    try {
      if (action.kind === "order") await this.exec.send(this.app, "submitOrder", [action.order, action.sig], this.op);
      else await this.exec.send(this.app, "fill", [action.a, action.b], this.op);
      out = { action, ok: true };
    } catch (e) {
      out = { action, ok: false, error: why(e) };
    }
    this.current.log.push(out);
    return out;
  }

  async seal() {
    await this.exec.send(this.app, "sealBatch", [], this.op);
    this.current.sealed = true;
  }

  /**
   * Roll the latest batch back to its checkpoint and replay its log on a new snapshot.
   * Only the latest, unproposed batch can be rebased.
   */
  async rebase(snap?: Snapshot): Promise<{ dropped: Outcome[]; replayed: Outcome[] }> {
    const old = this.batches.pop()!;
    await this.exec.rollback(old.checkpoint);
    const nb = await this.open(old.traders, snap);
    const replayed: Outcome[] = [];
    for (const o of old.log) replayed.push(await this.apply(o.action));
    if (old.sealed) await this.seal();
    const dropped = replayed.filter((r, i) => !r.ok && old.log[i].ok);
    void nb;
    return { dropped, replayed };
  }

  async fills(no: bigint) {
    return this.exec.read<any[]>(this.app, "fills", [no]);
  }

  /** Sorted traders of a batch, as L1 wants them. */
  async traders(no: bigint): Promise<Address[]> {
    const t = await this.exec.read<Address[]>(this.app, "traders", [no]);
    return [...t].sort((x, y) => (BigInt(x) < BigInt(y) ? -1 : 1));
  }

  async proposal(no: bigint) {
    const fills = await this.fills(no);
    const users = await this.traders(no);
    const at: number[] = [];
    for (const f of fills) at.push(users.indexOf(f.a.trader), users.indexOf(f.b.trader));
    return { fills: encodeAbiParameters([fillT], [fills as any]), users, at };
  }
}

/** The arguments `finalize` needs, from the BatchProposed event (anyone can do this). */
export async function finalizeArgs(l1: Chain, settlement: C, txHash: Hex) {
  const r = await l1.pub.getTransactionReceipt({ hash: txHash });
  for (const log of r.logs) {
    try {
      const ev = decodeEventLog({ abi: settlement.abi, data: log.data, topics: log.topics }) as any;
      if (ev.eventName === "BatchProposed") return [ev.args.users, ev.args.dEth, ev.args.dUsd, ev.args.nonces];
    } catch { /* other events */ }
  }
  throw new Error("no BatchProposed in receipt");
}

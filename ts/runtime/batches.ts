// Batch lifecycle and recovery for the clearing runtime (clearing.ts). Review of 5db7064
// (docs/experiments/clearing.md):
// - every batch has a state (open → sealed → proposed → finalized, or discarded) and the
//   L1 transaction and block that proposed it, in a journal written atomically to disk;
// - recovery starts at the EARLIEST affected batch and replays every later unproposed batch
//   too (a later batch may spend what an earlier one produced);
// - the new snapshot and its proofs are obtained BEFORE anything is rolled back; if that
//   fails, nothing changes;
// - only accepted actions are replayed; rejected ones are reported, never silently retried;
// - a block the node doesn't know is "unknown", not "orphaned": proposing pauses and
//   nothing is replayed.
import { writeFileSync, readFileSync, renameSync, existsSync } from "node:fs";
import type { Hex } from "viem";
import type { L1ReadView, Policy, Snapshot } from "./l1view.ts";
import type { Chain } from "./executor.ts";

export type BatchState = "open" | "sealed" | "proposed" | "finalized" | "discarded";

export type Logged<A> = { action: A; ok: boolean; error?: string };

export type JournalBatch<A, O> = {
  no: string; // the executor's batch number
  state: BatchState;
  snap: Snapshot;
  openState: O; // executor state at open, so a recovery can plan from that point
  prepared: unknown; // what was used to open (witnesses, relayed data)
  log: Logged<A>[];
  checkpoint?: Hex; // executor checkpoint taken just before the batch opened (volatile)
  proposal?: { tx: Hex; block: string };
};

export type Journal<A, O> = {
  batches: JournalBatch<A, O>[];
  recovering?: { from: string; reason: string; snap: Snapshot; prepared: unknown };
};

export type RecoveryReport<A> = {
  status: "recovered" | "nothing" | "unknown" | "proof-unavailable";
  from?: string;
  reason?: string;
  replayed: Logged<A>[];
  dropped: Logged<A>[]; // accepted before, refused now
  notRetried: Logged<A>[]; // rejected before: reported, not replayed
};

export type AnchorStatus = "canonical" | "orphaned" | "unknown";

const big = (_k: string, v: unknown) => (typeof v === "bigint" ? { $big: v.toString() } : v);
const unbig = (_k: string, v: any) => (v && typeof v === "object" && "$big" in v ? BigInt(v.$big) : v);

/**
 * The lifecycle engine. Subclasses supply the executor-specific steps; everything about
 * ordering, journaling and recovery lives here.
 */
export abstract class BatchRuntime<A, O> {
  journal: Journal<A, O> = { batches: [] };
  paused = false; // set while an anchor's status is unknown
  watched: Hex[] = []; // L1 contracts the app reads (for skim's block stream)

  readonly view: L1ReadView;
  exec: Chain;
  readonly journalPath: string;
  policy: Policy;
  readonly maxAnchorAge: bigint;
  readonly ageMargin: bigint;

  constructor(view: L1ReadView, exec: Chain, journalPath: string, policy: Policy, maxAnchorAge: bigint, ageMargin: bigint) {
    this.view = view;
    this.exec = exec;
    this.journalPath = journalPath;
    this.policy = policy;
    this.maxAnchorAge = maxAnchorAge;
    this.ageMargin = ageMargin;
    if (existsSync(journalPath)) this.journal = JSON.parse(readFileSync(journalPath, "utf8"), unbig);
  }

  // ---- what an executor-specific runtime provides ------------------------------------------

  /** The executor state a batch opens from (cursors, counts). Read-only. */
  protected abstract openState(): Promise<O>;
  /** Fetch everything needed to open a batch at `snap` from `from`. Must not touch the executor. */
  protected abstract prepare(snap: Snapshot, from: O, forBatches: JournalBatch<A, O>[]): Promise<unknown>;
  /** Pin and open; returns the executor's batch number. */
  protected abstract openWith(prepared: unknown): Promise<bigint>;
  /** The L1 block a batch actually opened at, when the executor follows L1's head itself. */
  protected openedAt(_prepared: unknown): Snapshot | undefined {
    return undefined;
  }
  protected abstract run(action: A): Promise<void>;
  protected abstract sealOne(): Promise<void>;
  /** Rebuild the executor when its checkpoint is gone (e.g. it restarted). */
  protected abstract rebuild(): Promise<void>;

  // ---- journal ---------------------------------------------------------------------------

  save() {
    const tmp = `${this.journalPath}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.journal, big, 2));
    renameSync(tmp, this.journalPath);
  }

  get batches() {
    return this.journal.batches;
  }

  get current(): JournalBatch<A, O> {
    return this.batches[this.batches.length - 1];
  }

  /** The latest batch with this executor number (a rebuilt executor numbers from 1 again). */
  batch(no: bigint) {
    return this.batches.findLast((b) => b.no === `${no}`);
  }

  // ---- normal path -------------------------------------------------------------------------

  async open(snap?: Snapshot): Promise<JournalBatch<A, O>> {
    snap ??= await this.view.snapshot(this.policy);
    const from = await this.openState();
    const prepared = await this.prepare(snap, from, []);
    const checkpoint = await this.exec.checkpoint();
    const no = await this.openWith(prepared);
    const b: JournalBatch<A, O> = { no: `${no}`, state: "open", snap: this.openedAt(prepared) ?? snap, openState: from, prepared, log: [], checkpoint };
    this.batches.push(b);
    this.save();
    return b;
  }

  async apply(action: A): Promise<Logged<A>> {
    let out: Logged<A>;
    try {
      await this.run(action);
      out = { action, ok: true };
    } catch (e: any) {
      out = { action, ok: false, error: e?.cause?.data?.errorName ?? e?.cause?.reason ?? e?.shortMessage ?? String(e) };
    }
    this.current.log.push(out);
    this.save();
    return out;
  }

  async seal() {
    await this.sealOne();
    this.current.state = "sealed";
    this.save();
  }

  markProposed(no: bigint, tx: Hex, block: bigint) {
    const b = this.batch(no)!;
    b.state = "proposed";
    b.proposal = { tx, block: `${block}` };
    this.save();
  }

  markFinal(no: bigint, state: "finalized" | "discarded") {
    this.batch(no)!.state = state;
    this.save();
  }

  // ---- watching ----------------------------------------------------------------------------

  /** skim's stream says so first (an explicit rewind); otherwise the node's block at that height. */
  async anchorStatus(b: JournalBatch<A, O>): Promise<AnchorStatus> {
    if (this.watched.length && (await this.view.skimRewound(b.snap, this.watched)) === "rewound") return "orphaned";
    return this.view.canonicalStatus(b.snap);
  }

  /**
   * One pass: find the earliest unproposed batch whose anchor left the chain, or will be too
   * old to propose (block-based maxAnchorAge, minus a margin), and recover from it. An
   * unknown status pauses proposing and changes nothing.
   */
  async tick(): Promise<RecoveryReport<A>> {
    const head = await this.view.head();
    this.paused = false;
    for (const b of this.batches) {
      if (b.state !== "open" && b.state !== "sealed") continue;
      const s = await this.anchorStatus(b);
      if (s === "unknown") {
        this.paused = true;
        return { status: "unknown", from: b.no, reason: "anchor status unknown", replayed: [], dropped: [], notRetried: [] };
      }
      if (s === "orphaned") return this.recover(b.no, "orphaned");
      if (head - b.snap.number > this.maxAnchorAge - this.ageMargin) return this.recover(b.no, "aged");
    }
    return { status: "nothing", replayed: [], dropped: [], notRetried: [] };
  }

  // ---- recovery ------------------------------------------------------------------------------

  /**
   * Recover from batch `from` (unproposed) and every later unproposed batch: one new snapshot,
   * proofs first, then roll back and replay their accepted actions into one batch on it.
   */
  async recover(from: string, reason: string, snap?: Snapshot): Promise<RecoveryReport<A>> {
    const i = this.batches.findLastIndex((b) => b.no === from);
    if (i < 0) throw new Error(`no batch ${from}`);
    const affected = this.batches.slice(i);
    if (affected.some((b) => b.state !== "open" && b.state !== "sealed")) {
      throw new Error(`batch ${from}: a later batch is already proposed; resolve it on L1 first`);
    }
    // 1. Proofs first. Nothing has changed yet if this fails.
    let prepared: unknown;
    try {
      snap ??= await this.view.snapshot(this.policy);
      if ((await this.view.canonicalStatus(snap)) !== "canonical") {
        return { status: "unknown", from, reason: "new snapshot not confirmed", replayed: [], dropped: [], notRetried: [] };
      }
      prepared = await this.prepare(snap, affected[0].openState, affected);
    } catch (e) {
      return { status: "proof-unavailable", from, reason: String((e as Error).message), replayed: [], dropped: [], notRetried: [] };
    }
    // 2. Record the intent, so a crash from here on resumes instead of losing the batches.
    this.journal.recovering = { from, reason, snap, prepared };
    this.save();
    return this.resume();
  }

  /** Finish a recorded recovery (also at startup, if the journal has one). */
  async resume(): Promise<RecoveryReport<A>> {
    const r = this.journal.recovering;
    if (!r) return { status: "nothing", replayed: [], dropped: [], notRetried: [] };
    const i = this.batches.findLastIndex((b) => b.no === r.from);
    const affected = this.batches.slice(i);
    // 3. Roll the executor back to just before the first affected batch.
    const cp = affected[0].checkpoint;
    if (!cp || !(await this.exec.rpc<boolean>("evm_revert", [cp]).catch(() => false))) {
      await this.rebuild();
      // rebuild() re-executes everything up to (not including) the first affected batch
    }
    const from = affected[0].openState;
    // 4. Replay their accepted actions, in order, into one batch on the new snapshot.
    const checkpoint = await this.exec.checkpoint();
    const no = await this.openWith(r.prepared);
    const merged: JournalBatch<A, O> = { no: `${no}`, state: "open", snap: this.openedAt(r.prepared) ?? r.snap, openState: from, prepared: r.prepared, log: [], checkpoint };
    this.journal.batches = [...this.batches.slice(0, i), merged];
    const accepted = affected.flatMap((b) => b.log.filter((l) => l.ok));
    const notRetried = affected.flatMap((b) => b.log.filter((l) => !l.ok));
    const replayed: Logged<A>[] = [];
    for (const l of accepted) replayed.push(await this.apply(l.action));
    if (affected.some((b) => b.state === "sealed")) await this.seal();
    this.journal.recovering = undefined;
    this.save();
    return { status: "recovered", from: r.from, reason: r.reason, replayed, dropped: replayed.filter((x) => !x.ok), notRetried };
  }
}

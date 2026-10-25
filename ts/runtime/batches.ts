// Batch lifecycle and recovery for the clearing runtime (clearing.ts). Review of 5db7064
// (docs/experiments/clearing.md):
// - every batch has a state (open → sealed → proposed → finalized, or discarded) and the
//   L1 transaction and block that proposed it, in a journal written atomically to disk;
// - recovery starts at the EARLIEST affected batch and replays every later unproposed batch
//   too (a later batch may spend what an earlier one produced);
// - every L1 block a batch executed against is watched (its opening head and every
//   execution segment's head), and the earliest batch with an orphaned one is recovered:
//   from the orphaned segment's checkpoint inside that batch when there is one (what ran
//   before it, against canonical blocks, is kept), otherwise from the whole batch;
// - the new snapshot and its proofs are obtained BEFORE anything is rolled back; if that
//   fails, nothing changes;
// - the original batches stay in the journal, untouched, until a recovery completes: the
//   replay is built apart (`recovering.merged`) and swapped in with one save, so a crash
//   mid-replay resumes from the full original log;
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
  /**
   * A recovery in progress. The affected batches (from `from` on) stay in `batches`
   * unchanged until it completes; `merged` is the replay being built (discarded and rebuilt
   * if the process stops before it's swapped in).
   */
  recovering?: {
    from: string; reason: string; snap: Snapshot; prepared: unknown; merged?: JournalBatch<A, O>;
    /** Recovery inside batch `from`: back to this executor checkpoint, keeping its log before `logIndex`. */
    within?: { checkpoint: Hex; logIndex: number; segment: number };
  };
};

export type RecoveryReport<A> = {
  status: "recovered" | "nothing" | "unknown" | "proof-unavailable";
  from?: string;
  reason?: string;
  segment?: number; // set when the recovery started inside batch `from`, at this segment
  replayed: Logged<A>[];
  dropped: Logged<A>[]; // accepted before, refused now
  notRetried: Logged<A>[]; // rejected before: reported, not replayed
};

export type AnchorStatus = "canonical" | "orphaned" | "unknown";

const big = (_k: string, v: unknown) => (typeof v === "bigint" ? { $big: v.toString() } : v);
const unbig = (_k: string, v: any) => (v && typeof v === "object" && "$big" in v ? BigInt(v.$big) : v);
const copy = <T>(x: T): T => JSON.parse(JSON.stringify(x, big), unbig);

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
  /** Every L1 block batch `b` executed against after it opened (its execution segments). */
  protected heads(_b: JournalBatch<A, O>): Snapshot[] {
    return this.segmentPoints(_b).map((p) => p.snap);
  }
  /**
   * Batch `b`'s execution segments in order: each head, and where one was taken, the executor
   * checkpoint just before the action that started it and that action's index in the log.
   */
  protected segmentPoints(_b: JournalBatch<A, O>): { snap: Snapshot; checkpoint?: Hex; logIndex?: number }[] {
    return [];
  }
  /**
   * After the executor returned to a checkpoint inside a batch: bring its L1 view to the
   * current head (a checkpoint holds the head it was taken at, possibly the orphaned block).
   */
  protected async afterRollback(): Promise<void> {}
  /** `prepared` as it was before segment `i` started (a recovery inside the batch keeps it). */
  protected preparedBefore(prepared: unknown, _i: number): unknown {
    return prepared;
  }
  /**
   * An action that failed for a reason outside it (e.g. L1 reorganized under the batch): not
   * logged as rejected; the error propagates and recovery replays the action later.
   */
  protected transient(_e: unknown): boolean {
    return false;
  }
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

  /** The batch actions go into: during a recovery, the replay being built. */
  get current(): JournalBatch<A, O> {
    return this.journal.recovering?.merged ?? this.batches[this.batches.length - 1];
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
      if (this.transient(e)) throw e;
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
  async snapStatus(snap: Snapshot): Promise<AnchorStatus> {
    if (this.watched.length && (await this.view.skimRewound(snap, this.watched)) === "rewound") return "orphaned";
    return this.view.canonicalStatus(snap);
  }

  /**
   * Every block batch `b` executed against: its opening head and each segment's head.
   * Orphaned if any left the chain; unknown if none did but one can't be confirmed. A head
   * that merely moved on is not a change: only a different block at a recorded height is.
   */
  async anchorStatus(b: JournalBatch<A, O>): Promise<AnchorStatus> {
    let unknown = false;
    for (const s of [b.snap, ...this.heads(b)]) {
      const st = await this.snapStatus(s);
      if (st === "orphaned") return st;
      if (st === "unknown") unknown = true;
    }
    return unknown ? "unknown" : "canonical";
  }

  /** The oldest block batch `b` executed against. */
  oldest(b: JournalBatch<A, O>): bigint {
    return [b.snap, ...this.heads(b)].reduce((m, s) => (s.number < m ? s.number : m), b.snap.number);
  }

  /**
   * One pass: find the earliest unproposed batch that executed against a block that left
   * the chain (its opening head or any segment's head), or that will be too old to propose
   * (block-based maxAnchorAge, minus a margin), and recover from it. The recovery replays
   * that batch and every later one, so nothing that depended on the orphaned block survives.
   * An unknown status pauses proposing and changes nothing.
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
      if (s === "orphaned") {
        // The earliest orphaned segment, if the batch's opening block is still canonical and
        // that segment has a checkpoint: recover from there inside the batch.
        if ((await this.snapStatus(b.snap)) === "canonical") {
          const pts = this.segmentPoints(b);
          for (let i = 0; i < pts.length; i++) {
            if ((await this.snapStatus(pts[i].snap)) !== "orphaned") continue;
            const p = pts[i];
            if (p.checkpoint && p.logIndex !== undefined) return this.recoverWithin(b.no, i, p.checkpoint, p.logIndex);
            break;
          }
        }
        return this.recover(b.no, "orphaned");
      }
      if (head - this.oldest(b) > this.maxAnchorAge - this.ageMargin) return this.recover(b.no, "aged");
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
    this.journal.recovering = { from, reason, snap, prepared: copy(prepared) };
    this.save();
    return this.resume();
  }

  /**
   * Recover from segment `seg` of batch `from`: return the executor to the checkpoint taken just
   * before that segment started, keep the batch's log before it, and replay the rest (and
   * every later unproposed batch) at the executor's head now. The batch keeps its number,
   * opening and earlier segments. No new proofs are needed up front: nothing at an old block
   * is read again.
   */
  async recoverWithin(from: string, seg: number, checkpoint: Hex, logIndex: number): Promise<RecoveryReport<A>> {
    const i = this.batches.findLastIndex((b) => b.no === from);
    const b = this.batches[i];
    if (this.batches.slice(i).some((x) => x.state !== "open" && x.state !== "sealed")) {
      throw new Error(`batch ${from}: a later batch is already proposed; resolve it on L1 first`);
    }
    this.journal.recovering = {
      from, reason: "orphaned", snap: b.snap, prepared: copy(this.preparedBefore(b.prepared, seg)), within: { checkpoint, logIndex, segment: seg },
    };
    this.save();
    return this.resume();
  }

  /**
   * Finish a recorded recovery (also at startup, if the journal has one). The affected
   * batches are read, never modified, until the final swap; a replay a crash interrupted is
   * discarded and redone from them.
   */
  async resume(): Promise<RecoveryReport<A>> {
    const r = this.journal.recovering;
    if (!r) return { status: "nothing", replayed: [], dropped: [], notRetried: [] };
    r.merged = undefined;
    const i = this.batches.findLastIndex((b) => b.no === r.from);
    if (i < 0) throw new Error(`recovery from ${r.from}: the batch isn't in the journal`);
    const affected = this.batches.slice(i);
    if (r.within) {
      // Inside the batch: back to the segment's checkpoint. If it's gone (the executor
      // restarted, or an earlier revert dropped it), recover the whole batch instead.
      if (!(await this.exec.rpc<boolean>("evm_revert", [r.within.checkpoint]).catch(() => false))) {
        this.journal.recovering = undefined;
        this.save();
        return this.recover(r.from, r.reason);
      }
      await this.afterRollback();
      const b = affected[0];
      const kept = b.log.slice(0, r.within.logIndex);
      r.merged = { ...b, state: "open", prepared: copy(r.prepared), log: copy(kept) };
      this.save();
      const later = [{ ...b, log: b.log.slice(r.within.logIndex) }, ...affected.slice(1)];
      const replayed: Logged<A>[] = [];
      for (const l of later.flatMap((x) => x.log.filter((y) => y.ok))) replayed.push(await this.apply(l.action));
      if (affected.some((x) => x.state === "sealed")) await this.seal();
      this.journal.batches = [...this.batches.slice(0, i), r.merged];
      this.journal.recovering = undefined;
      this.save();
      return { status: "recovered", from: r.from, reason: r.reason, segment: r.within.segment, replayed, dropped: replayed.filter((x) => !x.ok), notRetried: later.flatMap((x) => x.log.filter((y) => !y.ok)) };
    }
    // 3. Roll the executor back to just before the first affected batch.
    const cp = affected[0].checkpoint;
    if (!cp || !(await this.exec.rpc<boolean>("evm_revert", [cp]).catch(() => false))) {
      await this.rebuild();
      // rebuild() re-executes everything up to (not including) the first affected batch
    }
    const from = affected[0].openState;
    // 4. Replay their accepted actions, in order, into one batch on the new snapshot, built
    //    apart from the journal's batches (`current` is the replay while it's being built).
    const checkpoint = await this.exec.checkpoint();
    const prepared = copy(r.prepared);
    const no = await this.openWith(prepared);
    r.merged = { no: `${no}`, state: "open", snap: this.openedAt(prepared) ?? r.snap, openState: from, prepared, log: [], checkpoint };
    this.save();
    const accepted = affected.flatMap((b) => b.log.filter((l) => l.ok));
    const notRetried = affected.flatMap((b) => b.log.filter((l) => !l.ok));
    const replayed: Logged<A>[] = [];
    for (const l of accepted) replayed.push(await this.apply(l.action));
    if (affected.some((b) => b.state === "sealed")) await this.seal();
    // 5. One save swaps the originals for the replay and clears the intent.
    this.journal.batches = [...this.batches.slice(0, i), r.merged];
    this.journal.recovering = undefined;
    this.save();
    return { status: "recovered", from: r.from, reason: r.reason, replayed, dropped: replayed.filter((x) => !x.ok), notRetried };
  }
}

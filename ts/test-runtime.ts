// The batch runtime's control flow (runtime/batches.ts) with a fake L1 view and executor:
// no chain, so each case is exact. Regressions for the review of 174ecfc:
//   #3  a batch whose later execution segment's L1 block is orphaned is recovered, though the
//       block it opened at is still canonical; an ordinary head advance changes nothing.
//   #4  a crash in the middle of a recovery's replay loses nothing: the original actions stay
//       in the journal until the replay is complete, and a restart replays all of them.
// And recovery inside a batch: an orphaned segment with a checkpoint is recovered from there,
// keeping what ran before it; without a usable checkpoint, the whole batch is recovered.
// Run: npm run test-runtime
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Hex } from "viem";
import { BatchRuntime, type JournalBatch } from "./runtime/batches.ts";
import type { Snapshot } from "./runtime/l1view.ts";

function check(c: unknown, m: string) {
  if (!c) throw new Error(`FAILED: ${m}`);
  console.log(`ok  ${m}`);
}

const snap = (n: number, branch = "a"): Snapshot => ({
  chainId: 1, number: BigInt(n), hash: `0x${branch.repeat(2)}${n.toString(16).padStart(62, "0")}` as Hex,
  parentHash: "0x" as Hex, stateRoot: "0x" as Hex, policy: { kind: "latest" }, speculative: true,
});

/** L1 as the fake node sees it: a head, and the hash it has at each height. */
class FakeL1 {
  head = 100;
  orphaned = new Set<string>();
  unknown = new Set<string>();
  async snapshot() { return snap(this.head, "b"); }
  async head_() { return BigInt(this.head); }
  async canonicalStatus(s: Snapshot) {
    if (this.unknown.has(s.hash)) return "unknown" as const;
    return this.orphaned.has(s.hash) ? ("orphaned" as const) : ("canonical" as const);
  }
}

class Crash extends Error {}

type Point = { snap: Snapshot; checkpoint?: Hex; logIndex?: number };
type P = { heads: Point[] };
/** Actions are strings; "fill@N" runs at L1 block N (starting a segment there). */
class FakeRuntime extends BatchRuntime<string, { n: number }> {
  l1: FakeL1;
  ran: string[] = [];
  crashBefore?: string;
  opened = 0;
  reverts: string[] = [];
  revertOk = true;
  constructor(l1: FakeL1, path: string) {
    const view = { snapshot: () => l1.snapshot(), head: () => l1.head_(), canonicalStatus: (s: Snapshot) => l1.canonicalStatus(s) };
    let n = 0;
    const exec = {
      checkpoint: async () => `0x${(++n).toString(16)}`,
      rpc: async (_m: string, [id]: [string]) => { this.reverts.push(id); return this.revertOk; },
    };
    super(view as any, exec as any, path, { kind: "latest" }, 256n, 16n);
    this.l1 = l1;
  }
  protected async openState() { return { n: this.ran.length }; }
  protected async prepare(): Promise<unknown> { return { heads: [] } satisfies P; }
  protected async openWith() { return BigInt(++this.opened); }
  protected openedAt() { return snap(this.l1.head); }
  protected async run(a: string) {
    if (a === this.crashBefore) throw new Crash(a);
    this.ran.push(a);
    const m = /@(\d+)$/.exec(a);
    if (!m) return;
    const p = this.current.prepared as P;
    if (p.heads.at(-1)?.snap.number === BigInt(m[1])) return; // same head: same segment
    // A new segment: checkpoint just before the action that starts it (as ClearingOperator does).
    const checkpoint = await this.exec.checkpoint();
    p.heads.push({ snap: snap(Number(m[1])), checkpoint, logIndex: this.current.log.length });
  }
  protected segmentPoints(b: JournalBatch<string, { n: number }>) { return (b.prepared as P).heads; }
  protected preparedBefore(prepared: unknown, i: number) { return { heads: (prepared as P).heads.slice(0, i) }; }
  protected transient(e: unknown) { return e instanceof Crash; }
  protected async sealOne() {}
  protected async rebuild() {}
}

async function main() {
  const dir = mkdtempSync(join(tmpdir(), "skim-runtime-"));

  // ---- #3: an orphaned later segment ------------------------------------------------------
  {
    const l1 = new FakeL1();
    const R = new FakeRuntime(l1, join(dir, "j3.json"));
    await R.open(); // at block 100
    await R.apply("fill@100");
    l1.head = 101;
    await R.apply("fill@101"); // segment 1 at block 101
    l1.head = 103;
    check((await R.tick()).status === "nothing", "the head moves on (101 → 103), every block still canonical: nothing to do");
    l1.orphaned.add(snap(101).hash);
    R.revertOk = false; // the checkpoint is gone: the whole batch is recovered
    const r = await R.tick();
    check(r.status === "recovered" && r.reason === "orphaned" && r.from === "1" && r.segment === undefined,
      "#3: block 101 (segment 1's head) is orphaned while the opening block 100 isn't: tick() recovers the batch");
    check(r.replayed.length === 2 && R.current.no === "2" && R.batches.length === 1, "without a usable checkpoint, both fills are replayed into a new batch; nothing from block 101 survives");
    l1.unknown.add(snap(101).hash); // the replay ran "fill@101" again, so the batch lists 101 once more
    check((await R.tick()).status === "unknown" && R.paused, "a segment head the node can't confirm pauses proposing (not treated as a reorg)");
  }

  // ---- recovery inside the batch, from the orphaned segment's checkpoint --------------------
  {
    const l1 = new FakeL1();
    const R = new FakeRuntime(l1, join(dir, "jw.json"));
    await R.open(); // at block 100
    await R.apply("fill@100"); // segment 0
    await R.apply("X");
    l1.head = 101;
    await R.apply("fill@101"); // segment 1: a checkpoint, log index 2
    await R.apply("Y");
    const cp1 = (R.current.prepared as P).heads[1].checkpoint;
    l1.head = 103;
    l1.orphaned.add(snap(101).hash);
    R.ran = [];
    const r = await R.tick();
    check(r.status === "recovered" && r.segment === 1 && R.reverts.at(-1) === cp1,
      "block 101 is orphaned: the executor goes back to segment 1's checkpoint (taken just before the fill that started it)");
    check(R.ran.join() === "fill@101,Y" && R.current.no === "1" && R.current.log.map((l) => l.action).join() === "fill@100,X,fill@101,Y",
      "only what ran from that segment on is replayed; the batch keeps its number, opening and segment 0 (fill@100 and X ran against canonical blocks)");
    check((R.current.prepared as P).heads.length === 2 && (R.current.prepared as P).heads[1].checkpoint !== cp1,
      "the replayed fill starts a fresh segment, with its own checkpoint");
  }

  // ---- #4: a crash mid-replay ---------------------------------------------------------------
  {
    const l1 = new FakeL1();
    const path = join(dir, "j4.json");
    const R = new FakeRuntime(l1, path);
    await R.open();
    for (const a of ["A", "B", "C"]) await R.apply(a);
    R.crashBefore = "B"; // the process dies after A is replayed and saved
    let crashed = false;
    try { await R.recover("1", "orphaned"); } catch (e) { crashed = e instanceof Crash; }
    check(crashed, "the recovery's replay stops after A (simulated crash)");
    const onDisk = JSON.parse(readFileSync(path, "utf8"));
    check(onDisk.batches.length === 1 && onDisk.batches[0].log.map((l: any) => l.action).join() === "A,B,C",
      "#4: the journal on disk still holds the original batch with A, B and C");
    check(onDisk.recovering?.merged?.log.map((l: any) => l.action).join() === "A", "the partial replay (A) is kept apart, in recovering.merged");
    const R2 = new FakeRuntime(l1, path); // restart from the journal
    const r = await R2.resume();
    check(r.status === "recovered" && r.replayed.map((l) => l.action).join() === "A,B,C" && R2.ran.join() === "A,B,C",
      "after the restart, resume() replays A, B and C (the interrupted replay is discarded and redone)");
    const final = JSON.parse(readFileSync(path, "utf8"));
    check(final.batches.length === 1 && final.batches[0].log.map((l: any) => l.action).join() === "A,B,C" && !final.recovering,
      "and only then is the original swapped for the replay, in one save");
  }
  console.log("RUNTIME TESTS PASSED");
}

main().catch((e) => { console.error(e); process.exit(1); });

// The batch runtime's control flow (runtime/batches.ts) with a fake L1 view and executor:
// no chain, so each case is exact. Regressions for the review of 174ecfc:
//   #3  a batch whose later execution segment's L1 block is orphaned is recovered, though the
//       block it opened at is still canonical; an ordinary head advance changes nothing.
//   #4  a crash in the middle of a recovery's replay loses nothing: the original actions stay
//       in the journal until the replay is complete, and a restart replays all of them.
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

type P = { heads: Snapshot[] };
/** Actions are strings; "fill@N" runs at L1 block N (starting a segment there). */
class FakeRuntime extends BatchRuntime<string, { n: number }> {
  l1: FakeL1;
  ran: string[] = [];
  crashBefore?: string;
  opened = 0;
  constructor(l1: FakeL1, path: string) {
    const view = { snapshot: () => l1.snapshot(), head: () => l1.head_(), canonicalStatus: (s: Snapshot) => l1.canonicalStatus(s) };
    const exec = { checkpoint: async () => "0x1", rpc: async () => true };
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
    if (m) (this.current.prepared as P).heads.push(snap(Number(m[1])));
  }
  protected heads(b: JournalBatch<string, { n: number }>) { return (b.prepared as P).heads; }
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
    const r = await R.tick();
    check(r.status === "recovered" && r.reason === "orphaned" && r.from === "1",
      "#3: block 101 (segment 1's head) is orphaned while the opening block 100 isn't: tick() recovers the batch");
    check(r.replayed.length === 2 && R.current.no === "2" && R.batches.length === 1, "both fills are replayed into one batch at the new head; nothing from block 101 survives");
    l1.unknown.add(snap(101).hash); // the replay ran "fill@101" again, so the batch lists 101 once more
    check((await R.tick()).status === "unknown" && R.paused, "a segment head the node can't confirm pauses proposing (not treated as a reorg)");
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

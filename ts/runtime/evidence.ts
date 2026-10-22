// Pinned evidence: the witnesses an unsettled obligation may need later (a round's
// resolution value, a batch's L1 reads). Kept apart from any head cache: nothing here is
// evicted by age or size, only released once the obligation it backs is settled on L1.
// Each record is self-contained (raw header + witness package) so anyone holding a copy
// can act on L1 without an RPC that still serves old proofs.
import { mkdirSync, writeFileSync, readFileSync, renameSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import type { Hex } from "viem";

export type EvidenceRecord = {
  purpose: string; // e.g. "prediction:resolution:<channel>:<round>"
  anchor: { chainId: number; blockNumber: string; blockHash: Hex; stateRoot?: Hex };
  rawHeader: Hex;
  package: Hex; // abi.encode(WitnessPackage), as WitnessVerifier.verify takes it
  reads: { account: Hex; slot: Hex }[];
  pinnedAt: string; // ISO time
  releasedAt?: string;
  note?: string;
};

export class EvidenceStore {
  readonly dir: string;
  constructor(dir: string) {
    this.dir = dir;
    mkdirSync(join(dir, "pinned"), { recursive: true });
    mkdirSync(join(dir, "released"), { recursive: true });
  }

  private path(state: "pinned" | "released", key: string) {
    if (!/^[A-Za-z0-9:._-]+$/.test(key)) throw new Error(`bad evidence key ${key}`);
    return join(this.dir, state, `${key.replaceAll(":", "_")}.json`);
  }

  /** Write atomically (temp file + rename): a crash never leaves a half record. */
  pin(key: string, r: Omit<EvidenceRecord, "pinnedAt">) {
    const p = this.path("pinned", key);
    const tmp = `${p}.tmp`;
    writeFileSync(tmp, JSON.stringify({ ...r, pinnedAt: new Date().toISOString() }, null, 2));
    renameSync(tmp, p);
  }

  get(key: string): EvidenceRecord | undefined {
    const p = this.path("pinned", key);
    return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : undefined;
  }

  /** Only after L1 shows the obligation settled. Moves the record aside; nothing is deleted. */
  release(key: string) {
    const rec = this.get(key);
    if (!rec) throw new Error(`no pinned evidence ${key}`);
    writeFileSync(this.path("released", key), JSON.stringify({ ...rec, releasedAt: new Date().toISOString() }, null, 2));
    renameSync(this.path("pinned", key), `${this.path("pinned", key)}.moved`);
  }

  pinnedKeys(): string[] {
    return readdirSync(join(this.dir, "pinned")).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5));
  }
}

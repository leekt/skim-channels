// L1ReadView: the app's selective, read-only view of L1 through JSON-RPC (skim, or any node
// for local tests). Rules it enforces:
// - One snapshot per batch: a single block (number, hash, state root) chosen by a
//   confirmation policy. Every read for the batch names that block hash. Two "latest" reads
//   are never treated as one snapshot.
// - stateReady vs proofReady: `value()` returns a node's answer (on skim, a tracked key kept
//   current from BALs) — good for previews, never an execution input. `witness()` returns
//   EIP-1186 proofs at the exact block hash, which the executor verifies before the app may
//   read them; if the node can't serve them (skim: recent roots only), it throws.
// - `latest` is speculative: anything executed on it can be rolled back if the block leaves
//   the chain (`canonical()`), and a skim stream reports rewinds explicitly.
import { execFileSync } from "node:child_process";
import { createPublicClient, http, type Hex, type Address } from "viem";

export type Policy =
  | { kind: "latest" } // speculative
  | { kind: "confirmations"; n: number }
  | { kind: "safe" }
  | { kind: "finalized" };

export type Snapshot = {
  chainId: number;
  number: bigint;
  hash: Hex;
  parentHash: Hex;
  stateRoot: Hex;
  policy: Policy;
  speculative: boolean;
};

export type Read = { account: Address; slots: Hex[] };
export type Witness = { anchorId: Hex; rawHeader: Hex; package: Hex };

export class ProofNotReady extends Error {}

export class L1ReadView {
  readonly url: string;
  readonly chainId: number;
  readonly cli: string;
  readonly client;

  constructor(opts: { url: string; chainId: number; cli: string }) {
    this.url = opts.url;
    this.chainId = opts.chainId;
    this.cli = opts.cli;
    this.client = createPublicClient({ transport: http(opts.url) });
  }

  private rpc<T>(method: string, params: unknown[]): Promise<T> {
    return this.client.request({ method: method as any, params: params as any }) as Promise<T>;
  }

  /** One block, chosen by the policy, in one call. */
  async snapshot(policy: Policy): Promise<Snapshot> {
    let tag: string;
    if (policy.kind === "confirmations") {
      const head = BigInt(await this.rpc<Hex>("eth_blockNumber", []));
      tag = `0x${(head - BigInt(policy.n)).toString(16)}`;
    } else {
      tag = policy.kind;
    }
    const b = await this.rpc<any>("eth_getBlockByNumber", [tag, false]);
    if (!b) throw new Error(`no block for ${tag}`);
    return {
      chainId: this.chainId, number: BigInt(b.number), hash: b.hash, parentHash: b.parentHash, stateRoot: b.stateRoot,
      policy, speculative: policy.kind === "latest",
    };
  }

  /** stateReady: the node's value at the snapshot's block hash. Not an execution input. */
  async value(snap: Snapshot, account: Address, slot: Hex): Promise<bigint> {
    return BigInt(await this.rpc<Hex>("eth_getStorageAt", [account, slot, { blockHash: snap.hash }]));
  }

  /** proofReady: proofs for every read at exactly this block (via the skim-channels CLI). */
  witness(snap: Snapshot, reads: Read[]): Witness {
    const args = ["witness", "--rpc", this.url, "--block-hash", snap.hash, "--chain-id", `${this.chainId}`];
    for (const r of reads) args.push("--read", `${r.account}:${r.slots.join(":")}`);
    try {
      return JSON.parse(execFileSync(this.cli, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
    } catch (e: any) {
      throw new ProofNotReady(`no proofs at ${snap.hash}: ${String(e.stderr ?? e.message).trim()}`);
    }
  }

  /** Is the snapshot's block still the canonical block at its height? */
  async canonical(snap: Snapshot): Promise<boolean> {
    const b = await this.rpc<any>("eth_getBlockByNumber", [`0x${snap.number.toString(16)}`, false]);
    return !!b && b.hash === snap.hash;
  }

  /**
   * skim only: the next blocks' state changes for `addresses` (from block access lists) and
   * rewinds. `recent` is the caller's newest blocks (hash list), so skim can say how far to
   * undo after a reorg. See skim's json-rpc guide, `skim_streamNext`.
   */
  streamNext(req: { cursor?: unknown; recent: { number: number; hash: Hex }[]; addresses: Address[]; maxBlocks?: number; fromBlock?: number }) {
    return this.rpc<any>("skim_streamNext", [{
      cursor: req.cursor, recent: req.recent, fromBlock: req.fromBlock, filters: [],
      bal: { addresses: req.addresses }, maxBlocks: req.maxBlocks ?? 8,
    }]);
  }
}

/** Storage slot of `mapping(address => …)` at `slot`, plus `offset` words. */
export async function mappingSlot(key: Address, slot: bigint, offset = 0n): Promise<Hex> {
  const { keccak256, encodeAbiParameters, toHex } = await import("viem");
  const base = BigInt(keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [key, slot])));
  return toHex(base + offset, { size: 32 });
}

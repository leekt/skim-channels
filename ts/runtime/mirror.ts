// Relays a Chainlink answer from a source chain (Sepolia, via a skim node) into FeedMirror on
// another chain, with storage proofs. Each step: take a snapshot under the policy (skim's
// `safe` by default), read the aggregator's latest round there, prove both slots at that
// exact block hash, and send `update(rawHeader, package)`. FeedMirror verifies the proofs;
// that the header is canonical is this relayer's word (see FeedMirror.sol).
import { encodeAbiParameters, keccak256, type Address, type Hex } from "viem";
import type { PrivateKeyAccount } from "viem/accounts";
import type { C, Chain } from "./executor.ts";
import { type L1ReadView, type Policy } from "./l1view.ts";

export const HOT_SLOT: Hex = `0x${"2b".padStart(64, "0")}`;
export const transmissionSlot = (round: number): Hex =>
  keccak256(encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [BigInt(round), 0x2cn]));

export type Mirrored = {
  sourceBlock: bigint; sourceBlockHash: Hex; round: number; answer: bigint; answeredAt: bigint;
  proofBytes: number; proveMs: number; tx: Hex; gas: bigint; at: number;
};

export class FeedRelay {
  last?: Mirrored;
  readonly source: L1ReadView;
  readonly target: Chain;
  readonly mirror: C;
  readonly relayer: PrivateKeyAccount;
  readonly aggregator: Address;
  readonly policy: Policy;

  constructor(source: L1ReadView, target: Chain, mirror: C, relayer: PrivateKeyAccount, aggregator: Address, policy: Policy = { kind: "safe" }) {
    this.source = source;
    this.target = target;
    this.mirror = mirror;
    this.relayer = relayer;
    this.aggregator = aggregator;
    this.policy = policy;
  }

  /** Mirror the latest answer at the policy's block, if that block is newer than the last. */
  async step(): Promise<Mirrored | undefined> {
    const snap = await this.source.snapshot(this.policy);
    if (this.last && snap.number <= this.last.sourceBlock) return undefined;
    const hot = await this.source.value(snap, this.aggregator, HOT_SLOT);
    const round = Number((hot >> 176n) & 0xffffffffn);
    const t0 = Date.now();
    const w = this.source.witness(snap, [{ account: this.aggregator, slots: [HOT_SLOT, transmissionSlot(round)] }]);
    const proveMs = Date.now() - t0;
    const r = await this.target.send(this.mirror, "update", [w.rawHeader, w.package], this.relayer);
    const [price, answeredAt] = await Promise.all([
      this.target.read<bigint>(this.mirror, "price"), this.target.read<bigint>(this.mirror, "answeredAt"),
    ]);
    this.last = {
      sourceBlock: snap.number, sourceBlockHash: snap.hash, round, answer: price, answeredAt,
      proofBytes: (w.package.length - 2) / 2 + (w.rawHeader.length - 2) / 2, proveMs, tx: r.transactionHash, gas: r.gasUsed, at: Date.now(),
    };
    return this.last;
  }
}

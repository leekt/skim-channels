// LIVE: the read path against a real skim node (Sepolia), into the app on a local executor.
// Not part of CI, and separate from the deterministic e2e (ts/e2e-clearing.ts), which uses
// anvil as L1. Nothing is settled here (no Sepolia escrow); this checks what only a real
// skim can: BAL-driven state changes, safe snapshots from skim's light client, proofs at an
// exact block, the window where proofs stop, and that AppState carries across snapshots.
//   SKIM_RPC=http://127.0.0.1:8545 npm run live-skim
import { privateKeyToAccount } from "viem/accounts";
import { mkdirSync, writeFileSync } from "node:fs";
import type { Address, Hex } from "viem";
import { Chain } from "./runtime/executor.ts";
import { L1ReadView, ProofNotReady } from "./runtime/l1view.ts";
import { eip712Order, orderHash, type Order } from "./runtime/clearing.ts";

const ROOT = new URL("..", import.meta.url).pathname;
const CLI = `${ROOT}target/debug/skim-channels`;
const SEPOLIA = 11155111;
const WETH = "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9" as Address; // a busy Sepolia contract
const NOBODY = "0x000000000000000000000000000000000000dEaD" as Address; // stands in for an escrow with nothing in it
const op = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const alice = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");

function check(cond: unknown, msg: string) {
  if (!cond) throw new Error(`FAILED: ${msg}`);
  console.log(`ok  ${msg}`);
}

async function main() {
  const url = process.env.SKIM_RPC;
  if (!url) {
    console.log("SKIM_RPC not set: skipping the live skim test");
    return;
  }
  const view = new L1ReadView({ url, chainId: SEPOLIA, cli: CLI });
  const status = await view.client.request({ method: "skim_status" as any, params: [] as any }) as any;
  check(status?.head > 0, `skim is following Sepolia (head ${status.head}, ${status.el_peers} EL peers)`);
  const out: Record<string, unknown> = { skim: url, head: status.head };

  // 1) state-ready: what changed in WETH's storage, block by block, from block access lists.
  const head = Number(await view.client.request({ method: "eth_blockNumber" as any, params: [] as any }));
  const s1 = await view.streamNext({ recent: [], addresses: [WETH], fromBlock: head - 3, maxBlocks: 4 });
  const changes = (s1.events ?? []).flatMap((e: any) => (e.type === "apply" ? e.stateChanges ?? [] : []));
  const touched = changes.find((c: any) => c.kind === "storage");
  check(touched, `skim_streamNext reported ${changes.length} WETH state changes from BALs (${(s1.events ?? []).length} events)`);
  const slot = touched.slot as Hex;
  out.slot = slot;

  // 2) one snapshot from skim's light client; values vs. proofs at exactly that block.
  const snapA = await view.snapshot({ kind: "safe" });
  const valueA = await view.value(snapA, WETH, slot);
  const t0 = Date.now();
  const wA = view.witness(snapA, [{ account: WETH, slots: [slot] }, { account: NOBODY, slots: [`0x${"0".repeat(64)}`] }]);
  out.witnessMs = Date.now() - t0;
  out.witnessBytes = (wA.package.length - 2) / 2;
  check(true, `safe snapshot ${snapA.number}: stateReady value ${valueA}; proofs at that hash in ${out.witnessMs} ms (${out.witnessBytes} B)`);

  // 3) the app on a local executor reads only the pinned, verified snapshot.
  const ex = await Chain.anvil(18668, 7001);
  try {
    const l1v = await ex.deploy(ROOT, op, "L1View.sol", "L1View", [BigInt(SEPOLIA)]);
    const app = await ex.deploy(ROOT, op, "ClearingApp.sol", "ClearingApp", [l1v.address, NOBODY, BigInt(SEPOLIA), WETH, slot, 10_000n, op.address]);
    await ex.send(l1v, "pin", [wA.rawHeader, wA.package], op);
    check((await ex.read<bigint>(l1v, "read", [wA.anchorId, WETH, slot])) === valueA, "the executor verified the skim proofs: same value as skim's stateReady answer");
    await ex.send(app, "openBatch", [wA.anchorId], op);
    const domain = { name: "SkimClearing", version: "0", chainId: SEPOLIA, verifyingContract: NOBODY };
    const o: Order = { trader: alice.address, sellToken: 0, sellAmount: 10n ** 15n, buyAmount: 1n, nonce: 1n, expiry: 10n ** 12n };
    const sig = await alice.signTypedData({ domain, types: eip712Order, primaryType: "Order", message: o as any });
    await ex.send(app, "submitOrder", [o, sig], op);
    await ex.send(app, "sealBatch", [], op);

    // 4) later: a new snapshot, a new batch; the order placed at A is still in AppState.
    let snapB = await view.snapshot({ kind: "safe" });
    for (let i = 0; i < 30 && snapB.number === snapA.number; i++) {
      await new Promise((r) => setTimeout(r, 4000));
      snapB = await view.snapshot({ kind: "safe" });
    }
    check(snapB.number > snapA.number, `a later safe snapshot ${snapB.number}`);
    const wB = view.witness(snapB, [{ account: WETH, slots: [slot] }, { account: NOBODY, slots: [`0x${"0".repeat(64)}`] }]);
    await ex.send(l1v, "pin", [wB.rawHeader, wB.package], op);
    await ex.send(app, "openBatch", [wB.anchorId], op);
    const bookA = await ex.read<any>(app, "book", [orderHash(o)]);
    check(bookA[0] === alice.address, "AppState kept alice's order across the L1 snapshot change");
    const vA = await ex.read<bigint>(l1v, "read", [wA.anchorId, WETH, slot]);
    const vB = await ex.read<bigint>(l1v, "read", [wB.anchorId, WETH, slot]);
    check(true, `snapshot A still reads ${vA}; snapshot B reads ${vB}`);
    out.values = { a: `${vA}`, b: `${vB}`, blocks: [`${snapA.number}`, `${snapB.number}`] };
    // No escrow on Sepolia here: the collateral gate reads 0 and fails closed.
    let gate = "";
    try { await ex.read(app, "available", [alice.address, 0]); gate = "readable"; } catch { gate = "refused"; }
    check(gate === "refused", "alice's escrow slots weren't witnessed, so collateral can't be read (fail-closed)");

    // 5) reorg signal: ask skim to continue from snapshot A; any rewind would be reported.
    const s2 = await view.streamNext({ recent: [{ number: Number(snapA.number), hash: snapA.hash }], addresses: [WETH], maxBlocks: 2 });
    const rewinds = (s2.events ?? []).filter((e: any) => e.type === "rewind");
    check(true, `skim_streamNext from snapshot A: ${rewinds.length} rewind(s); canonical(A) = ${await view.canonical(snapA)}`);
    out.rewinds = rewinds.length;

    // 6) proofReady ends where skim's peers stop serving state roots (the depth varies).
    const probes: Record<string, string> = {};
    for (const n of [64, 256, 1024, 4096]) {
      try {
        const old = await view.snapshot({ kind: "confirmations", n });
        view.witness(old, [{ account: WETH, slots: [slot] }]);
        probes[n] = "served";
      } catch (e) {
        probes[n] = e instanceof ProofNotReady ? "refused: " + (e.message.match(/"reason":"[a-z_]+"/)?.[0] ?? e.message.slice(-80)) : `no header: ${(e as Error).message}`;
      }
    }
    check(Object.values(probes).some((v) => v !== "served"), `old blocks stop being proof-ready: ${JSON.stringify(probes)}`);
    out.proofDepth = probes;
  } finally {
    ex.stop();
  }
  mkdirSync(`${ROOT}docs/experiments/data`, { recursive: true });
  writeFileSync(`${ROOT}docs/experiments/data/live-skim-clearing.json`, JSON.stringify(out, null, 2) + "\n");
  console.log("LIVE SKIM PASSED");
}

main().catch((e) => { console.error(e); process.exit(1); });

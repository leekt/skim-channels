// Subscription-first L1 reads, live on Sepolia through skim (the executor follows
// skim_streamNext). A tiny L1 contract is deployed on Sepolia for this, then: act against H,
// change it on Sepolia, act again: the executor has moved to the new block by itself, the
// second action sees the new value, app state is kept. Measured: cold vs warm reads, network
// requests per Sepolia block, stream events, state-ready cross-checks. Then the executor
// restarts with the same --state-dir and continues the stream from its cursor.
// Run: SKIM_RPC=http://127.0.0.1:18545 SEPOLIA_OPERATOR_KEY=0x… npm run live-subscription
import { existsSync, mkdtempSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { privateKeyToAccount } from "viem/accounts";
import type { Hex } from "viem";
import { Chain } from "./runtime/executor.ts";

const ROOT = new URL("..", import.meta.url).pathname;
const SKIM = process.env.SKIM_RPC ?? "http://127.0.0.1:18545";
const op = privateKeyToAccount(process.env.SEPOLIA_OPERATOR_KEY as Hex);
const appUser = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"); // app-local only
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
function check(c: unknown, m: string) {
  if (!c) throw new Error(`FAILED: ${m}`);
  console.log(`ok  ${m}`);
}
const delta = (a: Record<string, number>, b: Record<string, number>) => Object.fromEntries(Object.keys(b).map((k) => [k, b[k] - a[k]]));

const l1 = new Chain(SKIM, 11155111);
const feed = await l1.deploy(ROOT, op, "Probes.sol", "L1Feed", [42n]);
console.log(`     L1Feed on Sepolia: ${feed.address} `);
const dir = mkdtempSync(join(tmpdir(), "skim-executor-state-"));
const start = () => Chain.appExecutor(ROOT, 18975, 7001, SKIM, { readonly: [feed.address], stateDir: dir } as any);
let ex = await start();
try {
  const probe = await ex.deploy(ROOT, appUser, "Probes.sol", "AppProbe");
  const read = () => ex.pub.readContract({ address: probe.address, abi: probe.abi, functionName: "read", args: [feed.address] }) as Promise<bigint>;
  const record = async () => {
    const hash = await ex.wallet(appUser).writeContract({ address: probe.address, abi: probe.abi, functionName: "record", args: [feed.address], gas: 500_000n } as any);
    await ex.pub.waitForTransactionReceipt({ hash });
    return ex.rpc<any>("eth_getTransactionReceipt", [hash]);
  };
  let t = performance.now();
  await read();
  const coldMs = performance.now() - t;
  const r1 = await record();
  const H = BigInt(r1.l1BlockNumber);
  check((await ex.pub.readContract({ address: probe.address, abi: probe.abi, functionName: "lastSeen" })) === 42n, `action 1 against Sepolia block ${H}: saw 42`);

  const m0 = await ex.rpc<Record<string, number>>("executor_metrics");
  const rc = await l1.send(feed, "set", [43n], op);
  const changedAt = rc.blockNumber;
  const t0 = Date.now();
  while (BigInt((await ex.rpc<any>("executor_status")).pin.number) < changedAt) {
    if (Date.now() - t0 > 120_000) throw new Error("FAILED: the executor didn't follow Sepolia");
    await sleep(200);
  }
  const followMs = Date.now() - t0;
  const r2 = await record();
  const m1 = await ex.rpc<Record<string, number>>("executor_metrics");
  check(BigInt(r2.l1BlockNumber) >= changedAt, `action 2 against Sepolia block ${BigInt(r2.l1BlockNumber)}: the executor followed by itself (${followMs} ms after the change's receipt); no pin, sync or restart`);
  check((await ex.pub.readContract({ address: probe.address, abi: probe.abi, functionName: "lastSeen" })) === 43n, "action 2 saw the new Sepolia value (43)");
  check((await ex.pub.readContract({ address: probe.address, abi: probe.abi, functionName: "count" })) === 2n, "app state carried over: count = 2");
  const d = delta(m0, m1);
  check(d.cold_fetches === 0, `the second action needed no proof of its own (${d.warm_reads} warm reads)`);
  check(d.state_ready_mismatches === 0, `the stream's state-ready changes agreed with the proofs (${d.state_ready_changes} changes seen; used only as a cross-check)`);
  const N = 30;
  t = performance.now();
  for (let i = 0; i < N; i++) await read();
  const warmMs = (performance.now() - t) / N;
  const blocks = d.heads_adopted;
  console.log(`     ${blocks} Sepolia block(s) followed: ${d.proof_requests} eth_getProof, ${d.code_requests} code fetches, ${d.header_requests} header requests, ${d.stream_apply} stream applies, ${d.stream_rewind} rewinds, ${d.stream_gap} gaps; ${(d.refresh_ms / Math.max(1, blocks)).toFixed(0)} ms proving per block`);
  console.log(`     latency through the app network: cold first read ${coldMs.toFixed(0)} ms (proved via skim), warm ${warmMs.toFixed(2)} ms`);

  // Restart with the same state dir: the stream continues from the cursor on disk.
  const cursorFile = join(dir, "stream-cursor.json");
  check(existsSync(cursorFile), "the stream cursor is on disk");
  ex.stop();
  const stored = JSON.parse(readFileSync(cursorFile, "utf8"));
  await sleep(500);
  ex = await start();
  const before = BigInt((await ex.rpc<any>("executor_status")).pin.number);
  await sleep(30_000);
  const st = await ex.rpc<any>("executor_status");
  const resumed = JSON.parse(readFileSync(cursorFile, "utf8"));
  // (apply events come only for blocks that touch a watched account; the cursor shows progress)
  check(st.following && BigInt(st.pin.number) > before && Number(resumed.number) > Number(stored.number),
    `restarted with the same --state-dir: the stream continued from the stored cursor (block ${stored.number} → ${resumed.number}), head ${st.pin.number}`);
  mkdirSync(`${ROOT}docs/experiments/data`, { recursive: true });
  writeFileSync(`${ROOT}docs/experiments/data/subscription-sepolia.json`, JSON.stringify({
    note: "Sepolia through skim (skim_streamNext); app executor crates/app-executor; one read-only imported contract",
    coldReadMs: +coldMs.toFixed(0), warmReadMs: +warmMs.toFixed(2), followMsAfterReceipt: followMs, acrossTheUpdate: d,
  }, null, 2) + "\n");
  console.log("LIVE SUBSCRIPTION PASSED");
} finally {
  ex.stop();
}

// Subscription-first L1 reads, end to end on an anvil L1 (the executor polls the head here; on
// skim it follows skim_streamNext: see live-subscription.ts).
//
// A. Executor: act against H, change the L1 dependency, act again: the executor has moved to
//    H+1 by itself (no executor_pin, no sync, no restart), the second action sees the new value,
//    and app state is kept. Measured: cold vs warm read latency, network requests per block.
// B. Clearing: one session, one batch. A fill at H (feed 2000); the feed moves to 2100 on L1; the
//    next fill in the same batch runs at the new head and starts a new oracle segment by
//    itself. L1 verifies both segments' prices at their anchors, a watcher finds nothing to
//    challenge, and the batch finalizes. No new session and no L1 keep-alive.
// Run: npm run e2e-subscription  (needs anvil, forge build, cargo build -p channel-runner -p app-executor)
import { writeFileSync, mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { keccak256, pad, parseEther, toHex, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Chain } from "./runtime/executor.ts";
import { L1ReadView } from "./runtime/l1view.ts";
import { EvidenceStore } from "./runtime/evidence.ts";
import { ClearingOperator, deploySessionCode, eip712Order, openSession, orderHash, type Order } from "./runtime/clearing.ts";

const ROOT = new URL("..", import.meta.url).pathname;
const CLI = `${ROOT}target/debug/skim-channels`;
const op = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const alice = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const bob = privateKeyToAccount("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
const appUser = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");
const usd = (x: number) => BigInt(Math.round(x * 1e6));
const answer = (x: number) => BigInt(Math.round(x * 1e8));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function check(c: unknown, m: string) {
  if (!c) throw new Error(`FAILED: ${m}`);
  console.log(`ok  ${m}`);
}
const metrics = (ex: Chain) => ex.rpc<Record<string, number>>("executor_metrics");
const delta = (a: Record<string, number>, b: Record<string, number>) => Object.fromEntries(Object.keys(b).map((k) => [k, b[k] - a[k]]));
/** Watch the executor's head (observation only) until it has applied at least `n`. */
async function headAtLeast(ex: Chain, n: bigint, ms = 15_000) {
  const t0 = Date.now();
  for (;;) {
    const st = await ex.rpc<any>("executor_status");
    if (BigInt(st.pin.number) >= n) return { head: BigInt(st.pin.number), waitedMs: Date.now() - t0 };
    if (Date.now() - t0 > ms) throw new Error(`FAILED: executor didn't reach L1 block ${n}`);
    await sleep(50);
  }
}

const chains: Chain[] = [];
const out: Record<string, unknown> = { note: "anvil L1 (no skim stream: the executor polls the head every 500 ms); app executor crates/app-executor" };

async function partA(l1: Chain) {
  const feed = await l1.deploy(ROOT, op, "Probes.sol", "L1Feed", [42n]);
  const ex = await Chain.appExecutor(ROOT, 18972, 7001, l1.url, { readonly: [feed.address] });
  chains.push(ex);
  const probe = await ex.deploy(ROOT, appUser, "Probes.sol", "AppProbe");
  const w = ex.wallet(appUser);
  const record = async () => {
    const hash = await w.writeContract({ address: probe.address, abi: probe.abi, functionName: "record", args: [feed.address], gas: 500_000n } as any);
    await ex.pub.waitForTransactionReceipt({ hash });
    return ex.rpc<any>("eth_getTransactionReceipt", [hash]);
  };
  const read = () => ex.pub.readContract({ address: probe.address, abi: probe.abi, functionName: "read", args: [feed.address] }) as Promise<bigint>;

  // Cold: the first read of the dependency proves it on the spot.
  let t = performance.now();
  await read();
  const coldMs = performance.now() - t;
  const r1 = await record();
  const H = BigInt(r1.l1BlockNumber);
  check((await ex.pub.readContract({ address: probe.address, abi: probe.abi, functionName: "lastSeen" })) === 42n, `action 1 ran against L1 block ${H}: it saw 42`);

  // L1 changes the dependency; the executor follows by itself.
  const m0 = await metrics(ex);
  await l1.send(feed, "set", [43n], op);
  const { head, waitedMs } = await headAtLeast(ex, H + 1n);
  const r2 = await record();
  const m1 = await metrics(ex);
  check(BigInt(r2.l1BlockNumber) > H, `action 2 ran against L1 block ${BigInt(r2.l1BlockNumber)} (the executor got there by itself in ${waitedMs} ms; nobody called executor_pin, sync or restart)`);
  check((await ex.pub.readContract({ address: probe.address, abi: probe.abi, functionName: "lastSeen" })) === 43n, "action 2 saw the new L1 value (43)");
  check((await ex.pub.readContract({ address: probe.address, abi: probe.abi, functionName: "count" })) === 2n, "and app state carried over: count = 2");
  const d = delta(m0, m1);
  check(d.cold_fetches === 0, `across those blocks the action needed no proof of its own: ${d.cold_fetches} cold fetches, ${d.warm_reads} warm reads`);

  // Warm reads: the dependency is proven at the current head already.
  const N = 50;
  t = performance.now();
  for (let i = 0; i < N; i++) await read();
  const warmMs = (performance.now() - t) / N;
  // Network per block of following: one proof per account in the working set.
  const m2 = await metrics(ex);
  for (let i = 0; i < 5; i++) {
    await l1.rpc("anvil_mine", [toHex(1)]);
    await headAtLeast(ex, (await l1.height()));
  }
  const m3 = await metrics(ex);
  const per = delta(m2, m3);
  check(per.heads_adopted === 5 && per.proof_requests === 5 * 1 && per.cold_fetches === 0,
    `per block followed: ${per.proof_requests / 5} eth_getProof (1 account in the working set), ${per.code_requests} code fetches, ${(per.refresh_ms / 5).toFixed(0)} ms proving, off the execution path`);
  console.log(`     latency (eth_call through the app network, incl. HTTP): cold first read ${coldMs.toFixed(1)} ms, warm ${warmMs.toFixed(2)} ms`);
  out.executor = { coldReadMs: +coldMs.toFixed(1), warmReadMs: +warmMs.toFixed(2), followLatencyMs: waitedMs, acrossOneUpdate: d, perBlock: { proofRequests: per.proof_requests / 5, proofSlots: per.proof_slots / 5, codeRequests: per.code_requests, headerRequests: per.header_requests / 5, provingMs: per.refresh_ms / 5 } };
  void head;
}

async function partB(l1: Chain) {
  const agg = await l1.deploy(ROOT, op, "ChainlinkMocks.sol", "MockOffchainAggregator", [answer(2000)]);
  const proxy = await l1.deploy(ROOT, op, "ChainlinkMocks.sol", "MockFeedProxy", [agg.address]);
  const codeHash = async (a: Address) => keccak256((await l1.pub.getCode({ address: a }))!);
  const MAX_STALE = 86_400n;
  const adapter = await l1.deploy(ROOT, op, "ChainlinkAdapter.sol", "ChainlinkAdapter",
    [proxy.address, await codeHash(proxy.address), agg.address, await codeHash(agg.address), 8, MAX_STALE]);
  const anchors = await l1.deploy(ROOT, op, "AnchorRegistry.sol", "AnchorRegistry");
  const codec = await l1.deploy(ROOT, op, "ClearingCodec.sol", "ClearingCodec");
  const token = await l1.deploy(ROOT, op, "Clearing.t.sol", "TestUSD");
  const vault = await l1.deploy(ROOT, op, "ClearingVault.sol", "ClearingVault", [op.address, token.address]);
  const session = await openSession(l1, op, vault, await deploySessionCode(l1, op), {
    operator: op.address, anchors: anchors.address, codec: codec.address, priceAdapter: adapter.address, bandBps: 100n,
    challengeWindow: 3600n, forceDelay: 86_400n, maxAnchorAge: 256n, minBond: parseEther("1"), takeoverDelay: 172_800n, appChainId: 7001n,
  });
  const ch = session.channel;
  await l1.send(ch, "deposit", [0, parseEther("2")], alice, undefined, parseEther("2"));
  await l1.send(token, "mint", [bob.address, usd(10_000)], bob);
  await l1.send(token, "approve", [ch.address, usd(10_000)], bob);
  await l1.send(ch, "deposit", [1, usd(10_000)], bob);

  const ex = await Chain.appExecutor(ROOT, 18973, 7001, l1.url, { readonly: [...session.imports, proxy.address, agg.address] });
  chains.push(ex);
  const feed = { proxy: proxy.address, aggregator: agg.address };
  const book = await ClearingOperator.deployBook(ex, l1, op, ch, feed, MAX_STALE);
  const dir = mkdtempSync(join(tmpdir(), "skim-subscription-"));
  const A = new ClearingOperator({
    view: new L1ReadView({ url: l1.url, chainId: 900, cli: CLI }), exec: ex, book, op, l1, channel: ch, anchors, feed, maxStaleness: MAX_STALE,
    evidence: new EvidenceStore(join(dir, "evidence")), policy: { kind: "latest" }, bond: parseEther("1"),
    journal: join(dir, "journal.json"), maxAnchorAge: 256n, ageMargin: 16n, nextBlock: () => l1.rpc("anvil_mine", [toHex(1)]),
  });
  const domain = { name: "SkimClearing", version: "0", chainId: 7001, verifyingContract: ch.address, salt: pad(toHex(1n), { size: 32 }) };
  const order = async (who: typeof alice, sellToken: number, sellAmount: bigint, buyAmount: bigint, nonce: bigint) => {
    const o: Order = { trader: who.address, sellToken, sellAmount, buyAmount, nonce, expiry: 10n ** 9n };
    return { o, sig: await who.signTypedData({ domain, types: eip712Order, primaryType: "Order", message: o as any }), h: orderHash(o) };
  };

  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  const a1 = await order(alice, 0, parseEther("0.5"), usd(1000), 1n);
  const k1 = await order(bob, 1, usd(1000), parseEther("0.5"), 1n);
  await A.apply({ kind: "order", order: a1.o, sig: a1.sig });
  await A.apply({ kind: "order", order: k1.o, sig: k1.sig });
  check((await A.apply({ kind: "fill", a: a1.h, b: k1.h })).ok, "batch 1, fill 1 at 2000 (the head the batch opened at)");
  const h0 = BigInt((await ex.rpc<any>("executor_status")).pin.number);

  // The feed moves on L1. The operator does nothing but keep trading: no pin, no new session.
  await l1.send(agg, "transmit", [answer(2100)], op);
  await headAtLeast(ex, h0 + 1n);
  const a2 = await order(alice, 0, parseEther("0.5"), usd(1050), 2n);
  const k2 = await order(bob, 1, usd(1050), parseEther("0.5"), 2n);
  await A.apply({ kind: "order", order: a2.o, sig: a2.sig });
  await A.apply({ kind: "order", order: k2.o, sig: k2.sig });
  check((await A.apply({ kind: "fill", a: a2.h, b: k2.h })).ok, "fill 2 at 2100 in the same batch: the executor followed L1, so the book saw the new round");
  const segs = await ex.read<any[]>(book, "segments", [BigInt(A.current.no)]);
  check(segs.length === 2 && segs[0].price === usd(2000) && segs[1].price === usd(2100) && Number(segs[1].firstFill) === 1,
    `the batch has 2 oracle segments: 2000 at L1 block ${segs[0].anchorBlock}, 2100 at ${segs[1].anchorBlock} (from fill 1)`);
  const acc = await ex.read<any>(book, "account", [0]);
  check(BigInt(acc.eth) === parseEther("1") && BigInt(acc.usd) === usd(2050), "app state carried across the segments: alice holds 1 ETH and 2050 USD");

  await A.seal();
  const p = await A.propose(BigInt(A.current.no), { label: "propose (2 segments)" });
  check((p.segments?.length ?? 0) === 2, "proposed with both segments' price witnesses: L1 verified each price at its own anchor");
  const ev = await l1.pub.getContractEvents({ address: ch.address, abi: ch.abi, eventName: "Segments", fromBlock: 0n }) as any[];
  const { firstFills, prices, anchorBlocks } = ev[ev.length - 1].args;
  for (const i of [0n, 1n]) {
    let fault = true;
    try { await l1.pub.simulateContract({ account: op, address: ch.address, abi: ch.abi, functionName: "challengeFill", args: [p.fills, i, firstFills, prices, anchorBlocks] }); } catch { fault = false; }
    check(!fault, `a watcher can't challenge fill ${i}: it's within the band of its own segment's price (${Number(prices[Number(i)]) / 1e6})`);
  }
  await l1.rpc("evm_increaseTime", [3601]);
  await l1.rpc("anvil_mine", [toHex(1)]);
  await l1.send(ch, "finalize", [], op);
  await A.finalized();
  check(Number((await l1.read<any[]>(ch, "state"))[3]) === 1, "and the batch finalized: one session, one batch, two oracle contexts, no L1 keep-alive");
  out.clearing = { segments: segs.map((g) => ({ anchorBlock: String(g.anchorBlock), price: String(g.price), firstFill: Number(g.firstFill) })), proposeGas: l1.gas["propose (2 segments)"] };
}

async function main() {
  const l1 = await Chain.anvil(18970, 900);
  chains.push(l1);
  try {
    await partA(l1);
    await partB(l1);
    mkdirSync(`${ROOT}docs/experiments/data`, { recursive: true });
    writeFileSync(`${ROOT}docs/experiments/data/subscription-anvil.json`, JSON.stringify(out, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
    console.log("E2E SUBSCRIPTION PASSED");
  } finally {
    chains.forEach((c) => c.stop());
  }
}

main().catch((e) => { console.error(e); process.exit(1); });

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
//    Regressions (review of 174ecfc): the feed moves after a batch opens but before its first
//    fill: one segment, starting at that fill, at the new price (#1). The executor moves on with
//    the same round: the next fill starts a segment at the new head that reuses the price (no
//    new witness), and an order that expired by that head is refused although the price is the
//    same (#2). L1 accepts both shapes.
// Run: npm run e2e-subscription  (needs anvil, forge build, cargo build -p channel-runner -p app-executor)
import { writeFileSync, mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { keccak256, pad, parseEther, toHex, zeroAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Chain } from "./runtime/executor.ts";
import { L1ReadView } from "./runtime/l1view.ts";
import { EvidenceStore } from "./runtime/evidence.ts";
import { watchProposal } from "./runtime/watcher.ts";
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
  const order = async (who: typeof alice, sellToken: number, sellAmount: bigint, buyAmount: bigint, nonce: bigint, expiry = 10n ** 9n) => {
    const o: Order = { trader: who.address, sellToken, sellAmount, buyAmount, nonce, expiry };
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
    `the batch has 2 segments: 2000 at L1 block ${segs[0].head}, 2100 at ${segs[1].head} (from fill 1)`);
  const acc = await ex.read<any>(book, "account", [0]);
  check(BigInt(acc.eth) === parseEther("1") && BigInt(acc.usd) === usd(2050), "app state carried across the segments: alice holds 1 ETH and 2050 USD");

  await A.seal();
  const p = await A.propose(BigInt(A.current.no), { label: "propose (2 segments)" });
  check((p.segments?.length ?? 0) === 2, "proposed with both segments' price witnesses: L1 verified each price at its own anchor");
  const ev = await l1.pub.getContractEvents({ address: ch.address, abi: ch.abi, eventName: "Segments", fromBlock: 0n }) as any[];
  const { firstFills, prices, heads } = ev[ev.length - 1].args;
  for (const i of [0n, 1n]) {
    let fault = true;
    try { await l1.pub.simulateContract({ account: op, address: ch.address, abi: ch.abi, functionName: "challengeFill", args: [p.fills, i, firstFills, prices, heads] }); } catch { fault = false; }
    check(!fault, `a watcher can't challenge fill ${i}: it's within the band of its own segment's price (${Number(prices[Number(i)]) / 1e6})`);
  }
  await l1.rpc("evm_increaseTime", [3601]);
  await l1.rpc("anvil_mine", [toHex(1)]);
  await l1.send(ch, "finalize", [], op);
  await A.finalized();
  check(Number((await l1.read<any[]>(ch, "state"))[3]) === 1, "and the batch finalized: one session, one batch, two oracle contexts, no L1 keep-alive");

  // #1: the feed moves after the batch opens, before its first fill.
  const b2 = await A.open();
  await l1.send(agg, "transmit", [answer(2200)], op);
  await headAtLeast(ex, await l1.height());
  const a3 = await order(alice, 0, parseEther("0.1"), usd(220), 3n);
  const k3 = await order(bob, 1, usd(220), parseEther("0.1"), 3n);
  await A.apply({ kind: "order", order: a3.o, sig: a3.sig });
  await A.apply({ kind: "order", order: k3.o, sig: k3.sig });
  check((await A.apply({ kind: "fill", a: a3.h, b: k3.h })).ok, "batch 2: the feed moved to 2200 after the batch opened; the first fill runs at 2200");
  let s2 = await ex.read<any[]>(book, "segments", [BigInt(A.current.no)]);
  check(s2.length === 1 && Number(s2[0].firstFill) === 0 && s2[0].price === usd(2200) && s2[0].head > b2.snap.number && s2[0].priceBlock === s2[0].head,
    `#1: one segment, from fill 0, at the head the fill ran at (${s2[0].head}; the batch opened at ${b2.snap.number}): no empty segment for the opening price`);

  // #2: the executor moves on, the round doesn't. An order that expired by the new head is refused.
  const h2 = BigInt(s2[0].head);
  await l1.rpc("anvil_mine", [toHex(1)]);
  await headAtLeast(ex, h2 + 1n);
  const a4 = await order(alice, 0, parseEther("0.1"), usd(220), 4n, h2); // last block: the previous head
  const k4 = await order(bob, 1, usd(220), parseEther("0.1"), 4n, h2);
  await A.apply({ kind: "order", order: a4.o, sig: a4.sig });
  await A.apply({ kind: "order", order: k4.o, sig: k4.sig });
  let why: any;
  try { await ex.pub.simulateContract({ account: op, address: book.address, abi: book.abi, functionName: "fill", args: [a4.h, k4.h] }); } catch (e: any) { why = e?.cause?.data; }
  check(why?.errorName === "Rejected" && Number(why.args[0]) === 6,
    `#2: an order whose last block was ${h2} is refused at the new head (Expired), although the round and price are unchanged`);
  const a5 = await order(alice, 0, parseEther("0.1"), usd(220), 4n);
  const k5 = await order(bob, 1, usd(220), parseEther("0.1"), 4n);
  await A.apply({ kind: "order", order: a5.o, sig: a5.sig });
  await A.apply({ kind: "order", order: k5.o, sig: k5.sig });
  check((await A.apply({ kind: "fill", a: a5.h, b: k5.h })).ok, "a live order fills at the new head");
  s2 = await ex.read<any[]>(book, "segments", [BigInt(A.current.no)]);
  check(s2.length === 2 && s2[1].head > h2 && s2[1].priceBlock === s2[0].priceBlock && s2[1].price === s2[0].price,
    `it starts segment 1 at head ${s2[1].head}, reusing the price read at block ${s2[1].priceBlock}`);
  await A.seal();
  const p2 = await A.propose(BigInt(A.current.no), { label: "propose (reused price)" });
  const ev2 = await l1.pub.getContractEvents({ address: ch.address, abi: ch.abi, eventName: "Segments", fromBlock: 0n }) as any[];
  const g2 = ev2[ev2.length - 1].args;
  check(g2.heads.length === 2 && g2.heads[1] === s2[1].head && (A.batch(BigInt(A.current.no))!.prepared as any).segments.filter((s: any) => s.witness).length === 1,
    "L1 accepted it: 2 segments, 1 price witness, and each fill's head is committed for disputes");
  for (const i of [0n, 1n]) {
    let fault = true;
    try { await l1.pub.simulateContract({ account: op, address: ch.address, abi: ch.abi, functionName: "challengeFill", args: [p2.fills, i, g2.firstFills, g2.prices, g2.heads] }); } catch { fault = false; }
    check(!fault, `and fill ${i} isn't challengeable`);
  }
  await l1.rpc("evm_increaseTime", [3601]);
  await l1.rpc("anvil_mine", [toHex(1)]);
  await l1.send(ch, "finalize", [], op);
  await A.finalized();

  // A reorg of a later segment's head, recovered inside the batch from that segment's checkpoint.
  await A.open();
  const a6 = await order(alice, 0, parseEther("0.1"), usd(220), 5n);
  const k6 = await order(bob, 1, usd(220), parseEther("0.1"), 5n);
  await A.apply({ kind: "order", order: a6.o, sig: a6.sig });
  await A.apply({ kind: "order", order: k6.o, sig: k6.sig });
  await A.apply({ kind: "fill", a: a6.h, b: k6.h });
  const hR = BigInt((await ex.rpc<any>("executor_status")).pin.number);
  await l1.rpc("anvil_mine", [toHex(1)]);
  await headAtLeast(ex, hR + 1n);
  const a7 = await order(alice, 0, parseEther("0.1"), usd(220), 6n);
  const k7 = await order(bob, 1, usd(220), parseEther("0.1"), 6n);
  await A.apply({ kind: "order", order: a7.o, sig: a7.sig });
  await A.apply({ kind: "order", order: k7.o, sig: k7.sig });
  await A.apply({ kind: "fill", a: a7.h, b: k7.h });
  const s3 = await ex.read<any[]>(book, "segments", [BigInt(A.current.no)]);
  const no3 = A.current.no;
  await l1.rpc("anvil_reorg", [1, []]); // replaces segment 1's block
  await l1.rpc("anvil_mine", [toHex(1)]);
  const r3 = await A.tick();
  const s3b = await ex.read<any[]>(book, "segments", [BigInt(A.current.no)]);
  check(r3.status === "recovered" && r3.segment === 1 && A.current.no === no3 && r3.replayed.length === 1 && A.current.log.length === 6,
    `segment 1's block (${s3[1].head}) reorged out: recovered inside batch ${no3} from its checkpoint: only the fill that started it is replayed; the orders before it and segment 0 are kept`);
  check(s3b.length === 2 && s3b[0].hash === s3[0].hash && s3b[1].hash !== s3[1].hash,
    `the batch now has segment 0 unchanged and segment 1 at the new canonical block ${s3b[1].head}`);
  await A.seal();
  await A.propose(BigInt(A.current.no), { label: "propose (after an in-batch recovery)" });
  check((await l1.read<any>(ch, "pending")).at > 0n, "and L1 accepts the batch");
  await l1.rpc("evm_increaseTime", [3601]);
  await l1.rpc("anvil_mine", [toHex(1)]);
  await l1.send(ch, "finalize", [], op);
  await A.finalized();

  // Partial fills: alice's one order (sell 0.3 ETH, limit 2190 per ETH) filled 0.1 then 0.2.
  await A.open();
  const a8 = await order(alice, 0, parseEther("0.3"), usd(657), 7n);
  const k8 = await order(bob, 1, usd(220), parseEther("0.1"), 7n);
  const k9 = await order(bob, 1, usd(440), parseEther("0.2"), 8n);
  for (const x of [a8, k8, k9]) await A.apply({ kind: "order", order: x.o, sig: x.sig });
  check((await A.apply({ kind: "fill", a: a8.h, b: k8.h, eth: parseEther("0.1"), usd: usd(220) })).ok, "a partial fill: 0.1 of alice's 0.3 ETH, at 2200");
  const mid = await ex.read<any>(book, "account", [0]);
  check(await ex.read<boolean>(book, "resting", [a8.h]) && BigInt(mid.filled) === parseEther("0.1"),
    "alice's order rests on, 0.1 ETH filled (her account's `filled`)");
  check(!(await A.apply({ kind: "fill", a: a8.h, b: k9.h, eth: parseEther("0.25"), usd: usd(550) })).ok, "a fill past what's left (0.25 of the remaining 0.2) is refused");
  check((await A.apply({ kind: "fill", a: a8.h, b: k9.h, eth: parseEther("0.2"), usd: usd(440) })).ok, "the remaining 0.2 fills with bob's next order");
  const done = await ex.read<any>(book, "account", [0]);
  check(!(await ex.read<boolean>(book, "resting", [a8.h])) && BigInt(done.filled) === 0n, "alice's order is complete: out of the book, `filled` back to 0");
  await A.seal();
  const before3 = Number((await l1.read<any[]>(ch, "state"))[3]);
  const p3 = await A.propose(BigInt(A.current.no), { label: "propose (partial fills)" });
  const w3 = await watchProposal({ l1, channel: ch, view: A.view, feed, from: op.address, fin: A.fin, next: p3.next, fills: p3.fills });
  check(w3.faults.length === 0, `L1 takes both partial fills: the watcher tried ${w3.checked.accounts} accounts and ${w3.checked.fills} fills, nothing to challenge`);
  await l1.rpc("evm_increaseTime", [3601]);
  await l1.rpc("anvil_mine", [toHex(1)]);
  await l1.send(ch, "finalize", [], op);
  await A.finalized();
  check(Number((await l1.read<any[]>(ch, "state"))[3]) === before3 + 1, "and the batch finalized");

  out.clearing = {
    segments: segs.map((g) => ({ head: String(g.head), priceBlock: String(g.priceBlock), price: String(g.price), firstFill: Number(g.firstFill) })),
    proposeGas: l1.gas["propose (2 segments)"], reusedPriceProposeGas: l1.gas["propose (reused price)"],
  };
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

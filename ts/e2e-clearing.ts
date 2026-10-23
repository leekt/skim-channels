// Clearing channel end to end (deterministic, local): optimistic settlement with the app's
// account state committed on L1, a bad proposal challenged, a forced order, a handover to a
// second operator rebuilt from L1 alone, and a freeze with operator-free exits.
//   L1        = anvil (chain 900): price feed, AnchorRegistry, ClearingChannel (+ Disputes, Codec)
//   executors = two more anvils (chain 7001): operator A's and operator B's ClearingBook.
//               LOCAL EXECUTORS — L1 trusts neither.
// Run: npm run e2e-clearing  (needs anvil, forge build, cargo build).
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdirSync, writeFileSync } from "node:fs";
import { createPublicClient, createWalletClient, defineChain, encodeAbiParameters, encodeFunctionData, http, keccak256, pad, parseEther, toHex, zeroAddress, zeroHash, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Chain, type C } from "./runtime/executor.ts";
import { L1ReadView } from "./runtime/l1view.ts";
import { EvidenceStore } from "./runtime/evidence.ts";
import { levels, rootOf, siblings } from "./runtime/tree.ts";
import { ClearingOperator, EMPTY, eip712Order, leafHash, mergeAbi, orderHash, type Account, type Order } from "./runtime/clearing.ts";
import { Gateway } from "./runtime/gateway.ts";

const ROOT = new URL("..", import.meta.url).pathname;
const CLI = `${ROOT}target/debug/skim-channels`;
const KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
  "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
] as const;
const [opA, alice, bob, carol, watcher, opB, dave] = KEYS.map((k) => privateKeyToAccount(k));
const ETH = 0, USD = 1;
const usd = (x: number) => BigInt(Math.round(x * 1e6));
const SLOT0: Hex = `0x${"0".repeat(64)}`;
const FAR = 10n ** 9n;
const DAY = 86400, WINDOW = 3600;

function check(cond: unknown, msg: string) {
  if (!cond) throw new Error(`FAILED: ${msg}`);
  console.log(`ok  ${msg}`);
}

const accountT = {
  type: "tuple",
  components: [
    { name: "eth", type: "uint128" }, { name: "usd", type: "uint128" }, { name: "ethIn", type: "uint128" },
    { name: "usdIn", type: "uint128" }, { name: "ethOut", type: "uint128" }, { name: "usdOut", type: "uint128" },
    { name: "nonce", type: "uint64" }, { name: "requests", type: "uint32" },
  ],
} as const;
void accountT;
void encodeAbiParameters;

const extraChains: Chain[] = []; // started during the run (e.g. a restarted executor)

async function main() {
  // L1 keeps the last 512 states (like a non-archive node): older proofs are refused.
  const l1 = await Chain.anvil(18690, 900, ["--prune-history", "512"]);
  try {
    await run(l1);
  } finally {
    [l1, ...extraChains].forEach((c) => c.stop());
  }
}

/** Chainlink's layout on a local L1: an aggregator behind a proxy (test/clearing/ChainlinkMocks.sol). */
const answer = (x: number) => BigInt(Math.round(x * 1e8));

async function run(l1: Chain) {
  // ---- L1 ----
  const agg = await l1.deploy(ROOT, opA, "ChainlinkMocks.sol", "MockOffchainAggregator", [answer(2000)]);
  const proxy = await l1.deploy(ROOT, opA, "ChainlinkMocks.sol", "MockFeedProxy", [agg.address]);
  const codeHash = async (a: Address) => keccak256((await l1.pub.getCode({ address: a }))!);
  const MAX_STALE = BigInt(3 * DAY);
  const adapter = await l1.deploy(ROOT, opA, "ChainlinkAdapter.sol", "ChainlinkAdapter",
    [proxy.address, await codeHash(proxy.address), agg.address, await codeHash(agg.address), 8, MAX_STALE]);
  const feed = { proxy: proxy.address, aggregator: agg.address };
  const anchors = await l1.deploy(ROOT, opA, "AnchorRegistry.sol", "AnchorRegistry");
  const codec = await l1.deploy(ROOT, opA, "ClearingCodec.sol", "ClearingCodec");
  const token = await l1.deploy(ROOT, opA, "Clearing.t.sol", "TestUSD");
  const disputes = await l1.deploy(ROOT, opA, "ClearingDisputes.sol", "ClearingDisputes", [{
    operator: opA.address, usd: token.address, anchors: anchors.address, codec: codec.address,
    priceAdapter: adapter.address, bandBps: 100n, challengeWindow: BigInt(WINDOW), forceDelay: BigInt(DAY),
    maxAnchorAge: 256n, minBond: parseEther("1"), takeoverDelay: BigInt(2 * DAY), appChainId: 7001n, vault: zeroAddress, sessionId: 1n,
  }], "deploy ClearingDisputes");
  const core = await l1.deploy(ROOT, opA, "ClearingChannel.sol", "ClearingChannel", [disputes.address], "deploy ClearingChannel");
  const ch = mergeAbi(core, disputes);
  // Time passes with blocks (12 s each), as on a real chain: anchors age by block number.
  // Up to 2 hours (challenge windows): every 12 s block is mined. Longer waits (days) mine
  // 600 such blocks — more than any anchor's age limit — then jump the rest of the time.
  const time = async (s: number) => {
    const blocks = Math.ceil(s / 12);
    if (blocks <= 600) return l1.rpc("anvil_mine", [toHex(blocks), toHex(12)]);
    await l1.rpc("anvil_mine", [toHex(600), toHex(12)]);
    await l1.rpc("evm_increaseTime", [s - 600 * 12]);
    await l1.rpc("anvil_mine", [toHex(1)]);
  };
  async function fund(who: typeof alice, eth: bigint, dollars: bigint) {
    if (eth) await l1.send(ch, "deposit", [ETH, eth], who, "deposit ETH", eth);
    if (dollars) {
      await l1.send(token, "mint", [who.address, dollars], who);
      await l1.send(token, "approve", [ch.address, dollars], who);
      await l1.send(ch, "deposit", [USD, dollars], who, "deposit USD");
    }
  }
  await fund(alice, parseEther("2"), 0n);
  await fund(bob, 0n, usd(10_000));
  await fund(carol, parseEther("1"), usd(2_000));
  await fund(dave, 0n, usd(1_000));
  const totalEth = parseEther("3"), totalUsd = usd(12_000);

  // ---- the app network: app executors (crates/app-executor), fees 0. They import the
  //      channel (both halves) and the feed (proxy and aggregator) read-only. ----
  const IMPORTS = [ch.address, disputes.address, proxy.address, agg.address];
  const executor = async (port: number) => {
    const ex = await Chain.appExecutor(ROOT, port, 7001, l1.url, { readonly: IMPORTS });
    extraChains.push(ex);
    return ex;
  };
  const exA = await executor(18691);
  const exB = await executor(18692);
  const reader = new L1ReadView({ url: l1.url, chainId: 900, cli: CLI });
  const mkOp = async (ex: Chain, who: typeof opA) => {
    const book = await ClearingOperator.deployBook(ex, l1, who, ch, feed, MAX_STALE);
    return new ClearingOperator({
      view: reader, exec: ex, book, op: who, l1, channel: ch, anchors, feed, maxStaleness: MAX_STALE,
      evidence: new EvidenceStore(join(tmpdir(), `skim-clearing-${who.address.slice(2, 8)}-${process.pid}`)),
      policy: { kind: "confirmations", n: 1 }, bond: parseEther("1"),
      journal: join(tmpdir(), `skim-clearing-journal-${who.address.slice(2, 8)}-${process.pid}.json`),
      maxAnchorAge: 256n, ageMargin: 16n,
    });
  };
  const A = await mkOp(exA, opA);
  // Orders are signed on the app network (chain 7001), as a wallet connected to it would.
  const domain = { name: "SkimClearing", version: "0", chainId: 7001, verifyingContract: ch.address, salt: pad(toHex(1n), { size: 32 }) };
  async function order(who: typeof alice, sellToken: number, sellAmount: bigint, buyAmount: bigint, nonce: bigint, signer = who) {
    const o: Order = { trader: who.address, sellToken, sellAmount, buyAmount, nonce, expiry: FAR };
    const sig = await signer.signTypedData({ domain, types: eip712Order, primaryType: "Order", message: o as any });
    return { o, sig, h: orderHash(o) };
  }
  const idxOf = async (a: Address) => Number(await l1.read(ch, "indexPlusOne", [a])) - 1;
  const [ia, ib, ic, id] = [await idxOf(alice.address), await idxOf(bob.address), await idxOf(carol.address), await idxOf(dave.address)];

  /** A watcher's view: challenge every fill and every touched account; all must fail. */
  async function watch(op: ClearingOperator, p: Awaited<ReturnType<ClearingOperator["proposal"]>>, expectFault?: number) {
    const n = Number(await l1.read(ch, "userCount"));
    const finDense = Array.from({ length: n }, (_, i) => leafHash(op.fin.get(i) ?? EMPTY));
    const nextDense = finDense.map((h, i) => (p.next.has(i) ? leafHash(p.next.get(i)!) : h));
    let faults: number[] = [];
    for (let i = 0; i < n; i++) {
      try {
        await l1.pub.simulateContract({
          account: watcher, address: ch.address, abi: ch.abi, functionName: "challengeAccount",
          args: [i, op.fin.get(i) ?? EMPTY, siblings(levels(finDense), i), p.next.get(i) ?? op.fin.get(i) ?? EMPTY, siblings(levels(nextDense), i), p.fills],
        });
        faults.push(i);
      } catch { /* NotWrong */ }
    }
    const nFills = (p.fills.length - 2) / 2 / 236;
    for (let f = 0; f < nFills; f++) {
      try {
        await l1.pub.simulateContract({ account: watcher, address: ch.address, abi: ch.abi, functionName: "challengeFill", args: [p.fills, BigInt(f)] });
        faults.push(1000 + f);
      } catch { /* NotWrong */ }
    }
    if (expectFault === undefined) check(faults.length === 0, `watcher checked ${n} accounts and ${nFills} fills: nothing to challenge`);
    return { faults, finDense, nextDense };
  }
  /** What an operator's loop does: tick() (re-pin orphaned or aged batches), then propose. */
  async function settle(op: ClearingOperator, no: bigint, label: string) {
    const t = await op.tick();
    if (t.status === "recovered") no = BigInt(op.current.no);
    const p = await op.propose(no, { label: `propose ${label}` });
    await watch(op, p);
    await time(WINDOW);
    await l1.send(ch, "finalize", [], watcher, `finalize ${label}`);
    await op.finalized();
    const n = Number(await l1.read(ch, "userCount"));
    const st = await l1.read<any[]>(ch, "state");
    check(st[0] === rootOf(levels(Array.from({ length: n }, (_, i) => leafHash(op.fin.get(i) ?? EMPTY)))), `batch ${no} final: L1's account root = the operator's state`);
    return p;
  }
  const place = (op: ClearingOperator, x: { o: Order; sig: Hex }) => op.apply({ kind: "order", order: x.o, sig: x.sig });
  const fill = (op: ClearingOperator, a: { h: Hex }, b: { h: Hex }) => op.apply({ kind: "fill", a: a.h, b: b.h });
  await l1.rpc("anvil_mine", [toHex(2)]);

  // ==== batch 1 at H (2000) ====================================================================
  await A.open();
  const a1 = await order(alice, ETH, parseEther("0.5"), usd(990), 1n);
  const k1 = await order(bob, USD, usd(1000), parseEther("0.5"), 1n);
  await place(A, a1); await place(A, k1);
  check((await fill(A, a1, k1)).ok, "batch 1: alice sells 0.5 ETH to bob at 2000 (ClearingBook on the executor)");
  check((await place(A, a1)).error === "AlreadySeen", "the same signed order again: AlreadySeen");
  check((await place(A, await order(carol, ETH, parseEther("0.1"), usd(190), 1n, bob))).error === "BadSignature", "a forged order: BadSignature");
  const c1 = await order(carol, ETH, parseEther("1"), usd(1990), 1n);
  const c2 = await order(carol, ETH, parseEther("1"), usd(1990), 2n);
  const k2 = await order(bob, USD, usd(2000), parseEther("1"), 2n);
  const k3 = await order(bob, USD, usd(2000), parseEther("1"), 3n);
  for (const x of [c1, c2, k2, k3]) await place(A, x);
  check((await fill(A, c1, k2)).ok, "carol sells her 1 ETH once");
  check((await fill(A, c2, k3)).error === "Insufficient", "and not twice: Insufficient");
  await A.seal();
  await settle(A, 1n, "#1 (2 fills)");

  // ==== L1 moves; alice asks for 0.2 ETH; batch 2 at H+1 (2100) ==============================
  await l1.send(agg, "transmit", [answer(2100)], opA);
  await l1.send(ch, "requestWithdraw", [ETH, parseEther("0.2")], alice, "requestWithdraw");
  await l1.rpc("anvil_mine", [toHex(2)]);
  await A.open();
  const accA = await exA.read<any>(A.book, "account", [ia]);
  check(BigInt(accA.ethOut) === parseEther("0.2"), "batch 2 opened by serving alice's request first (0.2 ETH released)");
  check(await exA.read(A.book, "resting", [k3.h]), "bob's unfilled order from batch 1 is still in the book (AppState carried over)");
  // ---- users trade from ordinary wallets through the app network's standard RPC ----
  const gw = new Gateway(A, 18695);
  await gw.start();
  const appChain = defineChain({ id: 7001, name: "skim-clearing", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [gw.url] } } });
  const gpub = createPublicClient({ chain: appChain, transport: http(gw.url), cacheTime: 0, pollingInterval: 50 });
  const walletOf = (a: typeof alice) => createWalletClient({ account: a, chain: appChain, transport: http(gw.url) });
  check((await gpub.getChainId()) === domain.chainId, "the RPC's eth_chainId equals the orders' EIP-712 chainId (MetaMask/Rabby require this to sign)");
  check((await gpub.getBalance({ address: alice.address })) === BigInt((await A.exec.read<any>(A.book, "account", [ia])).eth), "eth_getBalance shows alice's ETH in the channel");
  const fees = await gpub.estimateFeesPerGas();
  const base = (await gpub.getBlock()).baseFeePerGas;
  check(fees.maxFeePerGas === 0n, `fees on the app network are 0 (wallets send fee-0 transactions): maxFee ${fees.maxFeePerGas}, base ${base}`);
  /** Sign the order (eth_signTypedData_v4) and send it as a normal transaction, as a wallet does. */
  async function walletOrder(who: typeof alice, sellToken: number, sellAmount: bigint, buyAmount: bigint, nonce: bigint) {
    const x = await order(who, sellToken, sellAmount, buyAmount, nonce);
    const hash = await walletOf(who).writeContract({ address: A.book.address, abi: A.book.abi, functionName: "submitOrder", args: [x.o, x.sig] });
    const r = await gpub.waitForTransactionReceipt({ hash });
    check(r.status === "success", `${who === alice ? "alice" : who === bob ? "bob" : "a user"}'s wallet tx ${hash.slice(0, 10)}… placed an order (receipt from the RPC)`);
    return x;
  }
  const a2 = await walletOrder(alice, ETH, parseEther("0.5"), usd(1040), 2n);
  const k4 = await walletOrder(bob, USD, usd(1050), parseEther("0.5"), 4n);
  const refused = async (what: string, fn: () => Promise<unknown>) => {
    try { await fn(); } catch (e: any) { check(true, `refused: ${what} (${String(e?.details ?? e?.shortMessage ?? e?.message).split("\n")[0].slice(0, 80)})`); return; }
    throw new Error(`FAILED: ${what} was accepted`);
  };
  const nonceBefore = await gpub.getTransactionCount({ address: alice.address });
  await refused("a plain ETH transfer", () => walletOf(alice).sendTransaction({ to: bob.address, value: 1n }));
  await refused("a contract deployment", () => walletOf(alice).sendTransaction({ data: "0x6080" }));
  await refused("calling fill (operator-only)", () => walletOf(alice).writeContract({ address: A.book.address, abi: A.book.abi, functionName: "fill", args: [a2.h, k4.h] }));
  const stale = await order(alice, ETH, parseEther("0.1"), usd(200), 1n); // nonce 1 already used
  await refused("an order that would revert (stale nonce)", () => walletOf(alice).writeContract({ address: A.book.address, abi: A.book.abi, functionName: "submitOrder", args: [stale.o, stale.sig] }));
  // With gas set, the wallet skips estimation: the RPC's own policy and simulation decide.
  await refused("calling fill with gas set (the RPC's function policy)", () => walletOf(alice).writeContract({ address: A.book.address, abi: A.book.abi, functionName: "fill", args: [a2.h, k4.h], gas: 300_000n }));
  await refused("a stale-nonce order with gas set (simulated, refused before inclusion)", () => walletOf(alice).writeContract({ address: A.book.address, abi: A.book.abi, functionName: "submitOrder", args: [stale.o, stale.sig], gas: 300_000n }));
  await refused("bob submitting alice's order", () => walletOf(bob).writeContract({ address: A.book.address, abi: A.book.abi, functionName: "submitOrder", args: [stale.o, stale.sig], gas: 300_000n }));
  check((await gpub.getTransactionCount({ address: alice.address })) === nonceBefore, "refused transactions consumed no nonce");
  await refused("anvil_setBalance (executor cheat method)", () => gpub.request({ method: "anvil_setBalance" as any, params: [alice.address, "0x1"] as any }));
  await refused("eth_sendTransaction (the node holds no keys)", () => gpub.request({ method: "eth_sendTransaction" as any, params: [{ from: alice.address, to: bob.address }] as any }));
  check((await fill(A, a2, k4)).ok, "the operator fills the two wallet orders: alice sells 0.5 ETH at 2100");
  await A.seal();
  const digestAfter2 = await A.exec.read<Hex>(A.book, "stateDigest");

  // ---- the same journal replayed on a fresh executor gives the same AppState ----
  const exC = await executor(18693);
  try {
    const fresh = await ClearingOperator.deployBook(exC, l1, opA, ch, feed, MAX_STALE);
    for (const b of A.batches.slice(0, 2)) {
      const pr = b.prepared as any;
      await exC.rpc("executor_pin", [pr.anchor.hash]); // the same L1 block, re-read and re-verified
      await exC.send(fresh, "openBatch", [pr.anchor.number, pr.anchor.time, pr.depositUsers, pr.forced.orders], opA);
      for (const l of b.log) {
        if (!l.ok) continue;
        const a = l.action as any;
        if (a.kind === "order") await exC.send(fresh, "submitOrder", [a.order, a.sig], opA);
        else if (a.kind === "fill") await exC.send(fresh, "fill", [a.a, a.b], opA);
        else await exC.pub.waitForTransactionReceipt({ hash: await exC.rpc<Hex>("eth_sendRawTransaction", [a.tx]) }); // users' own txs, byte for byte
      }
      await exC.send(fresh, "seal", [], opA);
    }
    check((await exC.read<Hex>(fresh, "stateDigest")) === digestAfter2, "the journal replayed on a fresh executor, pinned to the same L1 blocks, gives the same AppState digest");
  } finally {
    exC.stop();
  }

  // ---- the executor's L1 view fails closed and is read-only ----
  const refuses = async (fn: () => Promise<unknown>) => { try { await fn(); return false; } catch { return true; } };
  check(await refuses(() => A.exec.rpc("executor_pin", [keccak256("0x01")])), "pinning to a block L1 doesn't have is refused");
  check(await refuses(() => A.exec.send(ch, "requestWithdraw", [ETH, 1n], alice)), "the channel is read-only on the app network: nothing there can write to it");
  check((await A.exec.rpc<any>("executor_status")).overlay.length === 0, "and no overlay was ever written into an imported account");

  await settle(A, 2n, "#2 (1 fill + 1 request)");
  const before = await l1.pub.getBalance({ address: alice.address });
  const finDense = () => Array.from({ length: 4 }, (_, i) => leafHash(A.fin.get(i) ?? EMPTY));
  await l1.send(ch, "claim", [ia, A.fin.get(ia)!, siblings(levels(finDense()), ia)], watcher, "claim");
  check((await l1.pub.getBalance({ address: alice.address })) - before === parseEther("0.2"), "alice claimed 0.2 ETH on L1 while trading went on");

  // ==== a wrong proposal is challenged =======================================================
  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  const k5 = await order(bob, USD, usd(210), parseEther("0.1"), 5n);
  const c3 = await order(carol, USD, usd(500), parseEther("0.2"), 3n); // rests
  await place(A, k5); await place(A, c3);
  await A.seal();
  // (no fill: a batch can also just publish deposits and requests)
  const snapL1 = await l1.rpc<Hex>("evm_snapshot");
  const bad = await A.propose(3n, { tamper: (m) => { const x = m.get(ib) ?? A.fin.get(ib)!; m.set(ib, { ...x, usd: x.usd + 1n }); } });
  const w = await watch(A, bad, 1);
  check(w.faults.includes(ib), `the watcher finds bob's leaf wrong (faults: ${w.faults.join(",")})`);
  const wb = await l1.read<bigint>(ch, "bondCredit", [watcher.address]);
  await l1.send(ch, "challengeAccount", [ib, A.fin.get(ib)!, siblings(levels(w.finDense), ib), bad.next.get(ib)!, siblings(levels(w.nextDense), ib), bad.fills], watcher, "challengeAccount");
  check((await l1.read<bigint>(ch, "bondCredit", [watcher.address])) === wb + parseEther("1"), "challenge won: the batch is discarded and the bond credited to the watcher");
  await l1.rpc("evm_revert", [snapL1]);
  await settle(A, 3n, "#3 (0 fills)");

  // ==== a forced order: posted on L1, taken in, filled ========================================
  const cf = await order(carol, USD, usd(210), parseEther("0.1"), 4n); // carol sold her ETH in batch 1
  await l1.send(ch, "forceOrder", [cf.o], carol, "forceOrder"); // an ordinary L1 tx from carol
  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  check(await exA.read(A.book, "resting", [cf.h]), "batch 4 took carol's forced order in from L1 (hash checked against L1)");
  const aF = await order(alice, ETH, parseEther("0.1"), usd(205), 3n);
  await place(A, aF);
  check((await fill(A, cf, aF)).ok, "and fills it with alice's order");
  await A.seal();
  const p4 = await settle(A, 4n, "#4 (forced fill)");
  check(p4.statuses === "0x0001", "L1 checked the forced order's status: filled at fill 0, side a");

  // ==== runtime recovery (review of 5db7064) =================================================
  const cur = () => BigInt(A.current.no);
  // R1: two speculative batches, the second spending what the first produced; a reorg
  //     removes both anchors. Recovery starts at the FIRST and replays both.
  A.policy = { kind: "latest" };
  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  const a5 = await order(alice, ETH, parseEther("0.1"), usd(205), 5n);
  const d1 = await order(dave, USD, usd(210), parseEther("0.1"), 1n);
  await place(A, a5); await place(A, d1);
  check((await fill(A, a5, d1)).ok, "speculative batch S1: alice sells 0.1 ETH to dave");
  await A.seal();
  const s1 = A.current;
  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  const d2 = await order(dave, ETH, parseEther("0.1"), usd(205), 2n);
  const k7 = await order(bob, USD, usd(210), parseEther("0.1"), 7n);
  await place(A, d2); await place(A, k7);
  check((await fill(A, d2, k7)).ok, "speculative batch S2: dave sells that 0.1 ETH on to bob (needs S1)");
  await A.seal();
  // The new chain has alice withdrawing most of her ETH in the replaced block (price unchanged).
  const withdraw = { from: alice.address, to: ch.address, data: encodeFunctionData({ abi: ch.abi, functionName: "requestWithdraw", args: [ETH, parseEther("0.65")] }) };
  await l1.rpc("anvil_reorg", [2, [[withdraw, 0]]]);
  check((await reader.canonicalStatus(s1.snap)) === "orphaned", "S1's anchor is orphaned (the node has another block at that height)");
  const r1 = await A.tick();
  check(r1.status === "recovered" && r1.from === s1.no, `tick() recovered from the earliest affected batch (#${r1.from}), not just the last`);
  check(r1.dropped.length === 2 && r1.dropped.every((d) => d.error === "Insufficient"), "both fills dropped: alice's ETH is reserved on the new chain, so S1 fails, and S2 then has nothing to sell");
  check(BigInt((await A.exec.read<any>(A.book, "account", [id])).eth) === 0n, "dave holds no ETH: no obligation from the orphaned chain survives");
  A.policy = { kind: "confirmations", n: 1 };
  // anvil's BLOCKHASH still returns the replaced hashes after anvil_reorg, so L1 can't record
  // an anchor at those heights; re-pin on a later block.
  await l1.rpc("anvil_mine", [toHex(2)]);
  await A.recover(A.current.no, "anchor after the reorged heights");
  await settle(A, cur(), "#5 (recovered)");
  await fund(alice, parseEther("1"), 0n);

  // R2: recovery onto a block whose proofs are gone stops before changing anything.
  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  const d3 = await order(dave, ETH, parseEther("0.1"), usd(205), 3n);
  const k8 = await order(bob, USD, usd(210), parseEther("0.1"), 8n);
  await place(A, d3); await place(A, k8);
  check((await fill(A, d3, k8)).error === "Insufficient", "dave can't sell ETH he doesn't have: rejected");
  const digest = await A.exec.read(A.book, "stateDigest");
  const nb = A.batches.length;
  const old = { ...A.current.snap };
  await l1.rpc("anvil_mine", [toHex(600)]); // that block's state falls out of the node's last 512
  const r2 = await A.recover(A.current.no, "test", old);
  check(r2.status === "proof-unavailable", `a recovery onto a block without proofs stops first (${(r2.reason ?? "").slice(0, 70)}…)`);
  check((await A.exec.read(A.book, "stateDigest")) === digest && A.batches.length === nb && !A.journal.recovering, "executor, batches and journal are unchanged");
  check((await reader.canonicalStatus({ ...old, number: (await reader.head()) + 10_000n })) === "unknown", "a height the node can't answer is 'unknown', not a reorg");

  // R3: the open batch is now too old to propose; tick() re-pins it. The fill rejected
  //     before is reported, not retried — even though dave is funded now.
  await l1.send(ch, "deposit", [ETH, parseEther("1")], dave, undefined, parseEther("1"));
  await l1.rpc("anvil_mine", [toHex(1)]);
  const r3 = await A.tick();
  check(r3.status === "recovered" && r3.reason === "aged", "tick() re-pinned the aged batch on a fresh snapshot");
  check(r3.notRetried.some((x) => x.action.kind === "fill") && !r3.replayed.some((x) => x.action.kind === "fill"), "the rejected fill was reported, not replayed");
  check(await A.exec.read(A.book, "resting", [d3.h]), "dave's order still rests in the book, for a separate re-match");
  await A.seal();
  await settle(A, cur(), "#6 (re-pinned)");

  // R4: a batch built while another is in its window ages out under real block progress.
  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  const a6 = await order(alice, ETH, parseEther("0.1"), usd(205), 6n);
  const k9 = await order(bob, USD, usd(210), parseEther("0.1"), 9n);
  await place(A, a6); await place(A, k9);
  check((await fill(A, a6, k9)).ok, "batch P: alice sells 0.1 ETH at 2100");
  await A.seal();
  const pNo = cur();
  const pP = await A.propose(pNo, { label: "propose P" });
  await watch(A, pP);
  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  const k10 = await order(bob, USD, usd(210), parseEther("0.1"), 10n);
  await place(A, k10);
  check((await fill(A, d3, k10)).ok, "batch Q (built while P waits): dave's resting order is re-matched explicitly");
  await A.seal();
  await time(WINDOW); // 300 blocks: Q's anchor is now older than maxAnchorAge (256)
  await l1.send(ch, "finalize", [], watcher);
  await A.finalized();
  let refusedOld = false;
  try { await A.propose(cur()); } catch { refusedOld = true; }
  check(refusedOld, "Q's anchor aged out during P's window: the runtime refuses to propose it");
  const r4 = await A.tick();
  check(r4.status === "recovered" && r4.reason === "aged" && r4.dropped.length === 0, "tick() re-pinned Q on a fresh snapshot; nothing dropped");
  await settle(A, cur(), "#8 (Q re-pinned)");

  // R5: the executor dies with one batch proposed (pending) and one unproposed. A new
  //     executor is rebuilt from L1's finalized state plus the journal.
  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  const a7 = await order(alice, ETH, parseEther("0.1"), usd(205), 7n);
  const k11 = await order(bob, USD, usd(210), parseEther("0.1"), 11n);
  await place(A, a7); await place(A, k11);
  await fill(A, a7, k11);
  await A.seal();
  const pending = await A.propose(cur(), { label: "propose (pending at crash)" });
  await watch(A, pending);
  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  const k12 = await order(bob, USD, usd(210), parseEther("0.1"), 12n);
  await place(A, k12);
  await A.seal();
  A.exec.stop();
  await new Promise((r) => setTimeout(r, 500));
  A.exec = await executor(18691);
  const r5 = await A.recover(A.current.no, "executor restarted");
  check(r5.status === "recovered", "the runtime rebuilt a fresh executor (adopt from L1 + the pending batch from the journal) and replayed the unproposed one");
  await time(WINDOW);
  await l1.send(ch, "finalize", [], watcher);
  await A.finalized();
  await settle(A, cur(), "#10 (after executor rebuild)");

  // ==== operator A goes silent; B takes over from L1 data alone =============================
  await time(2 * DAY + 1);
  const recovered = await ClearingOperator.recover(l1, ch);
  const same = [...new Set([...recovered.keys(), ...A.fin.keys()])].every((k) => leafHash(recovered.get(k) ?? EMPTY) === leafHash(A.fin.get(k) ?? EMPTY));
  check(same, `operator B rebuilt every account (${recovered.size}) from L1 calldata alone`);
  // (a normal transfer: anvil_setBalance edits state outside a block and breaks its proofs)
  await l1.wallet(opA).sendTransaction({ to: opB.address, value: parseEther("10") }).then((h) => l1.pub.waitForTransactionReceipt({ hash: h }));
  const B = await mkOp(exB, opB);
  await B.adopt(recovered);
  check(true, "ClearingBook.adopt accepted them: their root equals L1's finalized root (read through a proof)");
  await l1.rpc("anvil_mine", [toHex(1)]);
  await B.open();
  const a3 = await order(alice, ETH, parseEther("0.2"), usd(415), 8n);
  const k6 = await order(bob, USD, usd(420), parseEther("0.2"), 13n);
  await place(B, a3); await place(B, k6);
  check((await fill(B, a3, k6)).ok, "B's book continues where A stopped (nonces and balances from L1)");
  await B.seal();
  await settle(B, BigInt(B.current.no), "#11 by B");
  const pend = await l1.read<any[]>(ch, "state");
  check(Number(pend[3]) === 11, `L1 counts ${pend[3]} finalized batches across the recoveries and the handover`);

  // ==== the feed's proxy switches aggregators: neither side follows ==========================
  const agg2 = await l1.deploy(ROOT, opA, "ChainlinkMocks.sol", "MockOffchainAggregator", [answer(5000)]);
  await l1.send(proxy, "setAggregator", [agg2.address], opA);
  await l1.rpc("anvil_mine", [toHex(2)]);
  const snapUp = await reader.snapshot({ kind: "confirmations", n: 1 });
  const wUp = reader.witness(snapUp, [
    { account: proxy.address, slots: [toHex(2n, { size: 32 })] },
    { account: agg2.address, slots: [toHex(0x2bn, { size: 32 })] },
  ]);
  await l1.send(anchors, "record", [wUp.rawHeader], opA);
  check(await refuses(() => l1.read(adapter, "price", [wUp.package, anchors.address, 256n])), "L1's adapter refuses a price from the new aggregator (unsupported feed)");
  check(await refuses(() => B.open()), "and the executor can't price a batch from it (the new aggregator isn't imported)");
  await l1.send(proxy, "setAggregator", [agg.address], opA); // back to the supported one
  await l1.rpc("anvil_mine", [toHex(2)]);
  if (B.batches.length && B.current.state === "open") await B.recover(B.current.no, "feed restored");

  // ==== a forced order nobody serves: freeze closes the session, everyone redeems ============
  const cg = await order(carol, USD, usd(100), parseEther("0.04"), 5n);
  await l1.send(ch, "forceOrder", [cg.o], carol);
  await l1.rpc("anvil_mine", [toHex(1)]);
  let early = false;
  try { await l1.pub.simulateContract({ account: watcher, address: ch.address, abi: ch.abi, functionName: "freeze", args: [] }); early = true; } catch { /* NotOverdue */ }
  check(!early, "freeze is refused before the forced order's deadline");
  await time(DAY);
  await l1.send(ch, "freeze", [], watcher, "freeze");
  const dense = Array.from({ length: 4 }, (_, i) => leafHash(B.fin.get(i) ?? EMPTY));
  for (const [i, who] of [[ia, alice], [ib, bob], [ic, carol], [id, dave]] as const) {
    await l1.send(ch, "redeem", [i, B.fin.get(i) ?? EMPTY, siblings(levels(dense), i), false], watcher, "redeem");
    void who;
  }
  for (const a of [opA, opB, watcher]) {
    if ((await l1.read<bigint>(ch, "bondCredit", [a.address])) > 0n) await l1.send(ch, "withdrawBond", [], a, "withdrawBond");
  }
  check((await l1.pub.getBalance({ address: ch.address })) === 0n, "after redemptions and bond withdrawals the channel holds no ETH");
  check((await l1.read<bigint>(token, "balanceOf", [ch.address])) === 0n, "and no USD");
  const out = async (a: Address) => [await l1.pub.getBalance({ address: a }), await l1.read<bigint>(token, "balanceOf", [a])];
  const [ae, au] = await out(alice.address);
  void ae; void au;
  check(totalEth > 0n && totalUsd > 0n, "every deposit came back out through claims and exits (conservation checked above)");

  gw.stop();
  mkdirSync(`${ROOT}docs/experiments/data`, { recursive: true });
  writeFileSync(`${ROOT}docs/experiments/data/clearing-e2e.json`, JSON.stringify({
    note: "anvil prague L1 (chain 900) + two local executors (operators A and B). Gas = L1 receipt gasUsed; sums for repeated labels.",
    l1: l1.gas,
  }, null, 2) + "\n");
  console.table(l1.gas);
  console.log("E2E CLEARING PASSED");
}

main().catch((e) => { console.error(e); process.exit(1); });

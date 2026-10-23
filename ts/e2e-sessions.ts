// Disposable sessions, end to end: one app (a ClearingVault) runs session 1 across several L1
// pins, closes it (a queued withdrawal and an unapplied deposit outstanding), and the operator's
// executor and journal are deleted. Session 2 then starts fresh, from settled funds only:
// users redeem session 1 from a passive recovery package, through an L1 endpoint that refuses
// every historical query, and roll over into the vault by their own choice.
// Checked: old signatures don't replay, duplicate rollovers and claim/rollover races fail,
// session 1 stays claimable while session 2 runs, and nothing had to run in between.
// Measured: setup, active operation, monitoring, close and publication cost, package sizes,
// restart work. Run: npm run e2e-sessions  (needs anvil, forge build, cargo build -p channel-runner)
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { keccak256, pad, parseEther, toHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Chain, type C } from "./runtime/executor.ts";
import { L1ReadView } from "./runtime/l1view.ts";
import { EvidenceStore } from "./runtime/evidence.ts";
import { ClearingOperator, EMPTY, eip712Order, leafHash, mergeAbi, orderHash, type Order } from "./runtime/clearing.ts";
import { levels, siblings } from "./runtime/tree.ts";
import { buildSessionPackage, claimFromJson, claimPackage, publicationChunks, redeemArgs, toJson, verifySessionPackage, type SessionPackage } from "./runtime/recovery.ts";

const ROOT = new URL("..", import.meta.url).pathname;
const CLI = `${ROOT}target/debug/skim-channels`;
const KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
  "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
] as const;
const [op, alice, bob, carol, watcher, dave] = KEYS.map((k) => privateKeyToAccount(k));
const ETH = 0, USD = 1;
const usd = (x: number) => BigInt(Math.round(x * 1e6));
const FAR = 10n ** 9n;
const DAY = 86400, WINDOW = 3600;

function check(cond: unknown, msg: string) {
  if (!cond) throw new Error(`FAILED: ${msg}`);
  console.log(`ok  ${msg}`);
}
async function reverts(p: Promise<unknown>) {
  try { await p; return false; } catch { return true; }
}

/** An L1 endpoint with no history: current state and new transactions only. */
function currentStateOnly(target: string, port: number) {
  const sent = new Set<string>();
  const latest = (v: unknown) => v === undefined || v === "latest" || v === "pending";
  // Recent blocks only, as a node that keeps no history still serves them.
  let head = 0n;
  const recent = (v: unknown) => latest(v) || (typeof v === "string" && v.startsWith("0x") && BigInt(v) + 128n >= head);
  const allowed = (m: string, p: any[]) => {
    switch (m) {
      case "eth_chainId": case "net_version": case "eth_blockNumber": case "eth_gasPrice": case "eth_maxPriorityFeePerGas":
      case "eth_feeHistory": case "eth_sendRawTransaction": return true;
      case "eth_call": case "eth_estimateGas": return latest(p[1]);
      case "eth_getBalance": case "eth_getTransactionCount": case "eth_getCode": return latest(p[1]);
      case "eth_getBlockByNumber": return recent(p[0]);
      case "eth_getTransactionReceipt": case "eth_getTransactionByHash": return sent.has(String(p[0]).toLowerCase());
      default: return false; // eth_getLogs, eth_getTransactionByHash, eth_getProof, debug_*, anvil_*, …
    }
  };
  const refused: string[] = [];
  const server = createServer(async (req, res) => {
    let body = "";
    for await (const c of req) body += c;
    const call = JSON.parse(body);
    const out = async (c: any) => {
      head = BigInt((await (await fetch(target, { method: "POST", headers: { "content-type": "application/json" }, body: '{"jsonrpc":"2.0","id":0,"method":"eth_blockNumber","params":[]}' })).json()).result);
      if (!allowed(c.method, c.params ?? [])) {
        refused.push(c.method);
        return { jsonrpc: "2.0", id: c.id, error: { code: -32601, message: `${c.method}: no history on this endpoint` } };
      }
      const r = await (await fetch(target, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(c) })).json();
      if (c.method === "eth_sendRawTransaction" && r.result) sent.add(String(r.result).toLowerCase());
      return r;
    };
    const r = Array.isArray(call) ? await Promise.all(call.map(out)) : await out(call);
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(r));
  });
  server.listen(port, "127.0.0.1");
  return { url: `http://127.0.0.1:${port}`, refused, close: () => server.close() };
}

const chains: Chain[] = [];
let l1Now: Chain; // users after close: no history
const metrics: Record<string, unknown> = {};
const l1Txs: Record<string, number> = {};

async function main() {
  const l1 = await Chain.anvil(18980, 900);
  chains.push(l1);
  try {
    await run(l1);
  } finally {
    chains.forEach((c) => c.stop());
  }
}

async function run(l1: Chain) {
  const send = async (c: C, fn: string, args: unknown[], who: typeof op, label: string, value?: bigint) => {
    l1Txs[label] = (l1Txs[label] ?? 0) + 1;
    return l1.send(c, fn, args, who, label, value);
  };
  const time = async (s: number) => {
    const blocks = Math.ceil(s / 12);
    if (blocks <= 600) return l1.rpc("anvil_mine", [toHex(blocks), toHex(12)]);
    await l1.rpc("anvil_mine", [toHex(600), toHex(12)]);
    await l1.rpc("evm_increaseTime", [s - 600 * 12]);
    await l1.rpc("anvil_mine", [toHex(1)]);
  };

  // ---- the app: shared infrastructure and its vault (once, for every session) -------------
  // The price feed: Chainlink's layout (an aggregator behind a proxy) on this local L1.
  const answer = (x: number) => BigInt(Math.round(x * 1e8));
  const agg = await l1.deploy(ROOT, op, "ChainlinkMocks.sol", "MockOffchainAggregator", [answer(2000)]);
  const proxy = await l1.deploy(ROOT, op, "ChainlinkMocks.sol", "MockFeedProxy", [agg.address]);
  const feed = { proxy: proxy.address, aggregator: agg.address };
  const MAX_STALE = BigInt(40 * DAY); // the test idles a month between sessions
  const codeHash = async (a: Address) => keccak256((await l1.pub.getCode({ address: a }))!);
  const adapter = await l1.deploy(ROOT, op, "ChainlinkAdapter.sol", "ChainlinkAdapter",
    [proxy.address, await codeHash(proxy.address), agg.address, await codeHash(agg.address), 8, MAX_STALE], "app: ChainlinkAdapter");
  const anchors = await l1.deploy(ROOT, op, "AnchorRegistry.sol", "AnchorRegistry", [], "app: AnchorRegistry");
  const codec = await l1.deploy(ROOT, op, "ClearingCodec.sol", "ClearingCodec", [], "app: ClearingCodec");
  const token = await l1.deploy(ROOT, op, "Clearing.t.sol", "TestUSD");
  const vault = await l1.deploy(ROOT, op, "ClearingVault.sol", "ClearingVault", [op.address, token.address], "app: ClearingVault");
  const appSetup = ["app: AnchorRegistry", "app: ChainlinkAdapter", "app: ClearingCodec", "app: ClearingVault"].reduce((a, k) => a + (l1.gas[k] ?? 0), 0);

  /** A session: its own L1 contracts (config + collateral), registered in the vault. */
  async function openSession(id: bigint) {
    const tag = `session ${id}`;
    const disputes = await l1.deploy(ROOT, op, "ClearingDisputes.sol", "ClearingDisputes", [{
      operator: op.address, usd: token.address, anchors: anchors.address, codec: codec.address,
      priceAdapter: adapter.address, bandBps: 100n, challengeWindow: BigInt(WINDOW), forceDelay: BigInt(DAY),
      maxAnchorAge: 256n, minBond: parseEther("1"), takeoverDelay: BigInt(2 * DAY), appChainId: 7001n, vault: vault.address, sessionId: id,
    }], `${tag}: deploy`);
    const core = await l1.deploy(ROOT, op, "ClearingChannel.sol", "ClearingChannel", [disputes.address], `${tag}: deploy`);
    await send(vault, "register", [core.address], op, `${tag}: register`);
    l1Txs[`${tag}: deploy`] = 2;
    const ch = mergeAbi(core, disputes);
    imports.set(ch.address, [ch.address, disputes.address, proxy.address, agg.address]);
    return ch;
  }
  const imports = new Map<Address, Address[]>(); // per session: what its executor imports (read-only)
  const domainOf = (ch: C, id: bigint) => ({ name: "SkimClearing", version: "0", chainId: 7001, verifyingContract: ch.address, salt: pad(toHex(id), { size: 32 }) });
  async function sign(who: typeof alice, domain: ReturnType<typeof domainOf>, sellToken: number, sellAmount: bigint, buyAmount: bigint, nonce: bigint) {
    const o: Order = { trader: who.address, sellToken, sellAmount, buyAmount, nonce, expiry: FAR };
    return { o, sig: await who.signTypedData({ domain, types: eip712Order, primaryType: "Order", message: o as any }), h: orderHash(o) };
  }
  async function deposit(ch: C, who: typeof alice, eth: bigint, dollars: bigint, label = "user: deposit") {
    if (eth) await send(ch, "deposit", [ETH, eth], who, label, eth);
    if (dollars) {
      await l1.send(token, "mint", [who.address, dollars], who);
      await l1.send(token, "approve", [ch.address, dollars], who);
      await send(ch, "deposit", [USD, dollars], who, label);
    }
  }
  /** The operator's own machine: an app executor (fees 0), a journal, an evidence store. */
  async function startOperator(ch: C, id: bigint, port: number) {
    const t0 = Date.now();
    const dir = mkdtempSync(join(tmpdir(), `skim-session-${id}-`));
    const ex = await Chain.appExecutor(ROOT, port, 7001, l1.url, { readonly: imports.get(ch.address)! });
    chains.push(ex);
    const book = await ClearingOperator.deployBook(ex, l1, op, ch, feed, MAX_STALE);
    const A = new ClearingOperator({
      view: new L1ReadView({ url: l1.url, chainId: 900, cli: CLI }), exec: ex, book, op, l1, channel: ch, anchors,
      feed, maxStaleness: MAX_STALE, evidence: new EvidenceStore(join(dir, "evidence")), policy: { kind: "confirmations", n: 1 },
      bond: parseEther("1"), journal: join(dir, "journal.json"), maxAnchorAge: 256n, ageMargin: 16n,
    });
    return { A, ex, dir, startMs: Date.now() - t0 };
  }
  async function batch(A: ClearingOperator, ch: C, label: string, body: () => Promise<void>) {
    await l1.rpc("anvil_mine", [toHex(2)]);
    await A.open();
    await body();
    await A.seal();
    const p = await A.propose(BigInt(A.current.no), { label: "operator: propose" });
    l1Txs["operator: propose"] = (l1Txs["operator: propose"] ?? 0) + 1;
    await time(WINDOW);
    await send(ch, "finalize", [], op, "operator: finalize");
    await A.finalized();
    const anchor = A.batches.find((b) => b.no === String(BigInt(A.current.no)))?.snap.number ?? A.current.snap.number;
    console.log(`     ${label}: pinned L1 block ${anchor}, ${(p.fills.length - 2) / 2 / 236} fill(s)`);
    return anchor;
  }

  // =========================== session 1 =====================================================
  const s1 = await openSession(1n);
  const d1 = domainOf(s1, 1n);
  await deposit(s1, alice, parseEther("2"), 0n);
  await deposit(s1, bob, 0n, usd(6000));
  await deposit(s1, carol, parseEther("1"), usd(1000));
  await deposit(s1, dave, 0n, usd(500));
  const idx = async (ch: C, a: Address) => Number(await l1.read(ch, "indexPlusOne", [a])) - 1;
  const [ia, ib, ic, id] = [await idx(s1, alice.address), await idx(s1, bob.address), await idx(s1, carol.address), await idx(s1, dave.address)];
  const op1 = await startOperator(s1, 1n, 18981);
  const A = op1.A;

  const pins: bigint[] = [];
  const a1 = await sign(alice, d1, ETH, parseEther("0.5"), usd(1000), 1n);
  const k1 = await sign(bob, d1, USD, usd(1000), parseEther("0.5"), 1n);
  pins.push(await batch(A, s1, "session 1 batch 1 at 2000", async () => {
    await A.apply({ kind: "order", order: a1.o, sig: a1.sig });
    await A.apply({ kind: "order", order: k1.o, sig: k1.sig });
    check((await A.apply({ kind: "fill", a: a1.h, b: k1.h })).ok, "session 1: alice sells 0.5 ETH to bob at 2000");
  }));
  await l1.send(agg, "transmit", [answer(2100)], op);
  await send(s1, "requestWithdraw", [ETH, parseEther("0.5")], alice, "user: requestWithdraw");
  const c1 = await sign(carol, d1, ETH, parseEther("0.2"), usd(420), 1n);
  const k2 = await sign(bob, d1, USD, usd(420), parseEther("0.2"), 2n);
  pins.push(await batch(A, s1, "session 1 batch 2 at 2100", async () => {
    await A.apply({ kind: "order", order: c1.o, sig: c1.sig });
    await A.apply({ kind: "order", order: k2.o, sig: k2.sig });
    check((await A.apply({ kind: "fill", a: c1.h, b: k2.h })).ok, "session 1: carol sells 0.2 ETH to bob at 2100 (a later pin, a new price)");
    const resting = await sign(carol, d1, USD, usd(100), parseEther("0.05"), 2n);
    await A.apply({ kind: "order", order: resting.o, sig: resting.sig }); // rests: books don't survive a session
  }));
  check(pins[1] > pins[0], `session 1 ran across L1 pins ${pins.join(" → ")}, AppState carried between them`);
  // alice claims her released withdrawal (served in batch 2) while the session runs.
  const dense = [0, 1, 2, 3].map((i) => leafHash(A.fin.get(i) ?? EMPTY));
  await send(s1, "claim", [ia, A.fin.get(ia)!, siblings(levels(dense), ia)], alice, "user: claim (active)");

  // Outstanding at close: a withdrawal request no batch served, a deposit no batch applied.
  await send(s1, "requestWithdraw", [USD, usd(500)], bob, "user: requestWithdraw");
  await deposit(s1, dave, parseEther("0.3"), 0n);

  // ---- close -------------------------------------------------------------------------------
  const tCloseStart = (await l1.pub.getBlock()).timestamp;
  await send(s1, "beginClose", [], op, "operator: beginClose");
  check(await reverts(l1.send(s1, "deposit", [ETH, 1n], carol, undefined, 1n)), "Closing: new deposits are refused");
  check(await reverts(l1.send(s1, "requestWithdraw", [ETH, 1n], carol)), "Closing: new withdrawal requests are refused");
  await send(s1, "close", [], op, "operator: close");
  const tClosed = (await l1.pub.getBlock()).timestamp;
  const st1 = await l1.read<any[]>(s1, "state");
  check(Number(st1[5]) === 2, "session 1 is Closed");
  const lastProposal = Number(st1[4]);

  // The recovery package: built once at close, a passive file. Plus one claim file per user.
  const pkg = await buildSessionPackage(l1, s1, A.fin);
  const keep = mkdtempSync(join(tmpdir(), "skim-recovery-"));
  writeFileSync(join(keep, "session-1.json"), toJson(pkg));
  const claimFiles = [ia, ib, ic, id].map((i) => { const f = join(keep, `claim-${i}.json`); writeFileSync(f, toJson(claimPackage(pkg, i))); return f; });
  const pkgBytes = readFileSync(join(keep, "session-1.json")).length;
  const claimBytes = readFileSync(claimFiles[0]).length;
  check(true, `recovery package: ${pkgBytes} B for ${pkg.users.length} users; a user's claim file: ${claimBytes} B`);
  // Optional on-chain publication, in bounded chunks, each checked against the final root by L1.
  for (const args of publicationChunks(pkg, 2)) await send(s1, "publishFinal", args, watcher, "optional: publishFinal");
  check(l1Txs["optional: publishFinal"] === 2, "the package is also published on L1 in 2 chunks, each accepted only as part of the final root");

  // Everything the operator ran for session 1 is deleted.
  op1.ex.stop();
  rmSync(op1.dir, { recursive: true, force: true });
  check(!existsSync(op1.dir), "the operator's executor, journal and evidence for session 1 are gone");

  // Nothing runs for a month. Closed is terminal: nobody can propose or reopen it.
  await time(30 * DAY);
  check(await reverts(l1.send(s1, "propose", ["0x", "0x", "0x", [], 0n, 0n, "0x"], watcher, undefined, parseEther("1"))), "a month later, nobody can propose to session 1 (no takeover of a closed session)");
  check(await reverts(l1.send(s1, "beginClose", [], op)), "and it can't be reopened");

  // =========================== session 2 =====================================================
  const tRestart = Date.now();
  const s2 = await openSession(2n);
  const op2 = await startOperator(s2, 2n, 18982);
  const B = op2.A;
  const restartMs = Date.now() - tRestart;
  const d2 = domainOf(s2, 2n);

  // Users work from their files, through an L1 endpoint with no history at all.
  const now = currentStateOnly(l1.url, 18989);
  l1Now = new Chain(now.url, 900);
  try {
    const loaded: SessionPackage = JSON.parse(readFileSync(join(keep, "session-1.json"), "utf8"));
    await verifySessionPackage(l1Now, s1, loaded);
    check(true, "the package verifies against session 1's final root with current-state reads only");
    check(await reverts(ClearingOperator.recover(l1Now, s1)), "rebuilding from L1 history instead fails on this endpoint (eth_getLogs refused)");

    // alice rolls her session-1 funds into the vault, then funds session 2 herself.
    const ca = claimFromJson(readFileSync(claimFiles[0], "utf8"));
    check(await reverts(l1Now.send(s1, "redeem", redeemArgs(ca, true), op)), "the operator can't roll alice's funds over for her");
    await l1Now.send(s1, "redeem", redeemArgs(ca, true), alice, "user: redeem → vault");
    l1Txs["user: redeem → vault"] = 1;
    const fa = await l1Now.read<any>(vault, "free", [alice.address]);
    check(fa.eth === parseEther("1") && fa.usd === usd(1000), `alice's session-1 entitlement, less the 0.5 ETH she claimed while it ran, is now free in the vault: ${Number(fa.eth) / 1e18} ETH, ${Number(fa.usd) / 1e6} USD`);
    check(await reverts(l1Now.send(s1, "redeem", redeemArgs(ca, true), alice)), "a second rollover of the same entitlement fails");
    check(await reverts(l1Now.send(s1, "redeem", redeemArgs(ca, false), watcher)), "and so does a wallet redemption after it");
    await l1Now.send(vault, "fund", [s2.address, ETH, parseEther("1")], alice, "user: vault.fund");
    await l1Now.send(vault, "fund", [s2.address, USD, usd(1000)], alice, "user: vault.fund");
    l1Txs["user: vault.fund"] = 2;
    check((await l1Now.read<any>(s2, "cumIn", [0])).eth === parseEther("1"), "alice funded session 2 from the vault (her own transaction)");

    // carol: someone triggers her wallet redemption; her rollover afterwards fails (race).
    const cc = claimFromJson(readFileSync(claimFiles[2], "utf8"));
    await l1Now.send(s1, "redeem", redeemArgs(cc, false), watcher, "user: redeem → wallet");
    check(await reverts(l1Now.send(s1, "redeem", redeemArgs(cc, true), carol)), "carol's rollover after her wallet redemption fails: one payout record for both");
    // dave: the unapplied deposit is part of his entitlement.
    const cd = claimFromJson(readFileSync(claimFiles[3], "utf8"));
    const dBefore = await l1.pub.getBalance({ address: dave.address });
    await l1Now.send(s1, "redeem", redeemArgs(cd, false), watcher, "user: redeem → wallet");
    check((await l1.pub.getBalance({ address: dave.address })) - dBefore === parseEther("0.3"), "dave's deposit that no batch applied comes back with his redemption");

    // ---- session 2 runs; bob redeems session 1 meanwhile ----
    await deposit(s2, bob, 0n, usd(3000));
    const old = await sign(alice, d1, ETH, parseEther("0.1"), usd(210), 9n);
    await l1.rpc("anvil_mine", [toHex(2)]);
    await B.open();
    const replay = await B.apply({ kind: "order", order: old.o, sig: old.sig });
    check(!replay.ok, "an order alice signed for session 1 is refused by session 2's book (session-salted domain)");
    const a2 = await sign(alice, d2, ETH, parseEther("0.4"), usd(840), 1n);
    const k3 = await sign(bob, d2, USD, usd(840), parseEther("0.4"), 1n);
    await B.apply({ kind: "order", order: a2.o, sig: a2.sig });
    await B.apply({ kind: "order", order: k3.o, sig: k3.sig });
    check((await B.apply({ kind: "fill", a: a2.h, b: k3.h })).ok, "session 2: alice sells 0.4 ETH to bob, with collateral rolled over from session 1");
    const cb = claimFromJson(readFileSync(claimFiles[1], "utf8"));
    const bUsd = await l1.read<bigint>(token, "balanceOf", [bob.address]);
    await l1Now.send(s1, "redeem", redeemArgs(cb, false), bob, "user: redeem → wallet");
    const bobGot = (await l1.read<bigint>(token, "balanceOf", [bob.address])) - bUsd;
    check(bobGot === usd(6000 - 1000 - 420), `while session 2 is active, bob redeems session 1 to his wallet: ${Number(bobGot) / 1e6} USD (his queued request is covered)`);
    await B.seal();
    await B.propose(BigInt(B.current.no), { label: "operator: propose" });
    await time(WINDOW);
    await send(s2, "finalize", [], op, "operator: finalize");
    await B.finalized();
    check(true, "session 2's first batch is final");
  } finally {
    now.close();
  }

  // Session 1 holds nothing but the operator's bond credits; once withdrawn, it is empty.
  await send(s1, "withdrawBond", [], op, "operator: withdrawBond");
  check((await l1.pub.getBalance({ address: s1.address })) === 0n && (await l1.read<bigint>(token, "balanceOf", [s1.address])) === 0n,
    "session 1 is empty: every entitlement was redeemed or rolled over, and no funds were moved without their owner");
  check(now.refused.includes("eth_getLogs"), `the history-free endpoint refused: ${[...new Set(now.refused)].join(", ")}`);

  // ---- measurements -------------------------------------------------------------------------
  Object.assign(metrics, {
    note: "anvil L1 (chain 900) and anvil executors (chain 7001). Gas = L1 receipt gasUsed, summed per label; txs = count per label.",
    users: pkg.users.length,
    appSetup: { gas: appSetup, txs: 4, what: "AnchorRegistry, ChainlinkAdapter, ClearingCodec, ClearingVault: once per app" },
    sessionSetup: { gas: l1.gas["session 1: deploy"] + l1.gas["session 1: register"], txs: 3, what: "ClearingDisputes + ClearingChannel + vault.register, per session" },
    perBatch: { proposeGas: Math.round(l1.gas["operator: propose"] / l1Txs["operator: propose"]), finalizeGas: Math.round(l1.gas["operator: finalize"] / l1Txs["operator: finalize"]) },
    idle: "no L1 transactions while idle (no batch, no proposal). An Active session must still be watched: after takeoverDelay anyone may propose",
    close: { beginCloseGas: l1.gas["operator: beginClose"], closeGas: l1.gas["operator: close"], txs: 2 },
    monitoring: {
      lastProposalToClosedSeconds: Number(tClosed) - lastProposal,
      beginCloseToClosedSeconds: Number(tClosed - tCloseStart),
      rule: "Active (even idle): watch, proposals stay possible. Closing: watch until nothing is pending. Closed: nothing to watch once the close transaction is final on L1",
    },
    recovery: {
      packageBytes: pkgBytes, claimFileBytes: claimBytes, publishFinalGas: l1.gas["optional: publishFinal"], publishChunks: l1Txs["optional: publishFinal"],
      publishedLeafBytes: (pkg.leaves.length - 2) / 2,
      bySize: "contracts/test/clearing/ClearingSession.t.sol test_publishFinalCost: ~5k execution gas + 108 calldata bytes per user, linear; 1024 users in one chunk = 5.1M execution gas + 110 KB",
    },
    restart: { ms: restartMs, l1Txs: 3, executorSetupMs: op2.startMs, what: "deploy + register session 2, start an empty executor; no replay of session 1" },
    users_: {
      claimWhileActiveGas: l1.gas["user: claim (active)"],
      redeemToWalletGas: Math.round(l1Now.gas["user: redeem → wallet"] / 3), redeemToVaultGas: l1Now.gas["user: redeem → vault"],
      vaultFundGas: Math.round(l1Now.gas["user: vault.fund"] / 2),
    },
    gas: { ...l1.gas, ...l1Now.gas }, txs: l1Txs,
  });
  mkdirSync(`${ROOT}docs/experiments/data`, { recursive: true });
  writeFileSync(`${ROOT}docs/experiments/data/sessions.json`, JSON.stringify(metrics, null, 2) + "\n");
  console.log(JSON.stringify({ ...metrics, gas: undefined, txs: undefined }, null, 2));
  console.log("E2E SESSIONS PASSED");
}

main().catch((e) => { console.error(e); process.exit(1); });

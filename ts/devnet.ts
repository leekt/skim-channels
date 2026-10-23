// A persistent devnet for trying the clearing app with a real wallet (MetaMask, Rabby…):
//   L1        anvil (chain 900, a block every 2 s): price feed, AnchorRegistry, ClearingChannel, test USD
//   app       a local executor (chain 7001, fees 0) with L1View + ClearingBook, behind the
//             standard JSON-RPC gateway (runtime/gateway.ts)
//   operator  a loop: open batches, match crossing orders, seal, propose, finalize, recover
//   maker     a bot that answers any user order at the L1 price, so one person can trade
// One HTTP server (default :8787) serves the test app, /rpc/l1 (filtered: no anvil cheats),
// /rpc/app (the gateway), and /api/* (faucet, state, claim/exit arguments, devnet controls).
// Expose it with `tailscale serve --bg 8787` (HTTPS on your tailnet).
//
// DEVNET ONLY: in-memory chains; the faucet and the time/price controls exist only here.
// Run: npm run devnet  (needs anvil, forge build, cargo build)
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  createWalletClient, decodeFunctionData, defineChain, http, parseEther, parseTransaction, toHex, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Chain, type C } from "./runtime/executor.ts";
import { L1ReadView } from "./runtime/l1view.ts";
import { EvidenceStore } from "./runtime/evidence.ts";
import { Gateway } from "./runtime/gateway.ts";
import { levels, siblings } from "./runtime/tree.ts";
import { ClearingOperator, EMPTY, eip712Order, leafHash, mergeAbi, orderHash, type Order } from "./runtime/clearing.ts";

const ROOT = new URL("..", import.meta.url).pathname;
const CLI = `${ROOT}target/debug/skim-channels`;
const PORT = Number(process.env.PORT ?? 8787);
const L1_ID = 900, APP_ID = 7001, WINDOW = 3600, DAY = 86400;
const SLOT0: Hex = `0x${"0".repeat(64)}`;
const usd = (x: number) => BigInt(Math.round(x * 1e6));
// anvil's well-known dev keys: the operator, and the market maker. Devnet only.
const op = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const maker = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");

type Known = { hash: Hex; order: Order; from: Address; maker: boolean; answered?: boolean; at: number };
const log: string[] = [];
function note(s: string) {
  const line = `${new Date().toISOString().slice(11, 19)} ${s}`;
  log.push(line);
  if (log.length > 200) log.shift();
  console.log(line);
}

async function main() {
  const l1 = await Chain.anvil(18901, L1_ID, ["--block-time", "2"]);
  const ex = await Chain.anvil(18902, APP_ID, ["--base-fee", "0", "--gas-limit", "10000000000"]);
  process.on("SIGINT", () => { l1.stop(); ex.stop(); process.exit(0); });

  // ---- L1 ----
  const oracle = await l1.deploy(ROOT, op, "AllocationFixture.sol", "AllocationFixture", [usd(2000)]);
  const anchors = await l1.deploy(ROOT, op, "AnchorRegistry.sol", "AnchorRegistry");
  const wv = await l1.deploy(ROOT, op, "WitnessVerifier.sol", "WitnessVerifier");
  const codec = await l1.deploy(ROOT, op, "ClearingCodec.sol", "ClearingCodec");
  const token = await l1.deploy(ROOT, op, "Clearing.t.sol", "TestUSD");
  const disputes = await l1.deploy(ROOT, op, "ClearingDisputes.sol", "ClearingDisputes", [{
    operator: op.address, usd: token.address, anchors: anchors.address, witnessVerifier: wv.address, codec: codec.address,
    priceFeed: oracle.address, priceSlot: SLOT0, bandBps: 100n, challengeWindow: BigInt(WINDOW), forceDelay: BigInt(DAY),
    maxAnchorAge: 256n, minBond: parseEther("1"), takeoverDelay: BigInt(2 * DAY), appChainId: BigInt(APP_ID),
  }]);
  const core = await l1.deploy(ROOT, op, "ClearingChannel.sol", "ClearingChannel", [disputes.address]);
  const ch = mergeAbi(core, disputes);

  // ---- app network ----
  const view = await ex.deploy(ROOT, op, "L1View.sol", "L1View", [BigInt(L1_ID)]);
  const book = await ex.deploy(ROOT, op, "ClearingBook.sol", "ClearingBook", [view.address, ch.address, oracle.address, SLOT0, 100n, op.address]);
  const reader = new L1ReadView({ url: l1.url, chainId: L1_ID, cli: CLI });
  const A = new ClearingOperator({
    view: reader, exec: ex, book, l1view: view, op, l1, channel: ch, anchors, priceFeed: oracle.address, priceSlot: SLOT0,
    evidence: new EvidenceStore(join(tmpdir(), `skim-devnet-evidence-${process.pid}`)), policy: { kind: "confirmations", n: 2 },
    bond: parseEther("1"), journal: join(tmpdir(), `skim-devnet-journal-${process.pid}.json`), maxAnchorAge: 256n, ageMargin: 32n,
  });
  const gw = new Gateway(A, 18903);
  await gw.start();

  // ---- the market maker: funded on L1 like any user ----
  await l1.send(ch, "deposit", [0, parseEther("50")], maker, undefined, parseEther("50"));
  await l1.send(token, "mint", [maker.address, usd(500_000)], maker);
  await l1.send(token, "approve", [ch.address, usd(500_000)], maker);
  await l1.send(ch, "deposit", [1, usd(500_000)], maker);
  const appChain = defineChain({ id: APP_ID, name: "skim clearing (devnet)", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [gw.url] } } });
  const makerWallet = createWalletClient({ account: maker, chain: appChain, transport: http(gw.url), pollingInterval: 50 });
  const domain = { name: "SkimClearing", version: "0", chainId: APP_ID, verifyingContract: ch.address };
  note(`L1 channel ${ch.address}, app book ${book.address}, maker ${maker.address}`);

  // ---- orders seen on the app network (from the journal's raw transactions) ----
  const known = new Map<Hex, Known>();
  function learn() {
    for (const b of A.batches) for (const l of b.log) {
      if (!l.ok || (l.action as any).kind !== "raw") continue;
      try {
        const { functionName, args } = decodeFunctionData({ abi: book.abi, data: parseRawData((l.action as any).tx) }) as any;
        if (functionName !== "submitOrder") continue;
        const o = args[0] as Order;
        const h = orderHash(o);
        if (!known.has(h)) known.set(h, { hash: h, order: o, from: o.trader, maker: o.trader.toLowerCase() === maker.address.toLowerCase(), at: Date.now() });
      } catch { /* not ours */ }
    }
  }
  const price = async () => BigInt(await l1.read<bigint>(oracle, "shareBps"));

  /** Answer each new user order with the opposite order at the user's own limit, if it's within the band. */
  async function makeMarket() {
    const p = await price();
    for (const k of known.values()) {
      if (k.maker || k.answered) continue;
      if (!(await ex.read<boolean>(book, "resting", [k.hash]))) { k.answered = true; continue; }
      const o = k.order;
      const eth = o.sellToken === 0 ? o.sellAmount : o.buyAmount;
      const dollars = o.sellToken === 0 ? o.buyAmount : o.sellAmount;
      const fillPrice = (dollars * 10n ** 18n) / eth;
      const diff = fillPrice > p ? fillPrice - p : p - fillPrice;
      if (diff * 10_000n > 100n * p) { k.answered = true; note(`maker: ${o.trader.slice(0, 8)}'s order at ${fmtPrice(fillPrice)} is outside 1% of ${fmtPrice(p)}: left resting`); continue; }
      const m: Order = o.sellToken === 0
        ? { trader: maker.address, sellToken: 1, sellAmount: dollars, buyAmount: eth, nonce: BigInt(Date.now()), expiry: 10n ** 12n }
        : { trader: maker.address, sellToken: 0, sellAmount: eth, buyAmount: dollars, nonce: BigInt(Date.now()), expiry: 10n ** 12n };
      const sig = await maker.signTypedData({ domain, types: eip712Order, primaryType: "Order", message: m as any });
      try {
        await makerWallet.writeContract({ address: book.address, abi: book.abi, functionName: "submitOrder", args: [m, sig] });
        known.set(orderHash(m), { hash: orderHash(m), order: m, from: maker.address, maker: true, at: Date.now() });
        k.answered = true;
        note(`maker: answered ${o.trader.slice(0, 8)}'s order at ${fmtPrice(fillPrice)}`);
      } catch (e: any) {
        note(`maker: couldn't answer (${String(e?.shortMessage ?? e).slice(0, 80)})`);
      }
    }
  }

  /** Fill every crossing pair of resting orders (the contract checks band, limits, collateral). */
  async function match() {
    const resting: Known[] = [];
    for (const k of known.values()) if (await ex.read<boolean>(book, "resting", [k.hash])) resting.push(k);
    const used = new Set<Hex>();
    for (const a of resting.filter((x) => x.order.sellToken === 0)) {
      for (const b of resting.filter((x) => x.order.sellToken === 1)) {
        if (used.has(a.hash) || used.has(b.hash) || a.order.trader === b.order.trader) continue;
        if (a.order.sellAmount < b.order.buyAmount || b.order.sellAmount < a.order.buyAmount) continue;
        const r = await A.apply({ kind: "fill", a: a.hash, b: b.hash });
        if (r.ok) { used.add(a.hash); used.add(b.hash); note(`filled: ${a.order.trader.slice(0, 8)} sells ${fmtEth(a.order.sellAmount)} ETH to ${b.order.trader.slice(0, 8)} for ${fmtUsd(b.order.sellAmount)} USD`); }
      }
    }
  }

  // ---- the operator loop ----
  let openedAt = 0;
  let busy = false;
  async function step() {
    if (busy) return;
    busy = true;
    try {
      const st = await l1.read<any[]>(ch, "state");
      if (st[5]) return; // frozen: users exit on L1
      const t = await A.tick();
      if (t.status === "recovered") note(`recovered batch ${t.from} (${t.reason}): ${t.dropped.length} action(s) dropped`);
      if (!A.batches.length || A.current.state !== "open") {
        await A.open();
        openedAt = Date.now();
      }
      learn();
      await makeMarket();
      learn();
      await match();
      // Seal every 15 s; propose the oldest sealed batch when nothing is pending on L1.
      const cur = A.current;
      const did = cur.log.length > 0 || ((cur.prepared as any).depositUsers?.length ?? 0) > 0 || ((cur.prepared as any).forced?.orders?.length ?? 0) > 0;
      if (Date.now() - openedAt > 15_000) {
        if (did) {
          await A.seal();
          await A.open();
        } else {
          // Nothing happened: re-pin the open batch on a fresh snapshot, taking in new
          // deposits, withdrawal requests and forced orders.
          const r = await A.recover(A.current.no, "refresh");
          if (r.status !== "recovered") note(`refresh: ${r.status}`);
        }
        openedAt = Date.now();
      }
      const pend = await l1.read<any>(ch, "pending");
      if (pend.at === 0n) {
        const next = A.batches.find((b) => b.state === "sealed");
        if (next) {
          try {
            await A.propose(BigInt(next.no));
            note(`proposed batch ${next.no} to L1 (finalizable after the ${WINDOW / 60}-minute window)`);
          } catch (e: any) { note(`propose ${next.no}: ${String(e?.message ?? e).slice(0, 100)}`); }
        }
      } else {
        const now = (await l1.pub.getBlock()).timestamp;
        if (now >= pend.at + BigInt(WINDOW)) {
          await l1.send(ch, "finalize", [], op);
          await A.finalized();
          note(`finalized on L1 (batches: ${(await l1.read<any[]>(ch, "state"))[3]})`);
        }
      }
    } catch (e: any) {
      note(`operator: ${String(e?.shortMessage ?? e?.message ?? e).slice(0, 160)}`);
    } finally {
      busy = false;
    }
  }
  setInterval(step, 2000);

  // ---- HTTP: the app, the RPCs, the API ----
  const L1_ALLOWED = /^(eth_|net_|web3_)/;
  const L1_DENIED = new Set(["eth_sendTransaction", "eth_sign", "eth_signTransaction", "eth_signTypedData_v4", "eth_accounts"]);
  const page = () => readFileSync(new URL("./devnet/app.html", import.meta.url), "utf8");
  const server = createServer(async (req, res) => {
    cors(res);
    if (req.method === "OPTIONS") return res.writeHead(204).end();
    const url = new URL(req.url ?? "/", "http://x");
    try {
      if (url.pathname === "/" || url.pathname === "/index.html") {
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        return res.end(page());
      }
      if (url.pathname === "/rpc/app") return proxy(req, res, gw.url, () => true);
      if (url.pathname === "/rpc/l1") return proxy(req, res, l1.url, (m) => L1_ALLOWED.test(m) && !L1_DENIED.has(m));
      if (url.pathname === "/api/config") {
        return json(res, {
          l1: { chainId: L1_ID, rpc: "/rpc/l1", channel: ch.address, token: token.address, oracle: oracle.address },
          app: { chainId: APP_ID, rpc: "/rpc/app", book: book.address },
          maker: maker.address, domain, challengeWindow: WINDOW, forceDelay: DAY,
          abi: { channel: ch.abi, book: book.abi, token: token.abi },
        });
      }
      if (url.pathname === "/api/state") {
        const p = await price();
        const st = await l1.read<any[]>(ch, "state");
        const pend = await l1.read<any>(ch, "pending");
        const orders = [];
        for (const k of known.values()) orders.push({ ...k, resting: await ex.read<boolean>(book, "resting", [k.hash]) });
        return json(res, {
          price: p.toString(), l1Block: (await l1.height()).toString(), l1Time: (await l1.pub.getBlock()).timestamp.toString(),
          frozen: st[5], finalizedBatches: st[3].toString(),
          pending: pend.at === 0n ? null : { at: pend.at.toString(), proposer: pend.proposer, finalizableAt: (pend.at + BigInt(WINDOW)).toString() },
          batches: A.batches.slice(-8).map((b) => ({ no: b.no, state: b.state, anchor: b.snap.number.toString(), actions: b.log.length })),
          orders: orders.filter((o) => o.resting).slice(-30), log: log.slice(-40),
        });
      }
      if (url.pathname === "/api/leaf") {
        // The finalized leaf and its path, for claim (and exit after a freeze).
        const a = url.searchParams.get("address") as Address;
        const ip = Number(await l1.read(ch, "indexPlusOne", [a]));
        if (!ip) return json(res, { registered: false });
        const n = Number(await l1.read(ch, "userCount"));
        const dense = Array.from({ length: n }, (_, i) => leafHash(A.fin.get(i) ?? EMPTY));
        const leaf = A.fin.get(ip - 1) ?? EMPTY;
        return json(res, { registered: true, idx: ip - 1, leaf: str(leaf), siblings: siblings(levels(dense), ip - 1), paid: str(await l1.read(ch, "paid", [ip - 1])) });
      }
      if (req.method === "POST" && url.pathname === "/api/faucet") {
        const { address } = await body(req);
        await l1.wallet(op).sendTransaction({ to: address, value: parseEther("5") }).then((h) => l1.pub.waitForTransactionReceipt({ hash: h }));
        await l1.send(token, "mint", [address, usd(20_000)], op);
        note(`faucet: 5 ETH and 20,000 USD (on L1) to ${address.slice(0, 8)}`);
        return json(res, { ok: true });
      }
      if (req.method === "POST" && url.pathname === "/api/devnet/advance") {
        const { seconds } = await body(req);
        await l1.rpc("evm_increaseTime", [Number(seconds)]);
        await l1.rpc("anvil_mine", [toHex(1)]);
        note(`devnet: L1 time advanced ${seconds} s`);
        return json(res, { ok: true });
      }
      if (req.method === "POST" && url.pathname === "/api/devnet/price") {
        const { price: p } = await body(req);
        await l1.send(oracle, "setShareBps", [usd(Number(p))], op);
        note(`devnet: L1 price set to ${p}`);
        return json(res, { ok: true });
      }
      res.writeHead(404).end("not found");
    } catch (e: any) {
      json(res, { error: String(e?.shortMessage ?? e?.message ?? e) }, 500);
    }
  });
  server.listen(PORT, "127.0.0.1", () => {
    note(`devnet ready: http://127.0.0.1:${PORT}  (tailscale serve --bg ${PORT})`);
  });
}

// ---- helpers ----------------------------------------------------------------------------------

const parseRawData = (raw: Hex): Hex => parseTransaction(raw).data ?? "0x";

const fmtPrice = (p: bigint) => (Number(p) / 1e6).toFixed(2);
const fmtEth = (x: bigint) => (Number(x) / 1e18).toString();
const fmtUsd = (x: bigint) => (Number(x) / 1e6).toFixed(2);
const str = (o: any) => JSON.parse(JSON.stringify(o, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));

function cors(res: ServerResponse) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "content-type");
}

function json(res: ServerResponse, v: unknown, status = 200) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? x.toString() : x)));
}

async function body(req: IncomingMessage): Promise<any> {
  let s = "";
  for await (const c of req) s += c;
  return s ? JSON.parse(s) : {};
}

/** Forward JSON-RPC to `target`, refusing methods `allow` rejects (batches included). */
async function proxy(req: IncomingMessage, res: ServerResponse, target: string, allow: (m: string) => boolean) {
  const raw = await body(req);
  const calls = Array.isArray(raw) ? raw : [raw];
  const out = await Promise.all(calls.map(async (c: any) => {
    if (!allow(String(c.method))) return { jsonrpc: "2.0", id: c.id, error: { code: -32601, message: `method ${c.method} not available on this network` } };
    const r = await fetch(target, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(c) });
    return r.json();
  }));
  json(res, Array.isArray(raw) ? out : out[0]);
}

main().catch((e) => { console.error(e); process.exit(1); });

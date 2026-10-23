// A persistent devnet for trying the clearing app with a real wallet (MetaMask, Rabby…).
//
// Two networks, one code path:
//   local    (default)  L1 = anvil (chain 900, a block every 2 s) with a Chainlink-layout feed
//                        (an aggregator behind a proxy) whose price the devnet controls.
//   sepolia  (SEPOLIA_OPERATOR_KEY set)  L1 = Sepolia through a skim node (SKIM_RPC): the
//                        session's contracts live on Sepolia, the price is Chainlink's real
//                        ETH/USD feed there, and every L1 read and write goes through skim.
//
// Either way:
//   app       crates/app-executor (chain 7001, fees 0): ClearingBook reads the channel and the
//             feed at their L1 addresses (imported read-only, verified at the pin), behind the
//             standard JSON-RPC gateway (runtime/gateway.ts) wallets connect to
//   operator  a loop: open batches, match, seal, propose (with the price witness L1's
//             ChainlinkAdapter checks), finalize, re-pin when idle (no L1 transaction)
//   maker     a bot that answers any user order inside the band, so one person can trade
//   sessions  on Sepolia, the app's vault and infrastructure are deployed once
//             (~/.skim-devnet/sepolia.json). A restart resumes the active session from its
//             journal (on disk) on a fresh executor. NEW_SESSION=1 opens a new session and closes
//             the previous one, whose users then redeem or roll over (docs/guide/stateful-runtime.md).
//             Under Amsterdam's code pricing a session costs ~36M gas to deploy, so rotate on purpose.
//
// One HTTP server (default :8787) serves the test app, /rpc/l1 (filtered), /rpc/app (the
// gateway) and /api/*. Expose it with `tailscale serve --bg 8787`.
//
// Run: npm run devnet                                         (local)
//      SEPOLIA_OPERATOR_KEY=0x… SKIM_RPC=http://127.0.0.1:18545 npm run devnet   (sepolia)
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import {
  concat, createWalletClient, decodeFunctionData, defineChain, http, keccak256, pad, parseEther, parseTransaction, toHex,
  type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { artifact, Chain, type C } from "./runtime/executor.ts";
import { L1ReadView } from "./runtime/l1view.ts";
import { EvidenceStore } from "./runtime/evidence.ts";
import { Gateway } from "./runtime/gateway.ts";
import { levels, siblings } from "./runtime/tree.ts";
import { ClearingOperator, EMPTY, eip712Order, leafHash, mergeAbi, orderHash, type Account, type Feed, type Order } from "./runtime/clearing.ts";

const ROOT = new URL("..", import.meta.url).pathname;
const CLI = `${ROOT}target/debug/skim-channels`;
const PORT = Number(process.env.PORT ?? 8787);
const APP_ID = 7001, WINDOW = 3600, DAY = 86400;
const SKIM_RPC = process.env.SKIM_RPC ?? "http://127.0.0.1:18545";
const OPERATOR_KEY = process.env.SEPOLIA_OPERATOR_KEY as Hex | undefined;
const NET: "local" | "sepolia" = OPERATOR_KEY ? "sepolia" : "local";
const SEPOLIA = 11155111;
// Chainlink ETH/USD on Sepolia: the proxy apps call.
const SEPOLIA_FEED_PROXY: Address = "0x694AA1769357215DE4FAC081bf1f309aDC325306";
const STATE_FILE = join(homedir(), ".skim-devnet", "sepolia.json");
const usd = (x: number) => BigInt(Math.round(x * 1e6));
const answer8 = (x: number) => BigInt(Math.round(x * 1e8));
// Local: anvil's well-known dev keys. Sepolia: the operator's key, and a maker key derived from it.
const op = privateKeyToAccount(OPERATOR_KEY ?? "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const maker = privateKeyToAccount(OPERATOR_KEY ? keccak256(concat([OPERATOR_KEY, toHex("maker")])) : "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");
// What each network can afford: the maker's float, the faucet, and how stale a price may be.
const P = NET === "local"
  ? { makerEth: parseEther("50"), makerUsd: usd(500_000), faucetEth: parseEther("5"), faucetUsd: usd(20_000), bond: parseEther("1"), maxStale: BigInt(DAY), policy: { kind: "confirmations", n: 2 } as const }
  : { makerEth: parseEther("0.02"), makerUsd: usd(50_000), faucetEth: parseEther("0.005"), faucetUsd: usd(20_000), bond: parseEther("0.01"), maxStale: BigInt(6 * 3600), policy: { kind: "safe" } as const };

type Known = { hash: Hex; order: Order; from: Address; maker: boolean; answered?: boolean; at: number };
const log: string[] = [];
function note(s: string) {
  const line = `${new Date().toISOString().slice(11, 19)} ${s}`;
  log.push(line);
  if (log.length > 200) log.shift();
  console.log(line);
}

const at = (abiOf: C, address: Address): C => ({ address, abi: abiOf.abi });
const abiOf = (file: string, name: string): C => ({ address: "0x0000000000000000000000000000000000000000", abi: artifact(ROOT, file, name).abi });

async function main() {
  // ---- L1 ----
  let l1: Chain;
  if (NET === "local") {
    l1 = await Chain.anvil(18901, 900, ["--block-time", "2"]);
  } else {
    l1 = new Chain(SKIM_RPC, SEPOLIA);
    const id = await l1.pub.getChainId().catch((e) => { throw new Error(`no skim node at ${SKIM_RPC}: ${e.message}`); });
    if (id !== SEPOLIA) throw new Error(`${SKIM_RPC} follows chain ${id}, not Sepolia`);
    const bal = await l1.pub.getBalance({ address: op.address });
    note(`Sepolia operator ${op.address}: ${Number(bal) / 1e18} ETH`);
    if (bal < parseEther("0.03")) throw new Error(`fund ${op.address} with Sepolia ETH (≥ 0.03; deployments and proposals cost gas)`);
  }
  const codeHash = async (a: Address) => (await l1.rpc<any>("eth_getProof", [a, [], "latest"])).codeHash as Hex;

  // ---- the app: feed, adapter, infrastructure and vault (once per app) ----
  type App = { token: Address; anchors: Address; codec: Address; adapter: Address; vault: Address; feed: Feed; sessions: { id: string; channel: Address; disputes: Address; startBlock?: string; makerRedeemed?: boolean }[] };
  // Each session's finalized leaves, kept on disk so a closed session can be redeemed after a restart.
  const finFile = (sid: string) => join(homedir(), ".skim-devnet", `session-${sid}-fin.json`);
  const loadFin = (sid: string): Map<number, Account> => {
    if (NET !== "sepolia" || !existsSync(finFile(sid))) return new Map();
    return new Map(Object.entries(JSON.parse(readFileSync(finFile(sid), "utf8"))).map(([k, v]: [string, any]) => [Number(k), {
      eth: BigInt(v.eth), usd: BigInt(v.usd), ethIn: BigInt(v.ethIn), usdIn: BigInt(v.usdIn), ethOut: BigInt(v.ethOut), usdOut: BigInt(v.usdOut), nonce: BigInt(v.nonce), requests: Number(v.requests),
    }]));
  };
  let app: App;
  const saved: App | undefined = NET === "sepolia" && existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : undefined;
  if (saved) {
    app = saved;
    note(`reusing the app's contracts on Sepolia (vault ${app.vault}, ${app.sessions.length} earlier session(s))`);
  } else {
    let feed: Feed;
    if (NET === "local") {
      const agg = await l1.deploy(ROOT, op, "ChainlinkMocks.sol", "MockOffchainAggregator", [answer8(2000)]);
      const proxy = await l1.deploy(ROOT, op, "ChainlinkMocks.sol", "MockFeedProxy", [agg.address]);
      feed = { proxy: proxy.address, aggregator: agg.address };
    } else {
      const aggregator = await l1.pub.readContract({ address: SEPOLIA_FEED_PROXY, abi: abiOf("ChainlinkMocks.sol", "MockFeedProxy").abi, functionName: "aggregator" }) as Address;
      feed = { proxy: SEPOLIA_FEED_PROXY, aggregator };
    }
    const adapter = await l1.deploy(ROOT, op, "ChainlinkAdapter.sol", "ChainlinkAdapter",
      [feed.proxy, await codeHash(feed.proxy), feed.aggregator, await codeHash(feed.aggregator), 8, P.maxStale]);
    const anchors = await l1.deploy(ROOT, op, "AnchorRegistry.sol", "AnchorRegistry");
    const codec = await l1.deploy(ROOT, op, "ClearingCodec.sol", "ClearingCodec");
    const token = await l1.deploy(ROOT, op, "Clearing.t.sol", "TestUSD");
    const vault = await l1.deploy(ROOT, op, "ClearingVault.sol", "ClearingVault", [op.address, token.address]);
    app = { token: token.address, anchors: anchors.address, codec: codec.address, adapter: adapter.address, vault: vault.address, feed, sessions: [] };
  }
  const save = () => {
    if (NET !== "sepolia") return;
    mkdirSync(join(homedir(), ".skim-devnet"), { recursive: true });
    writeFileSync(STATE_FILE, JSON.stringify(app, null, 2) + "\n");
  };
  save();
  const token = at(abiOf("Clearing.t.sol", "TestUSD"), app.token);
  const anchors = at(abiOf("AnchorRegistry.sol", "AnchorRegistry"), app.anchors);
  const vault = at(abiOf("ClearingVault.sol", "ClearingVault"), app.vault);
  const feedProxy = at(abiOf("ChainlinkMocks.sol", "MockFeedProxy"), app.feed.proxy);
  const feedAgg = at(abiOf("ChainlinkMocks.sol", "MockOffchainAggregator"), app.feed.aggregator);
  const chAbi = mergeAbi(abiOf("ClearingChannel.sol", "ClearingChannel"), abiOf("ClearingDisputes.sol", "ClearingDisputes")).abi;
  const sessionC = (a: Address): C => ({ address: a, abi: chAbi });

  // ---- the session: resume the active one, or open a new one (the previous one starts closing) ----
  const last = app.sessions.at(-1);
  const resume = NET === "sepolia" && !process.env.NEW_SESSION && !!last
    && Number((await l1.read<any[]>(sessionC(last.channel), "state"))[5]) === 0;
  if (!resume) {
    const sid = BigInt(Number(await l1.read(vault, "sessionCount")) + 1);
    const d = await l1.deploy(ROOT, op, "ClearingDisputes.sol", "ClearingDisputes", [{
      operator: op.address, usd: app.token, anchors: app.anchors, codec: app.codec, priceAdapter: app.adapter, bandBps: 100n,
      challengeWindow: BigInt(WINDOW), forceDelay: BigInt(DAY), maxAnchorAge: 256n, minBond: P.bond, takeoverDelay: BigInt(2 * DAY),
      appChainId: BigInt(APP_ID), vault: app.vault, sessionId: sid,
    }]);
    const c = await l1.deploy(ROOT, op, "ClearingChannel.sol", "ClearingChannel", [d.address]);
    const startBlock = await l1.height();
    await l1.send(vault, "register", [c.address], op);
    app.sessions.push({ id: sid.toString(), channel: c.address, disputes: d.address, startBlock: startBlock.toString() });
    save();
  }
  const cur = app.sessions.at(-1)!;
  const id = BigInt(cur.id);
  const core = { address: cur.channel };
  const disputes = { address: cur.disputes };
  const startBlock = BigInt(cur.startBlock ?? 0);
  const ch = sessionC(cur.channel);
  if (resume) note(`resuming session ${id} (${ch.address}) from its journal`);
  /** An earlier session: start closing it, close it when nothing is pending, then take the maker's float back. */
  async function closeOld(s: App["sessions"][number]) {
    const c = sessionC(s.channel);
    let ph = Number((await l1.read<any[]>(c, "state"))[5]);
    if (ph === 0) {
      await l1.send(c, "beginClose", [], op);
      note(`session ${s.id}: closing (it closes once nothing is pending; its users then redeem or roll over)`);
      ph = 1;
    }
    if (ph === 1) {
      const pend = await l1.read<any>(c, "pending");
      const now = (await l1.pub.getBlock()).timestamp;
      if (pend.at !== 0n && now >= pend.at + BigInt(WINDOW)) await l1.send(c, "finalize", [], op);
      if ((await l1.read<any>(c, "pending")).at !== 0n) return;
      await l1.send(c, "close", [], op);
      note(`session ${s.id}: closed. Its users redeem to their wallet or roll over into the vault`);
      ph = 2;
    }
    if (ph === 2 && !s.makerRedeemed) {
      const ip = Number(await l1.read(c, "indexPlusOne", [maker.address]));
      if (ip) {
        const fin = loadFin(s.id);
        const n = Number(await l1.read(c, "userCount"));
        const dense = Array.from({ length: n }, (_, i) => leafHash(fin.get(i) ?? EMPTY));
        await l1.send(c, "redeem", [ip - 1, fin.get(ip - 1) ?? EMPTY, siblings(levels(dense), ip - 1), false], maker);
        note(`session ${s.id}: the maker redeemed its float`);
      }
      s.makerRedeemed = true;
      save();
    }
  }
  for (const s of app.sessions.slice(0, -1)) await closeOld(s);

  // ---- the app network: the executor imports the channel and the feed read-only ----
  const ex = await Chain.appExecutor(ROOT, 18902, APP_ID, l1.url, { readonly: [core.address, disputes.address, app.feed.proxy, app.feed.aggregator] });
  process.on("SIGINT", () => { if (NET === "local") l1.stop(); ex.stop(); process.exit(0); });
  const book = await ClearingOperator.deployBook(ex, l1, op, ch, app.feed, P.maxStale);
  const reader = new L1ReadView({ url: l1.url, chainId: l1.chainId, cli: CLI });
  const A = new ClearingOperator({
    view: reader, exec: ex, book, op, l1, channel: ch, anchors, feed: app.feed, maxStaleness: P.maxStale,
    evidence: new EvidenceStore(NET === "sepolia" ? join(homedir(), ".skim-devnet", `session-${id}-evidence`) : join(tmpdir(), `skim-devnet-evidence-${process.pid}`)),
    policy: P.policy, bond: P.bond, maxAnchorAge: 256n, ageMargin: 32n, startBlock,
    journal: NET === "sepolia" ? join(homedir(), ".skim-devnet", `session-${id}-journal.json`) : join(tmpdir(), `skim-devnet-journal-${process.pid}.json`),
  });
  if (resume) {
    A.fin = loadFin(id.toString());
    await A.restart();
    note(`session ${id}: AppState rebuilt on a fresh executor (${A.batches.length} journaled batch(es))`);
  }
  const gw = new Gateway(A, 18903);
  await gw.start();

  // ---- the market maker: funded on L1 like any user (once per session) ----
  const makerIn = Number(await l1.read(ch, "indexPlusOne", [maker.address])) > 0;
  const makerNeeds = P.makerEth + parseEther("0.005"); // its deposit, plus gas
  const makerHas = NET === "sepolia" ? await l1.pub.getBalance({ address: maker.address }) : makerNeeds;
  if (!makerIn && makerHas < makerNeeds) {
    await l1.wallet(op).sendTransaction({ to: maker.address, value: makerNeeds - makerHas }).then((h) => l1.pub.waitForTransactionReceipt({ hash: h }));
  }
  if (!makerIn) {
    await l1.send(ch, "deposit", [0, P.makerEth], maker, undefined, P.makerEth);
    await l1.send(token, "mint", [maker.address, P.makerUsd], maker);
    await l1.send(token, "approve", [ch.address, P.makerUsd], maker);
    await l1.send(ch, "deposit", [1, P.makerUsd], maker);
  }
  const appChain = defineChain({ id: APP_ID, name: "skim clearing (devnet)", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [gw.url] } } });
  const makerWallet = createWalletClient({ account: maker, chain: appChain, transport: http(gw.url), pollingInterval: 50 });
  const domain = { name: "SkimClearing", version: "0", chainId: APP_ID, verifyingContract: ch.address, salt: pad(toHex(id), { size: 32 }) };
  note(`${NET}: session ${id} channel ${ch.address}, book ${book.address}, feed ${app.feed.proxy}, maker ${maker.address}`);

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
  /** The feed now, as any L1 caller sees it (latest block; batches use their pinned block). */
  async function feedNow() {
    const [round, ans, , updatedAt] = await l1.read<any[]>(feedProxy, "latestRoundData");
    return { round: BigInt(round), price: BigInt(ans) / 100n, updatedAt: BigInt(updatedAt) };
  }
  /** The open batch's price (what the maker quotes against): the one the book pinned. */
  async function price() {
    const cur = A.batches.length ? A.current : undefined;
    if (cur) {
      const [, , p] = await ex.read<any[]>(book, "batchInfo", [BigInt(cur.no)]);
      if (p > 0n) return BigInt(p);
    }
    return (await feedNow()).price;
  }

  // Per batch: the L1 block it pinned, the price it used there, and every fill against it.
  async function batchView(b: (typeof A.batches)[number]) {
    const [anchorBlock, anchorTime, p] = await ex.read<any[]>(book, "batchInfo", [BigInt(b.no)]).catch(() => [0n, 0n, 0n]);
    const prep = b.prepared as any;
    const fills = b.log.filter((l) => (l.action as any).kind === "fill").map((l) => {
      const a = known.get((l.action as any).a)?.order, o = known.get((l.action as any).b)?.order;
      if (!a || !o || !p) return { ok: l.ok, error: l.error };
      const [e, u] = a.sellToken === 0 ? [a, o] : [o, a];
      const fp = (u.sellAmount * 10n ** 18n) / e.sellAmount;
      const diffPct = Number(((fp > p ? fp - p : p - fp) * 100_000n) / BigInt(p)) / 1000;
      return { ok: l.ok, error: l.error, seller: e.trader, buyer: u.trader, eth: e.sellAmount.toString(), price: fp.toString(), diffPct };
    });
    return {
      anchorBlock: String(anchorBlock), anchorTime: String(anchorTime), price: String(p),
      priceWitnessBytes: prep?.priceWitness ? (prep.priceWitness.package.length - 2) / 2 : 0, fills,
    };
  }

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

  /** Earlier sessions still closing: finish them (see closeOld). */
  async function settleOld() {
    for (const s of app.sessions.slice(0, -1)) if (!s.makerRedeemed) await closeOld(s);
  }

  /** Local only: Chainlink feeds update on a heartbeat; the local one re-transmits hourly (L1 time). */
  async function heartbeat() {
    if (NET !== "local") return;
    const f = await feedNow();
    const now = (await l1.pub.getBlock()).timestamp;
    if (now - f.updatedAt > 3600n) await l1.send(feedAgg, "transmit", [f.price * 100n], op);
  }

  // ---- the operator loop ----
  let openedAt = 0;
  let busy = false;
  let stage = "", stageAt = 0; // what the loop is waiting on (the watchdog reports it)
  const at_ = (x: string) => { stage = x; stageAt = Date.now(); };
  setInterval(() => { if (busy && Date.now() - stageAt > 60_000) note(`operator: still waiting on ${stage} after ${Math.round((Date.now() - stageAt) / 1000)} s`); }, 30_000);
  async function step() {
    if (busy) return;
    busy = true;
    try {
      at_("heartbeat"); await heartbeat();
      at_("earlier sessions"); await settleOld();
      at_("state"); const st = await l1.read<any[]>(ch, "state");
      if (Number(st[5]) === 2) return; // closed: users redeem on L1
      at_("tick"); const t = await A.tick();
      if (t.status === "recovered") note(`recovered batch ${t.from} (${t.reason}): ${t.dropped.length} action(s) dropped`);
      if (!A.batches.length || A.current.state !== "open") {
        at_("open"); await A.open();
        openedAt = Date.now();
      }
      learn();
      at_("maker"); await makeMarket();
      learn();
      at_("match"); await match();
      // Seal every 15 s when something happened; idle batches only re-pin the executor (no L1 tx).
      const cur = A.current;
      const pr = cur.prepared as any;
      const did = cur.log.length > 0 || (pr.depositUsers?.length ?? 0) > 0 || (pr.requests ?? 0) > 0 || (pr.forced?.orders?.length ?? 0) > 0;
      if (Date.now() - openedAt > 15_000) {
        if (did) {
          at_("seal"); await A.seal();
          at_("open"); await A.open();
        } else {
          at_("refresh"); const r = await A.recover(A.current.no, "refresh");
          if (r.status !== "recovered") note(`refresh: ${r.status}`);
        }
        openedAt = Date.now();
      }
      const pend = await l1.read<any>(ch, "pending");
      if (pend.at === 0n) {
        const next = A.batches.find((b) => b.state === "sealed");
        if (next) {
          try {
            at_("propose"); await A.propose(BigInt(next.no));
            note(`proposed batch ${next.no} to L1 (finalizable after the ${WINDOW / 60}-minute window)`);
          } catch (e: any) { note(`propose ${next.no}: ${String(e?.message ?? e).slice(0, 100)}`); }
        }
      } else {
        const now = (await l1.pub.getBlock()).timestamp;
        if (now >= pend.at + BigInt(WINDOW)) {
          at_("finalize"); await l1.send(ch, "finalize", [], op);
          await A.finalized();
          if ((await l1.read<bigint>(ch, "bondCredit", [op.address])) > 0n) await l1.send(ch, "withdrawBond", [], op);
          if (NET === "sepolia") writeFileSync(finFile(id.toString()), JSON.stringify(Object.fromEntries(A.fin), (_k, v) => (typeof v === "bigint" ? v.toString() : v)));
          note(`finalized on L1 (batches: ${(await l1.read<any[]>(ch, "state"))[3]})`);
        }
      }
    } catch (e: any) {
      note(`operator: ${String(e?.shortMessage ?? e?.message ?? e).slice(0, 160)}`);
    } finally {
      busy = false;
    }
  }
  setInterval(step, NET === "local" ? 2000 : 6000);

  // ---- HTTP: the app, the RPCs, the API ----
  const L1_ALLOWED = /^(eth_|net_|web3_)/;
  const L1_DENIED = new Set(["eth_sendTransaction", "eth_sign", "eth_signTransaction", "eth_signTypedData_v4", "eth_accounts"]);
  const page = () => readFileSync(new URL("./devnet/app.html", import.meta.url), "utf8");
  const lastFaucet = new Map<string, number>();
  const server = createServer(async (req, res) => {
    cors(res);
    if (req.method === "OPTIONS") return res.writeHead(204).end();
    const url = new URL(req.url ?? "/", "http://x");
    try {
      if (url.pathname === "/" || url.pathname === "/index.html") {
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        return res.end(page());
      }
      if (url.pathname === "/faucet") {
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        return res.end(readFileSync(new URL("./devnet/faucet.html", import.meta.url), "utf8"));
      }
      if (url.pathname.startsWith("/schematic/")) return asset(res, url.pathname);
      if (url.pathname === "/rpc/app") return proxy(req, res, gw.url, () => true);
      if (url.pathname === "/rpc/l1") return proxy(req, res, l1.url, (m) => L1_ALLOWED.test(m) && !L1_DENIED.has(m));
      if (url.pathname === "/api/config") {
        return json(res, {
          network: NET,
          l1: { chainId: l1.chainId, name: NET === "local" ? "Skim L1 devnet" : "Sepolia", rpc: "/rpc/l1", channel: ch.address, token: app.token, vault: app.vault, adapter: app.adapter, explorer: NET === "sepolia" ? "https://sepolia.etherscan.io" : null },
          feed: { ...app.feed, maxStaleness: Number(P.maxStale) },
          session: { id: id.toString(), previous: app.sessions.slice(0, -1) },
          bandBps: 100, maxAnchorAge: 256,
          app: { chainId: APP_ID, rpc: "/rpc/app", book: book.address },
          faucet: { eth: P.faucetEth.toString(), usd: P.faucetUsd.toString() },
          maker: maker.address, domain, challengeWindow: WINDOW, forceDelay: DAY,
          abi: { channel: ch.abi, book: book.abi, token: token.abi, vault: vault.abi },
        });
      }
      if (url.pathname === "/api/state") {
        const st = await l1.read<any[]>(ch, "state");
        const pend = await l1.read<any>(ch, "pending");
        const orders = [];
        for (const k of known.values()) orders.push({ ...k, resting: await ex.read<boolean>(book, "resting", [k.hash]) });
        const f = await feedNow();
        const ev = await ex.rpc<any>("executor_evidence").catch(() => undefined);
        const head = await l1.pub.getBlock();
        return json(res, {
          network: NET, price: (await price()).toString(), l1Block: head.number.toString(), l1Time: head.timestamp.toString(),
          phase: Number(st[5]), frozen: Number(st[5]) === 2, finalizedBatches: st[3].toString(),
          pending: pend.at === 0n ? null : { at: pend.at.toString(), proposer: pend.proposer, finalizableAt: (pend.at + BigInt(WINDOW)).toString() },
          feed: { round: f.round.toString(), price: f.price.toString(), updatedAt: f.updatedAt.toString() },
          executor: ev && { pin: ev.anchor, accounts: ev.accounts, slots: ev.slots.length, evidenceBytes: (ev.package.length - 2) / 2 },
          batches: await Promise.all(A.batches.slice(-8).map(async (b) => ({
            no: b.no, state: b.state, anchor: b.snap.number.toString(), anchorHash: b.snap.hash, actions: b.log.length,
            proposal: b.proposal, custody: await batchView(b).catch(() => undefined),
          }))),
          orders: orders.filter((o) => o.resting).slice(-30), log: log.slice(-40),
        });
      }
      if (url.pathname === "/api/leaf") {
        // The finalized leaf and its path, for claim (and redeem after close).
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
        if (!/^0x[0-9a-fA-F]{40}$/.test(String(address))) return json(res, { error: "not an address" }, 400);
        const last = lastFaucet.get(address.toLowerCase()) ?? 0;
        if (NET === "sepolia" && Date.now() - last < 3600_000) return json(res, { error: "one faucet request per address per hour on Sepolia" }, 429);
        lastFaucet.set(address.toLowerCase(), Date.now());
        if (P.faucetEth > 0n && (await l1.pub.getBalance({ address: op.address })) > P.faucetEth + parseEther("0.05")) {
          await l1.wallet(op).sendTransaction({ to: address, value: P.faucetEth }).then((h) => l1.pub.waitForTransactionReceipt({ hash: h }));
        }
        await l1.send(token, "mint", [address, P.faucetUsd], op);
        note(`faucet: ${fmtEth(P.faucetEth)} ETH and ${fmtUsd(P.faucetUsd)} USD (on ${NET === "local" ? "the L1 devnet" : "Sepolia"}) to ${address.slice(0, 8)}`);
        return json(res, { ok: true });
      }
      if (NET === "local" && req.method === "POST" && url.pathname === "/api/devnet/advance") {
        const { seconds } = await body(req);
        await l1.rpc("evm_increaseTime", [Number(seconds)]);
        await l1.rpc("anvil_mine", [toHex(1)]);
        note(`devnet: L1 time advanced ${seconds} s`);
        return json(res, { ok: true });
      }
      if (NET === "local" && req.method === "POST" && url.pathname === "/api/devnet/price") {
        const { price: p } = await body(req);
        await l1.send(feedAgg, "transmit", [answer8(Number(p))], op);
        note(`devnet: the local feed's aggregator transmitted ${p}`);
        return json(res, { ok: true });
      }
      res.writeHead(404).end("not found");
    } catch (e: any) {
      json(res, { error: String(e?.shortMessage ?? e?.message ?? e) }, 500);
    }
  });
  server.listen(PORT, "127.0.0.1", () => {
    note(`devnet (${NET}) ready: http://127.0.0.1:${PORT}  (tailscale serve --bg ${PORT})`);
  });
}

// ---- helpers ----------------------------------------------------------------------------------

const parseRawData = (raw: Hex): Hex => parseTransaction(raw).data ?? "0x";

const fmtPrice = (p: bigint) => (Number(p) / 1e6).toFixed(2);
const fmtEth = (x: bigint) => (Number(x) / 1e18).toString();
const fmtUsd = (x: bigint) => (Number(x) / 1e6).toFixed(2);
const str = (o: any) => JSON.parse(JSON.stringify(o, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));

// The vendored design system (ts/devnet/schematic): one stylesheet and its fonts.
function asset(res: ServerResponse, path: string) {
  const name = path.slice("/schematic/".length);
  if (!/^(styles\.css|favicon\.svg|fonts\/[a-z0-9-]+\.woff2)$/.test(name)) return res.writeHead(404).end("not found");
  const type = name.endsWith(".css") ? "text/css; charset=utf-8" : name.endsWith(".svg") ? "image/svg+xml" : "font/woff2";
  res.writeHead(200, { "content-type": type, "cache-control": "public, max-age=3600" });
  res.end(readFileSync(new URL(`./devnet/schematic/${name}`, import.meta.url)));
}

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

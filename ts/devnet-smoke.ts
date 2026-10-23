// Smoke test for a running devnet (npm run devnet), through its public HTTP endpoints only —
// the same calls the browser app and a wallet make. Run: npm run devnet-smoke [URL]
import { createPublicClient, createWalletClient, defineChain, http, parseEther, parseUnits, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const BASE = process.argv[2] ?? "http://127.0.0.1:8787";
const cfg = await (await fetch(`${BASE}/api/config`)).json();
const l1Chain = defineChain({ id: cfg.l1.chainId, name: "l1", nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [BASE + cfg.l1.rpc] } } });
const appChain = defineChain({ id: cfg.app.chainId, name: "app", nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [BASE + cfg.app.rpc] } } });
const l1 = createPublicClient({ chain: l1Chain, transport: http(), pollingInterval: 200 });
const app = createPublicClient({ chain: appChain, transport: http(), pollingInterval: 200 });
const me = privateKeyToAccount(generatePrivateKey()); // a fresh user, like a new wallet
const wl1 = createWalletClient({ account: me, chain: l1Chain, transport: http() });
const wapp = createWalletClient({ account: me, chain: appChain, transport: http() });
const types = { Order: [
  { name: "trader", type: "address" }, { name: "sellToken", type: "uint8" }, { name: "sellAmount", type: "uint128" },
  { name: "buyAmount", type: "uint128" }, { name: "nonce", type: "uint64" }, { name: "expiry", type: "uint64" } ] };

function check(c: unknown, m: string) { if (!c) throw new Error(`FAILED: ${m}`); console.log(`ok  ${m}`); }
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function until<T>(what: string, f: () => Promise<T | undefined | false>, ms = 90_000): Promise<T> {
  const t0 = Date.now();
  for (;;) { const v = await f(); if (v) return v as T; if (Date.now() - t0 > ms) throw new Error(`FAILED: timed out waiting for ${what}`); await sleep(1000); }
}
const post = (p: string, b: unknown) => fetch(BASE + p, { method: "POST", body: JSON.stringify(b) });
async function tx(w: any, pub: any, address: Hex, abi: any, functionName: string, args: unknown[], value?: bigint) {
  const hash = await w.writeContract({ address, abi, functionName, args, value });
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`${functionName} reverted`);
}
const account = async () => app.request({ method: "clearing_account" as any, params: [me.address] as any }) as Promise<any>;

check((await post("/api/faucet", { address: me.address })).ok, "faucet funded a fresh wallet on L1");
await tx(wl1, l1, cfg.l1.channel, cfg.abi.channel, "deposit", [0, parseEther("1")], parseEther("1"));
await tx(wl1, l1, cfg.l1.token, cfg.abi.token, "approve", [cfg.l1.channel, parseUnits("4000", 6)]);
await tx(wl1, l1, cfg.l1.channel, cfg.abi.channel, "deposit", [1, parseUnits("4000", 6)]);
check(true, "deposited 1 ETH and 4,000 USD on L1 (through /rpc/l1)");
await until("deposits on the app network", async () => (await account())?.pending?.eth && BigInt((await account()).pending.eth) === parseEther("1"));
check(true, "the next batch applied them: eth_getBalance on the app network = " + (await app.getBalance({ address: me.address })) + " wei");

const price = BigInt((await (await fetch(BASE + "/api/state")).json()).price);
const o = { trader: me.address, sellToken: 0, sellAmount: parseEther("0.1"), buyAmount: price / 10n, nonce: BigInt(Date.now()), expiry: 10n ** 12n };
const sig = await me.signTypedData({ domain: cfg.domain, types, primaryType: "Order", message: o as any });
await tx(wapp, app, cfg.app.book, cfg.abi.book, "submitOrder", [o, sig]);
check(true, `placed "sell 0.1 ETH @ ${Number(price) / 1e6}" with a typed signature + an ordinary app-network transaction`);
await until("the maker's answer and the fill", async () => BigInt((await account()).pending.eth) === parseEther("0.9"));
const acc = await account();
check(BigInt(acc.pending.usd) === parseUnits("4000", 6) + price / 10n, `filled: pending 0.9 ETH, ${Number(BigInt(acc.pending.usd)) / 1e6} USD`);

await tx(wl1, l1, cfg.l1.channel, cfg.abi.channel, "requestWithdraw", [0, parseEther("0.5")]);
check(true, "requested 0.5 ETH on L1");
await until("the request served in a batch", async () => BigInt((await account()).pending.ethOut) === parseEther("0.5"));
// Fast-forward L1 past challenge windows until the batch with the request is final.
await until("finalization of the withdrawal", async () => {
  await post("/api/devnet/advance", { seconds: 3700 });
  await sleep(3000);
  const a = await account();
  return a?.finalized && BigInt(a.finalized.ethOut) === parseEther("0.5");
}, 240_000);
const leaf = await (await fetch(`${BASE}/api/leaf?address=${me.address}`)).json();
const l = Object.fromEntries(Object.entries(leaf.leaf).map(([k, v]) => [k, k === "requests" ? Number(v) : BigInt(v as string)]));
const before = await l1.getBalance({ address: me.address });
await tx(wl1, l1, cfg.l1.channel, cfg.abi.channel, "claim", [leaf.idx, l, leaf.siblings]);
const got = (await l1.getBalance({ address: me.address })) - before;
check(got > parseEther("0.49") && got <= parseEther("0.5"), `claimed ${Number(got) / 1e18} ETH on L1 (0.5 minus L1 gas)`);
console.log("DEVNET SMOKE PASSED");

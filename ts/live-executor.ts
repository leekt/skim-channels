// The app executor against live Sepolia through skim: an app contract calls Chainlink's real
// ETH/USD proxy at its Sepolia address; the executor reads the proxy and its aggregator from
// skim with proofs at the pin. Read-only on Sepolia: nothing is sent there.
// Run: SKIM_RPC=http://127.0.0.1:18545 npm run live-executor
import { createPublicClient, http, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Chain } from "./runtime/executor.ts";

const ROOT = new URL("..", import.meta.url).pathname;
const SKIM = process.env.SKIM_RPC ?? "http://127.0.0.1:18545";
const PROXY: Address = "0x694AA1769357215DE4FAC081bf1f309aDC325306";
const AGGREGATOR: Address = "0x719E22E3D4b690E5d96cCb40619180B5427F14AE";
const user = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");
const skim = createPublicClient({ transport: http(SKIM) });
const ABI = [{ type: "function", name: "latestRoundData", stateMutability: "view", inputs: [], outputs: [
  { type: "uint80" }, { type: "int256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint80" }] }] as const;

let failures = 0;
function check(c: unknown, m: string) { console.log(`${c ? "ok  " : "FAIL"} ${m}`); if (!c) failures++; }

async function run(imports: Address[], port: number) {
  const app = await Chain.appExecutor(ROOT, port, 7001, SKIM, imports, "latest");
  const reader = await app.deploy(ROOT, user, "Probes.sol", "FeedReader");
  return { app, reader };
}

const { app, reader } = await run([PROXY, AGGREGATOR], 18961);
try {
  const st = await app.rpc("executor_status");
  const t0 = Date.now();
  const [answer, updatedAt] = await app.pub.readContract({ address: reader.address, abi: reader.abi, functionName: "price", args: [PROXY] }) as [bigint, bigint];
  const ms = Date.now() - t0;
  const onSepolia = await skim.readContract({ address: PROXY, abi: ABI, functionName: "latestRoundData", blockNumber: BigInt(st.pin.number) });
  check(answer === onSepolia[1] && updatedAt === onSepolia[3],
    `the app's latestRoundData() through Chainlink's Sepolia proxy = ${Number(answer) / 1e8} USD (updated ${new Date(Number(updatedAt) * 1000).toISOString()}), same as Sepolia at block ${st.pin.number} (${ms} ms, cold)`);
  const ev = await app.rpc("executor_evidence");
  console.log(`     evidence: ${ev.accounts.length} accounts (${ev.accounts.map((a: any) => `${a.address.slice(0, 8)}… ${a.codeBytes} B code`).join(", ")}), ${ev.slots.length} slots, ${(ev.package.length - 2) / 2} bytes`);

  await app.wallet(user).writeContract({ address: reader.address, abi: reader.abi, functionName: "bump", args: [] }).then((h) => app.pub.waitForTransactionReceipt({ hash: h }));
  await new Promise((r) => setTimeout(r, 13_000));
  const moved = await app.rpc("executor_pin", ["latest"]);
  const [a2] = await app.pub.readContract({ address: reader.address, abi: reader.abi, functionName: "price", args: [PROXY] }) as [bigint];
  const reads = await app.pub.readContract({ address: reader.address, abi: reader.abi, functionName: "reads", args: [] });
  check(moved.number > st.pin.number && reads === 1n && a2 > 0n, `pin moved ${st.pin.number} → ${moved.number}; app state kept (reads = 1); price read again at the new pin: ${Number(a2) / 1e8}`);
} finally {
  app.stop();
}

// Only the proxy imported: its call into the aggregator meets an empty account and reverts.
const narrow = await run([PROXY], 18962);
try {
  const e = await narrow.app.pub.readContract({ address: narrow.reader.address, abi: narrow.reader.abi, functionName: "price", args: [PROXY] }).then(() => undefined, (x) => x);
  check(e !== undefined, "with only the proxy imported, the read reverts: the aggregator it calls isn't part of the app's L1 surface");
} finally {
  narrow.app.stop();
}
if (failures) { console.log(`${failures} FAILED`); process.exit(1); }
console.log("LIVE EXECUTOR PASSED");

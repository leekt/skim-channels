// The app executor's L1 import rules, end to end (crates/app-executor), against an anvil L1:
// same-address calls into imported L1 contracts, a proxy (DELEGATECALL storage context),
// protected and overlay writes, STATICCALL, value and sender protection, unsubscribed
// addresses, app state across pin moves, a refused pin move on conflict, evidence, snapshots,
// and failing closed when L1 can't answer.
// Run: npm run e2e-executor  (needs anvil, forge build, cargo build -p app-executor)
import { decodeErrorResult, encodeFunctionData, keccak256, encodeAbiParameters, parseAbi, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Chain } from "./runtime/executor.ts";

const ROOT = new URL("..", import.meta.url).pathname;
const owner = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"); // L1 deployer
const appUser = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");
const ERRORS = parseAbi(["error L1SlotProtected(address account, bytes32 slot)", "error L1AccountProtected(address account)"]);
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

let failures = 0;
function check(c: unknown, m: string) {
  console.log(`${c ? "ok  " : "FAIL"} ${m}`);
  if (!c) failures++;
}
async function rejects(p: Promise<unknown>): Promise<any> {
  try { await p; return undefined; } catch (e) { return e; }
}
const revertData = (e: any): Hex | undefined => {
  for (let x = e; x; x = x.cause) if (typeof x.data === "string" && x.data.startsWith("0x")) return x.data;
  for (let x = e; x; x = x.cause) if (typeof x.data?.data === "string") return x.data.data;
  return undefined;
};
const decoded = (e: any): { errorName: string; args: readonly unknown[] } | undefined => {
  for (let x = e; x; x = x.cause) if (x.data?.errorName) return x.data;
  const d = revertData(e);
  try { return d ? decodeErrorResult({ abi: ERRORS, data: d }) as any : undefined; } catch { return undefined; }
};
const noteSlot = (k: bigint) => keccak256(encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [k, 1n]));

const l1 = await Chain.anvil(18941, 900);
let app: Chain | undefined;
try {
  // ---- L1: a feed, a proxy in front of another feed, and one contract nobody imports ----
  const feed = await l1.deploy(ROOT, owner, "Probes.sol", "L1Feed", [42n]);
  const impl = await l1.deploy(ROOT, owner, "Probes.sol", "L1Feed", [0n]);
  const proxyC = await l1.deploy(ROOT, owner, "Probes.sol", "L1Proxy", [impl.address]);
  const proxy = { address: proxyC.address, abi: feed.abi };
  await l1.send(proxy, "set", [7n], owner);
  const other = await l1.deploy(ROOT, owner, "Probes.sol", "L1Feed", [5n]);

  app = await Chain.appExecutor(ROOT, 18942, 7001, l1.url, [feed.address, proxy.address, impl.address, owner.address], "latest", [[appUser.address, 10n ** 18n]]);
  const pin0 = await app.rpc("executor_status");
  const probe = await app.deploy(ROOT, appUser, "Probes.sol", "AppProbe");
  const call = (fn: string, args: unknown[] = [], value?: bigint) => app!.pub.readContract({ address: probe.address, abi: [...probe.abi, ...ERRORS], functionName: fn, args, account: appUser.address, ...(value ? { value } : {}) } as any) as Promise<any>;

  // ---- same-address calls ----
  check(await call("read", [feed.address]) === 42n, "the app calls L1Feed.latest() at its L1 address and gets L1's value (42)");
  check(await call("read", [proxy.address]) === 7n, "through the proxy: DELEGATECALL into the implementation, reading the proxy's storage (7)");
  const unsub = await rejects(call("read", [other.address]));
  check(unsub !== undefined, "a contract that isn't imported is empty on the app: calling it reverts");

  // ---- writes ----
  const set = await rejects(call("trySet", [feed.address, 1n]));
  const d1 = decoded(set);
  check(d1?.errorName === "L1SlotProtected" && (d1.args as any)[0].toLowerCase() === feed.address.toLowerCase() && BigInt((d1.args as any)[1]) === 0n,
    "writing a slot that is non-zero on L1 reverts: L1SlotProtected(feed, 0)");
  const d2 = decoded(await rejects(call("trySet", [proxy.address, 1n])));
  check(d2?.errorName === "L1SlotProtected" && (d2.args as any)[0].toLowerCase() === proxy.address.toLowerCase(),
    "through the proxy, the check is in the proxy's storage (the DELEGATECALL context), not the implementation's");
  const w = app.wallet(appUser);
  const tx = async (fn: string, args: unknown[]) => {
    const hash = await w.writeContract({ address: probe.address, abi: probe.abi, functionName: fn, args, gas: 1_000_000n } as any);
    return app!.pub.waitForTransactionReceipt({ hash });
  };
  const r1 = await tx("trySet", [feed.address, 1n]);
  check(r1.status === "reverted" && (await l1.read<bigint>(feed, "value")) === 42n && (await call("read", [feed.address])) === 42n,
    "as a transaction it is included and reverts; the app still reads 42");
  const r2 = await tx("tryNote", [proxy.address, 5n, 99n]);
  check(r2.status === "success" && (await call("noteOf", [proxy.address, 5n])) === 99n, "writing a slot that is zero on L1 goes into the overlay (notes[5] = 99)");
  const r3 = await tx("tryNote", [proxy.address, 5n, 100n]);
  check(r3.status === "success" && (await call("noteOf", [proxy.address, 5n])) === 100n,
    "writing it again is allowed: the check is against L1's value (0), not the overlay's (99)");
  check((await l1.read<bigint>(proxy, "notes", [5n])) === 0n, "L1 itself is unchanged");
  check((await call("staticNote", [proxy.address, 6n, 1n])) === false, "under STATICCALL the same write fails, as on any EVM");
  const pay = decoded(await rejects(call("pay", [feed.address], 1n)));
  check(pay?.errorName === "L1AccountProtected", "sending ETH to an imported account reverts: L1AccountProtected");
  const ownerTx = await rejects(app.wallet(owner).sendTransaction({ to: probe.address, data: "0x", gas: 100_000n }));
  check(String(ownerTx?.details ?? ownerTx?.message).includes("imported L1 account"), "a transaction from an imported account is refused (its nonce is L1's)");

  // ---- app state, then the pin moves ----
  await tx("record", [feed.address]);
  check((await call("count")) === 1n && (await call("lastSeen")) === 42n, "app state: count = 1, lastSeen = 42");
  await l1.send(feed, "set", [43n], owner);
  const moved = await app.rpc("executor_pin", ["latest"]);
  check(moved.number > pin0.pin.number && moved.overlayKept === 1, `the pin moves to L1 block ${moved.number}; the overlay slot is kept (still zero on L1)`);
  check((await call("read", [feed.address])) === 43n, "the app now reads L1's new value (43)");
  check((await call("count")) === 1n && (await call("noteOf", [proxy.address, 5n])) === 100n, "app state and the overlay carried over: count = 1, notes[5] = 100");

  const ev = await app.rpc("executor_evidence");
  const has = (a: string) => ev.accounts.some((x: any) => x.address.toLowerCase() === a.toLowerCase());
  const overlayProof = ev.slots.find((s: any) => s.account.toLowerCase() === proxy.address.toLowerCase() && s.slot === noteSlot(5n));
  check(ev.anchor.number === moved.number && has(feed.address) && has(proxy.address) && has(impl.address)
    && ev.accounts.find((x: any) => x.address.toLowerCase() === impl.address.toLowerCase()).codeBytes > 0,
    `evidence at the new pin: ${ev.accounts.length} accounts with code, ${ev.slots.length} slots, ${(ev.package.length - 2) / 2} bytes`);
  check(overlayProof && BigInt(overlayProof.value) === 0n, "evidence includes the zero proof behind the overlay slot at this pin");
  check(ev.slots.some((s: any) => s.slot === IMPL_SLOT), "and the proxy's implementation slot it read");

  // ---- conflict: L1 writes the slot the app wrote ----
  await l1.send(proxy, "note", [5n, 1n], owner);
  const conflict = await rejects(app.rpc("executor_pin", ["latest"]));
  const after = await app.rpc("executor_status");
  check(conflict?.code === -32010 || String(conflict?.message).includes("pin refused"), "L1 now holds a value at the overlay slot: the pin move is refused");
  check(after.pin.number === moved.number, "the previous pin is kept");
  check((await call("noteOf", [proxy.address, 5n])) === 100n && (await call("count")) === 1n, "and nothing was dropped: notes[5] = 100, count = 1");

  // ---- snapshots ----
  const snap = await app.rpc("evm_snapshot");
  await tx("record", [feed.address]);
  const c2 = await call("count");
  await app.rpc("evm_revert", [snap]);
  check(c2 === 2n && (await call("count")) === 1n, "evm_snapshot / evm_revert roll app state back");

  // ---- fail closed ----
  l1.stop();
  await new Promise((r) => setTimeout(r, 300));
  const down = await rejects(call("noteOf", [proxy.address, 777n]));
  check(String(down?.details ?? down?.message ?? "").includes("unavailable"), "a slot never fetched, with L1 unreachable, is an error, not zero");
} finally {
  app?.stop();
  l1.stop();
}
if (failures) { console.log(`${failures} FAILED`); process.exit(1); }
console.log("EXECUTOR E2E PASSED");

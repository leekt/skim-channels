// App channels on a real chain (docs/guide/app-channels.md, experiment 1), anvil Prague L1:
//   A. the operator disappears before the first proof: every deposit is refunded;
//   B. the operator disappears after two checkpoints: its state is DELETED, a late checkpoint is
//      refused by the one-day fence, the channel freezes, and every right is rebuilt from L1
//      events and calldata alone (`skim-channels app-recover`) and claimed. The vault ends empty.
// Proofs come from the labeled MOCK verifier: this exercises accounting and recovery, not
// execution validity. Run: cargo build -p channel-runner && npm run e2e-app
import { spawn, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import {
  createPublicClient, createWalletClient, http, defineChain, keccak256, toHex, parseEther,
  type Hex, type Address, type Abi,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const ROOT = new URL("..", import.meta.url).pathname;
const CLI = `${ROOT}target/debug/skim-channels`;
const URL_ = "http://127.0.0.1:18845";
const ETH = "0x0000000000000000000000000000000000000000" as Address;
const KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // operator
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // alice
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", // bob
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", // carol
  "0x47e5f8e46b54d6c1f8f6a4ca2f4b51a19b9a5bd2c1f6b9a2c1d4e5f6a7b8c9d0", // keeper (claims for others)
] as const;
const [op, alice, bob, carol, keeper] = KEYS.map((k) => privateKeyToAccount(k));
const chain = defineChain({ id: 31337, name: "l1", nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [URL_] } } });
const pub = createPublicClient({ chain, transport: http(), pollingInterval: 50 });
const wallet = (a: any) => createWalletClient({ account: a, chain, transport: http(), pollingInterval: 50 });

function art(file: string, name: string): { abi: Abi; bytecode: Hex } {
  const j = JSON.parse(readFileSync(`${ROOT}contracts/out/${file}/${name}.json`, "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
}
const cli = (...a: string[]) => JSON.parse(execFileSync(CLI, a, { encoding: "utf8" }));
function check(c: unknown, m: string) { if (!c) throw new Error(`FAILED: ${m}`); console.log(`ok  ${m}`); }
async function expectRevert(p: Promise<unknown>, m: string) {
  try { await p; } catch { console.log(`ok  ${m} (reverted)`); return; }
  throw new Error(`FAILED: ${m}: did not revert`);
}
const gas: Record<string, bigint> = {};
async function deploy(file: string, name: string, args: unknown[] = []) {
  const a = art(file, name);
  const r = await pub.waitForTransactionReceipt({ hash: await wallet(op).deployContract({ abi: a.abi, bytecode: a.bytecode, args } as any) });
  return { address: r.contractAddress as Address, abi: a.abi };
}
async function send(who: any, c: { address: Address; abi: Abi }, fn: string, args: unknown[], label?: string, value?: bigint) {
  const { request } = await pub.simulateContract({ account: who, address: c.address, abi: c.abi, functionName: fn, args, value });
  const r = await pub.waitForTransactionReceipt({ hash: await wallet(who).writeContract(request) });
  if (r.status !== "success") throw new Error(`${fn} failed`);
  if (label) gas[label] = r.gasUsed;
  return r;
}
async function warp(seconds: number) {
  await pub.request({ method: "evm_increaseTime" as any, params: [seconds] as any });
  await pub.request({ method: "evm_mine" as any, params: [] as any });
}

async function main() {
  const node = spawn("anvil", ["--port", "18845", "--hardfork", "prague", "--silent"], { stdio: "ignore" });
  try {
    await new Promise((r) => setTimeout(r, 1500));
    await pub.request({ method: "anvil_setBalance" as any, params: [keeper.address, toHex(parseEther("10"))] as any });
    await run();
  } finally {
    node.kill();
  }
}

async function run() {
  const anchors = await deploy("AnchorRegistry.sol", "AnchorRegistry");
  const mock = await deploy("MockAppCheckpointVerifier.sol", "MockAppCheckpointVerifier");
  const vault = await deploy("AppChannelVault.sol", "AppChannelVault", [anchors.address]);
  const usd = await deploy("AppChannelVault.t.sol", "TestToken");
  for (const u of [alice, bob, carol]) {
    await send(op, usd, "mint", [u.address, 1_000_000_000n]);
    await send(u, usd, "approve", [vault.address, 2n ** 255n]);
  }
  const usdBal = async (a: Address) => (await pub.readContract({ address: usd.address, abi: usd.abi, functionName: "balanceOf", args: [a] })) as bigint;
  const vaultHolds = async () => [await pub.getBalance({ address: vault.address }), await usdBal(vault.address)];

  async function open(salt: string) {
    const now = (await pub.getBlock()).timestamp;
    const cfg = { operator: op.address, verifier: mock.address, appConfigHash: keccak256(toHex("ledger-app")), closeDeadline: now + 30n * 86400n, payoutDelay: 3600, tokens: [ETH, usd.address] };
    const { result } = await pub.simulateContract({ account: op, address: vault.address, abi: vault.abi, functionName: "openChannel", args: [cfg, keccak256(toHex(salt))] });
    await send(op, vault, "openChannel", [cfg, keccak256(toHex(salt))], "openChannel");
    return result as Hex;
  }
  const depositEth = (u: any, id: Hex, v: bigint) => send(u, vault, "deposit", [id, ETH, v], "deposit ETH", v);
  const depositUsd = (u: any, id: Hex, v: bigint) => send(u, vault, "deposit", [id, usd.address, v], "deposit ERC-20");

  // ---- A: the operator never proves anything ----
  const a = await open("A");
  await depositEth(alice, a, parseEther("1"));
  await depositUsd(bob, a, 300_000_000n);
  await send(alice, vault, "forceExit", [a, ETH], "forceExit");
  await expectRevert(pub.simulateContract({ account: keeper, address: vault.address, abi: vault.abi, functionName: "freeze", args: [a] }), "A: freeze before the one-day deadline");
  await warp(86400);
  await send(keeper, vault, "freeze", [a], "freeze");
  const recA = cli("app-recover", "--rpc", URL_, "--vault", vault.address, "--channel", a);
  check(recA.recovered.nonce === 0 && recA.refundDeposits.length === 2, "A: recovery from L1 finds no checkpoints and 2 refundable deposits");
  const usdBobBefore = await usdBal(bob.address);
  for (const i of recA.refundDeposits) await send(keeper, vault, "refundDeposit", [a, BigInt(i)], "refundDeposit");
  check((await usdBal(bob.address)) - usdBobBefore === 300_000_000n, "A: bob's ERC-20 deposit refunded");

  // ---- B: two checkpoints, then the operator vanishes ----
  const b = await open("B");
  const dir = mkdtempSync(`${tmpdir()}/app-operator-`);
  const state = `${dir}/state.json`, acts = `${dir}/actions.json`;
  async function checkpoint(actions: unknown[], label: string) {
    writeFileSync(acts, JSON.stringify(actions));
    const args = ["app-checkpoint", "--rpc", URL_, "--vault", vault.address, "--channel", b, "--actions", acts];
    const out = cli(...args, ...(readFileSafe(state) ? ["--state", state] : []));
    const claim = { ...out.claim, depositCursor: BigInt(out.claim.depositCursor), forcedCursor: BigInt(out.claim.forcedCursor) };
    await send(op, vault, "submitCheckpoint", [b, claim, out.data, out.proof], label);
    gas[`${label} data bytes`] = BigInt((out.data.length - 2) / 2);
    writeFileSync(state, JSON.stringify(out.nextState));
    return { claim, out };
  }
  await depositEth(alice, b, parseEther("3"));
  await depositUsd(bob, b, 500_000_000n);
  await depositEth(carol, b, parseEther("1"));
  await checkpoint([], "submitCheckpoint #1");
  await checkpoint([
    { op: "transfer", from: alice.address, to: bob.address, token: ETH, amount: toHex(parseEther("1")) },
    { op: "transfer", from: bob.address, to: carol.address, token: usd.address, amount: toHex(200_000_000n) },
    { op: "withdraw", who: carol.address, token: usd.address, amount: toHex(50_000_000n) },
  ], "submitCheckpoint #2");
  // Carol's withdrawal credit is claimable now; proofs come from L1 data only.
  let rec = cli("app-recover", "--rpc", URL_, "--vault", vault.address, "--channel", b);
  const cr = rec.recovered.credits.find((c: any) => c.recipient.toLowerCase() === carol.address.toLowerCase());
  const usdCarol0 = await usdBal(carol.address);
  await send(keeper, vault, "claimCredit", [b, cr.recipient, cr.token, BigInt(cr.value), BigInt(cr.index), cr.siblings], "claimCredit");
  check((await usdBal(carol.address)) - usdCarol0 === 50_000_000n, "B: carol's withdrawal credit paid before any freeze");

  // A deposit the operator never consumes, a forced exit, then the operator disappears.
  await depositEth(bob, b, parseEther("4"));
  await send(bob, vault, "forceExit", [b, usd.address]);
  await warp(86400);
  writeFileSync(acts, "[]");
  const late = cli("app-checkpoint", "--rpc", URL_, "--vault", vault.address, "--channel", b, "--state", state, "--actions", acts);
  const lateClaim = { ...late.claim, depositCursor: BigInt(late.claim.depositCursor), forcedCursor: BigInt(late.claim.forcedCursor) };
  await expectRevert(pub.simulateContract({ account: op, address: vault.address, abi: vault.abi, functionName: "submitCheckpoint", args: [b, lateClaim, late.data, late.proof] }), "B: a late checkpoint that serves the request is refused after the deadline");
  rmSync(dir, { recursive: true, force: true }); // the operator's state is gone
  await send(keeper, vault, "freeze", [b]);
  rec = cli("app-recover", "--rpc", URL_, "--vault", vault.address, "--channel", b);
  check(rec.recovered.nonce === 2 && rec.refundDeposits.length === 1, "B: state rebuilt from L1 alone (2 checkpoints) and 1 unconsumed deposit found");
  const e0 = rec.recovered.exits[0];
  await expectRevert(pub.simulateContract({ account: keeper, address: vault.address, abi: vault.abi, functionName: "claimExit", args: [b, e0.recipient, e0.token, BigInt(e0.value), BigInt(e0.index), e0.siblings] }), "B: exits wait for the payout delay");
  await warp(3600);
  const before = { aliceEth: await pub.getBalance({ address: alice.address }), bobEth: await pub.getBalance({ address: bob.address }), bobUsd: await usdBal(bob.address), carolEth: await pub.getBalance({ address: carol.address }), carolUsd: await usdBal(carol.address) };
  for (const e of rec.recovered.exits) {
    await send(keeper, vault, "claimExit", [b, e.recipient, e.token, BigInt(e.value), BigInt(e.index), e.siblings], "claimExit");
  }
  for (const i of rec.refundDeposits) await send(keeper, vault, "refundDeposit", [b, BigInt(i)]);
  const after = { aliceEth: await pub.getBalance({ address: alice.address }), bobEth: await pub.getBalance({ address: bob.address }), bobUsd: await usdBal(bob.address), carolEth: await pub.getBalance({ address: carol.address }), carolUsd: await usdBal(carol.address) };
  check(after.aliceEth - before.aliceEth === parseEther("2"), "B: alice gets 2 ETH (3 deposited, 1 sent to bob)");
  check(after.bobEth - before.bobEth === parseEther("5"), "B: bob gets 1 ETH from alice + his unconsumed 4 ETH refunded");
  check(after.bobUsd - before.bobUsd === 300_000_000n, "B: bob gets 300 USD (500 − 200 to carol; his forced exit was never served)");
  check(after.carolEth - before.carolEth === parseEther("1") && after.carolUsd - before.carolUsd === 150_000_000n, "B: carol gets 1 ETH + 150 USD (200 − 50 already withdrawn)");
  const [ethLeft, usdLeft] = await vaultHolds();
  check(ethLeft === 0n && usdLeft === 0n, "vault holds nothing after both channels: every unit accounted for");

  mkdirSync(`${ROOT}docs/experiments/data`, { recursive: true });
  const outJ = Object.fromEntries(Object.entries(gas).map(([k, v]) => [k, Number(v)]));
  writeFileSync(`${ROOT}docs/experiments/data/app-channels-anvil.json`, JSON.stringify({
    note: "anvil Prague; AppChannelVault with the labeled MOCK verifier (no proof cost). Gas = receipt gasUsed; data bytes = published net diff.",
    measurements: outJ }, null, 2) + "\n");
  console.table(outJ);
  console.log("APP E2E PASSED");
}

function readFileSafe(p: string) { try { return readFileSync(p, "utf8"); } catch { return null; } }

main().catch((e) => { console.error(e); process.exit(1); });

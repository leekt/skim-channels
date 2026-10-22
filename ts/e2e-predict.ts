// Prediction rounds end to end on anvil (docs/guide/app-enforcement.md §1): the oracle is read
// through a real eth_getProof witness built by the skim-channels CLI at the resolution block,
// the operator's tree is built here independently of the contracts, a wrong proposal is
// challenged, a withdrawal is claimed, the operator disappears and users exit from L1 alone.
// The same round also runs directly on L1 (PredictionL1). Gas = receipt gasUsed.
// Run: npm run e2e-predict  (needs anvil, forge build, cargo build).
import { spawn, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import {
  createPublicClient, createWalletClient, http, encodeAbiParameters, encodePacked, keccak256, concat,
  defineChain, zeroHash, toHex, parseEther, type Hex, type Address, type Abi,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const ROOT = new URL("..", import.meta.url).pathname;
const CLI = `${ROOT}target/debug/skim-channels`;
const PORT = 18655, CHAIN_ID = 900;
const URL_ = `http://127.0.0.1:${PORT}`;
const KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
] as const;
const [op, watcher, ...users] = KEYS.map((k) => privateKeyToAccount(k));

const chain = defineChain({ id: CHAIN_ID, name: "l1", nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [URL_] } } });
const pub = createPublicClient({ chain, transport: http() });
const wallet = (a = op) => createWalletClient({ account: a, chain, transport: http() });

function artifact(file: string, name: string): { abi: Abi; bytecode: Hex } {
  const j = JSON.parse(readFileSync(`${ROOT}contracts/out/${file}/${name}.json`, "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
}
function check(cond: unknown, msg: string) {
  if (!cond) throw new Error(`FAILED: ${msg}`);
  console.log(`ok  ${msg}`);
}
async function expectRevert(p: Promise<unknown>, msg: string) {
  try { await p; } catch { console.log(`ok  ${msg} (reverted)`); return; }
  throw new Error(`FAILED: ${msg}: did not revert`);
}
const rpc = (method: string, params: unknown[] = []) => pub.request({ method: method as any, params: params as any });
const height = () => pub.getBlockNumber({ cacheTime: 0 });
async function mineTo(n: bigint) {
  const h = await height();
  if (h < n) await rpc("anvil_mine", [toHex(n - h)]);
}

type C = { address: Address; abi: Abi };
const gas: Record<string, number> = {};
async function deploy(file: string, name: string, args: unknown[] = []): Promise<C> {
  const a = artifact(file, name);
  const hash = await wallet().deployContract({ abi: a.abi, bytecode: a.bytecode, args } as any);
  const r = await pub.waitForTransactionReceipt({ hash });
  return { address: r.contractAddress as Address, abi: a.abi };
}
async function send(c: C, fn: string, args: unknown[], from = op, label?: string, value?: bigint) {
  const { request } = await pub.simulateContract({ account: from, address: c.address, abi: c.abi, functionName: fn, args, value });
  const hash = await wallet(from).writeContract(request);
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`${fn} failed`);
  if (label) gas[label] = (gas[label] ?? 0) + Number(r.gasUsed);
  return r;
}
const read = (c: C, fn: string, args: unknown[] = []) => pub.readContract({ address: c.address, abi: c.abi, functionName: fn, args }) as Promise<any>;

// ---- the operator's (and every watcher's) tree, independent of the contracts ----
const Z: Hex[] = [zeroHash];
for (let i = 0; i < 16; i++) Z.push(keccak256(concat([Z[i], Z[i]])));
function levels(leaves: Hex[]): Hex[][] {
  const L = [leaves];
  for (let l = 0; l < 16; l++) {
    const prev = L[l], next: Hex[] = [];
    for (let i = 0; i < prev.length; i += 2) next.push(keccak256(concat([prev[i], prev[i + 1] ?? Z[l]])));
    L.push(next);
  }
  return L;
}
const rootOf = (L: Hex[][]) => L[16][0] ?? Z[16];
function siblings(L: Hex[][], idx: number): Hex[] {
  const out: Hex[] = [];
  for (let l = 0; l < 16; l++, idx >>= 1) out.push(L[l][idx ^ 1] ?? Z[l]);
  return out;
}
/** The siblings SparseTree16.transition consumes for the (ascending) changed indices. */
function multiproof(L: Hex[][], indices: number[]): Hex[] {
  const out: Hex[] = [];
  let idx = [...indices];
  for (let l = 0; l < 16; l++) {
    const up: number[] = [];
    for (let i = 0; i < idx.length;) {
      const x = idx[i];
      if (x % 2 === 0 && idx[i + 1] === x + 1) i += 2;
      else { out.push(L[l][x ^ 1] ?? Z[l]); i += 1; }
      up.push(x >> 1);
    }
    idx = up;
  }
  return out;
}

type Leaf = { balance: bigint; cumWithdrawn: bigint; depositsApplied: bigint; requestsApplied: bigint };
type Part = { up: bigint; down: bigint; ticketHash: Hex };
const EMPTY: Leaf = { balance: 0n, cumWithdrawn: 0n, depositsApplied: 0n, requestsApplied: 0n };
const LEAF_TAG = keccak256(toHex("skim-predict/balance-leaf/v0"));
const PART_TAG = keccak256(toHex("skim-predict/participation-leaf/v0"));
const leafT = [{ type: "bytes32" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }] as const;
function leafHash(l: Leaf): Hex {
  if (!l.balance && !l.cumWithdrawn && !l.depositsApplied && !l.requestsApplied) return zeroHash;
  return keccak256(encodeAbiParameters(leafT, [LEAF_TAG, l.balance, l.cumWithdrawn, l.depositsApplied, l.requestsApplied]));
}
function partHash(p: Part): Hex {
  if (!p.up && !p.down && p.ticketHash === zeroHash) return zeroHash;
  return keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }, { type: "uint256" }, { type: "bytes32" }], [PART_TAG, p.up, p.down, p.ticketHash]));
}
const packLeaf = (l: Leaf) => encodePacked(["uint128", "uint128", "uint128", "uint32"], [l.balance, l.cumWithdrawn, l.depositsApplied, Number(l.requestsApplied)]);
function updates(fin: Leaf[], next: Leaf[]) {
  const L = levels(fin.map(leafHash));
  const idx = next.map((_, i) => i).filter((i) => leafHash(next[i]) !== leafHash(fin[i]));
  const packed = idx.length ? concat(idx.map((i) => concat([encodePacked(["uint32"], [i]), packLeaf(fin[i]), packLeaf(next[i])]))) : "0x";
  return { packed, proof: idx.length ? multiproof(L, idx) : [], newRoot: rootOf(levels(next.map(leafHash))) };
}
const leafAbi = { type: "tuple", components: [
  { name: "balance", type: "uint256" }, { name: "cumWithdrawn", type: "uint256" },
  { name: "depositsApplied", type: "uint256" }, { name: "requestsApplied", type: "uint256" },
] } as const;
const partAbi = { type: "tuple", components: [{ name: "up", type: "uint256" }, { name: "down", type: "uint256" }, { name: "ticketHash", type: "bytes32" }] } as const;
const sibAbi = { type: "bytes32[16]" } as const;

async function main() {
  const anvil = spawn("anvil", ["--port", `${PORT}`, "--chain-id", `${CHAIN_ID}`, "--hardfork", "prague", "--silent"], { stdio: "ignore" });
  try {
    await new Promise((r) => setTimeout(r, 1500));
    await run();
  } finally {
    anvil.kill();
  }
}

async function run() {
  const oracle = await deploy("AllocationFixture.sol", "AllocationFixture", [7000n]);
  const anchors = await deploy("AnchorRegistry.sol", "AnchorRegistry");
  const wv = await deploy("WitnessVerifier.sol", "WitnessVerifier");
  const rules = await deploy("PredictionRules.sol", "PredictionRules");
  const WINDOW = 3600n, BOND = parseEther("1");
  const ch = await deploy("PredictionChannel.sol", "PredictionChannel", [op.address, anchors.address, wv.address, rules.address, BOND, WINDOW]);
  const l1 = await deploy("PredictionL1.sol", "PredictionL1", [op.address, anchors.address, wv.address, rules.address]);
  await send(ch, "postBond", [], op, undefined, BOND);
  const SLOT = toHex(0, { size: 32 });

  // ---- deposits: three users, 10 ETH each ----
  for (const u of users) await send(ch, "deposit", [], u, "channel deposit (x3)", parseEther("10"));
  let fin: Leaf[] = users.map(() => EMPTY);

  // ---- round 1: tickets signed off-chain, only the latest per user reaches L1 ----
  const n0 = await height();
  const [DEADLINE, CH_END, RES] = [n0 + 6n, n0 + 9n, n0 + 12n];
  await send(ch, "openRound", [6500n, oracle.address, SLOT, 0, 256, DEADLINE, CH_END, RES], op, "openRound");
  const domain = { name: "SkimPrediction", version: "0", chainId: CHAIN_ID, verifyingContract: ch.address };
  const types = { Ticket: [{ name: "round", type: "uint256" }, { name: "up", type: "uint256" }, { name: "down", type: "uint256" }, { name: "nonce", type: "uint64" }] };
  const sign = (i: number, up: bigint, down: bigint, nonce: bigint) =>
    users[i].signTypedData({ domain, types, primaryType: "Ticket", message: { round: 1n, up, down, nonce } }).then((sig) => ({ idx: i, up, down, nonce, sig }));
  await sign(0, parseEther("1"), 0n, 1n); // A's first stake: superseded by ticket 2
  const tickets = [
    await sign(0, parseEther("2"), 0n, 2n),
    await sign(1, 0n, parseEther("3"), 1n),
    await sign(2, parseEther("1"), 0n, 1n),
  ];
  const packedTickets = concat(tickets.map((t) => encodePacked(["uint32", "uint128", "uint128", "uint64", "bytes"], [t.idx, t.up, t.down, t.nonce, t.sig])));
  await send(ch, "commit", [1n, packedTickets], op, "commit (3 users)");
  const parts: Part[] = tickets.map((t) => ({ up: t.up, down: t.down, ticketHash: keccak256(encodePacked(["uint64", "bytes"], [t.nonce, t.sig])) }));
  const PL = levels(parts.map(partHash));
  const round = await read(ch, "rounds", [1n]);
  check(round[10] === rootOf(PL), "L1 built the same participation root from the packed tickets");

  // ---- resolution: a real witness of the oracle slot at the resolution block ----
  await mineTo(RES + 1n);
  const resBlock = await pub.getBlock({ blockNumber: RES });
  const w = JSON.parse(execFileSync(CLI, ["witness", "--rpc", URL_, "--block-hash", resBlock.hash!, "--chain-id", `${CHAIN_ID}`, "--read", `${oracle.address}:${SLOT}`], { encoding: "utf8" }));
  await send(anchors, "record", [w.rawHeader], watcher, "AnchorRegistry.record");
  await send(ch, "resolve", [1n, w.package], watcher, "resolve (witness)");
  check((await read(ch, "rounds", [1n]))[1] === 1, "resolved UP from the L1 witness (7000 ≥ 6500)");

  // A 12, B 7, C 11: pot 6 split over UP 3.
  const next: Leaf[] = [
    { balance: parseEther("12"), cumWithdrawn: 0n, depositsApplied: parseEther("10"), requestsApplied: 0n },
    { balance: parseEther("7"), cumWithdrawn: 0n, depositsApplied: parseEther("10"), requestsApplied: 0n },
    { balance: parseEther("11"), cumWithdrawn: 0n, depositsApplied: parseEther("10"), requestsApplied: 0n },
  ];

  // ---- a wrong proposal (A overpaid by 1 wei) loses one O(1) challenge ----
  const bad = next.map((l, i) => (i === 0 ? { ...l, balance: l.balance + 1n } : l));
  const ub = updates(fin, bad);
  await send(ch, "propose", [1n, ub.packed, ub.proof], op, "propose (bad)");
  check((await read(ch, "pendingRoot")) === ub.newRoot, "L1 recomputed the proposed root from the packed leaves + multiproof");
  const evidence = (i: number, proposed: Leaf[]) => encodeAbiParameters(
    [leafAbi, sibAbi, leafAbi, sibAbi, partAbi, sibAbi],
    [fin[i], siblings(levels(fin.map(leafHash)), i), proposed[i], siblings(levels(proposed.map(leafHash)), i), parts[i], siblings(PL, i)] as any);
  await expectRevert(pub.simulateContract({ account: watcher, address: ch.address, abi: ch.abi, functionName: "challengeUpdate", args: [1, evidence(1, bad)] }), "B's leaf is correct: no challenge");
  const wBefore = await pub.getBalance({ address: watcher.address });
  await send(ch, "challengeUpdate", [0, evidence(0, bad)], watcher, "challengeUpdate");
  check((await pub.getBalance({ address: watcher.address })) > wBefore, "watcher won the bond");

  // ---- the honest proposal finalizes ----
  await send(ch, "postBond", [], op, undefined, BOND);
  const u1 = updates(fin, next);
  await send(ch, "propose", [1n, u1.packed, u1.proof], op, "propose (3 users)");
  await rpc("evm_increaseTime", [Number(WINDOW)]);
  await rpc("evm_mine");
  await send(ch, "finalize", [], watcher, "finalize");
  fin = next;
  check((await read(ch, "finalizedRoot")) === u1.newRoot, "finalized root = the operator's tree");

  // ---- normal withdrawal: A takes everything ----
  await send(ch, "requestWithdraw", [], users[0], "requestWithdraw");
  const wd = fin.map((l, i) => (i === 0 ? { ...l, balance: 0n, cumWithdrawn: l.balance, requestsApplied: 1n } : l));
  const u2 = updates(fin, wd);
  await send(ch, "propose", [0n, u2.packed, u2.proof], op, "propose (1 withdrawal)");
  await rpc("evm_increaseTime", [Number(WINDOW)]);
  await rpc("evm_mine");
  await send(ch, "finalize", [], watcher);
  fin = wd;
  const aBefore = await pub.getBalance({ address: users[0].address });
  await send(ch, "claim", [0, fin[0], siblings(levels(fin.map(leafHash)), 0)], watcher, "claim");
  check((await pub.getBalance({ address: users[0].address })) - aBefore === parseEther("12"), "A received 12 ETH");

  // ---- the operator disappears: B's request goes unanswered, anyone freezes, all exit ----
  await send(ch, "requestWithdraw", [], users[1], "requestWithdraw");
  const FL = levels(fin.map(leafHash));
  await expectRevert(pub.simulateContract({ account: watcher, address: ch.address, abi: ch.abi, functionName: "freeze", args: [1, fin[1], siblings(FL, 1)] }), "freeze before the one-day fence");
  await rpc("evm_increaseTime", [86400]);
  await rpc("evm_mine");
  await send(ch, "freeze", [1, fin[1], siblings(FL, 1)], watcher, "freeze");
  const none: Part = { up: 0n, down: 0n, ticketHash: zeroHash };
  const z = Array(16).fill(zeroHash);
  for (const [i, want] of [[1, parseEther("7")], [2, parseEther("11")]] as const) {
    const before = await pub.getBalance({ address: users[i].address });
    const r = await send(ch, "exit", [i, fin[i], siblings(FL, i), none, z], watcher, "exit");
    check((await pub.getBalance({ address: users[i].address })) - before === want, `user ${i} exited with ${Number(want) / 1e18} ETH, no operator`);
    r;
  }
  check((await pub.getBalance({ address: ch.address })) === BOND, "channel holds only the operator's bond");

  // ---- the same round directly on L1 ----
  for (const u of users) await send(l1, "deposit", [], u, "L1 deposit (x3)", parseEther("10"));
  const m0 = await height();
  await send(l1, "openRound", [6500n, oracle.address, SLOT, 0, 256, m0 + 6n, m0 + 8n], op, "L1 openRound");
  await send(l1, "stake", [1n, 1, parseEther("1")], users[0], "L1 stake (x4)");
  await send(l1, "stake", [1n, 1, parseEther("1")], users[0], "L1 stake (x4)");
  await send(l1, "stake", [1n, 2, parseEther("3")], users[1], "L1 stake (x4)");
  await send(l1, "stake", [1n, 1, parseEther("1")], users[2], "L1 stake (x4)");
  await mineTo(m0 + 9n);
  const res2 = await pub.getBlock({ blockNumber: m0 + 8n });
  const w2 = JSON.parse(execFileSync(CLI, ["witness", "--rpc", URL_, "--block-hash", res2.hash!, "--chain-id", `${CHAIN_ID}`, "--read", `${oracle.address}:${SLOT}`], { encoding: "utf8" }));
  await send(anchors, "record", [w2.rawHeader], watcher);
  await send(l1, "resolve", [1n, w2.package], watcher, "L1 resolve (witness)");
  for (const u of users) await send(l1, "collect", [1n], u, "L1 collect (x3)");
  check((await read(l1, "balance", [users[0].address])) === parseEther("12"), "L1 baseline: A 12 ETH, same payout rule");
  await send(l1, "withdraw", [parseEther("12")], users[0], "L1 withdraw");

  mkdirSync(`${ROOT}docs/experiments/data`, { recursive: true });
  writeFileSync(`${ROOT}docs/experiments/data/prediction-e2e.json`, JSON.stringify({
    note: "anvil prague, one round, 3 users (A: 2 stakes, B and C: 1). Gas = receipt gasUsed; (xN) rows are sums.",
    witnessPackageBytes: (w.package.length - 2) / 2,
    measurements: gas,
  }, null, 2) + "\n");
  console.table(gas);
  console.log("E2E PREDICT PASSED");
}

main().catch((e) => { console.error(e); process.exit(1); });

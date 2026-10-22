// Read-and-Split end to end on two real chains (PROJECT.md §9):
//   L1 = anvil (chain 900), L2 = anvil (chain 901), block acceptance = MOCK registry (labeled).
// Every L1 read is a real eth_getProof witness verified against a hash-checked header, the
// final outcome is a real L2 transaction, and settlement proves its receipt against the L2
// block's receipts root. Run: npm run e2e  (needs anvil, forge build, cargo build).
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import {
  createPublicClient, createWalletClient, http, encodeAbiParameters, keccak256, defineChain,
  type Hex, type Address, type Abi, parseEther, toHex, decodeAbiParameters,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const ROOT = new URL("..", import.meta.url).pathname;
const CLI = `${ROOT}target/debug/skim-channels`;
const L1_PORT = 18645, L2_PORT = 18646;
const L1_ID = 900, L2_ID = 901;
const L1_URL = `http://127.0.0.1:${L1_PORT}`, L2_URL = `http://127.0.0.1:${L2_PORT}`;
const KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
] as const;
const [ops, aliceAcct, bobAcct, carol] = KEYS.map((k) => privateKeyToAccount(k));

const l1 = defineChain({ id: L1_ID, name: "l1", nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [L1_URL] } } });
const l2 = defineChain({ id: L2_ID, name: "l2", nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [L2_URL] } } });
const pub1 = createPublicClient({ chain: l1, transport: http() });
const pub2 = createPublicClient({ chain: l2, transport: http() });
const w1 = (a = ops) => createWalletClient({ account: a, chain: l1, transport: http() });
const w2 = (a = ops) => createWalletClient({ account: a, chain: l2, transport: http() });

function artifact(file: string, name: string): { abi: Abi; bytecode: Hex } {
  const j = JSON.parse(readFileSync(`${ROOT}contracts/out/${file}/${name}.json`, "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
}
function cli(...args: string[]) {
  return JSON.parse(execFileSync(CLI, args, { encoding: "utf8" }));
}
function check(cond: unknown, msg: string) {
  if (!cond) throw new Error(`FAILED: ${msg}`);
  console.log(`ok  ${msg}`);
}
async function expectRevert(p: Promise<unknown>, msg: string) {
  try { await p; } catch { console.log(`ok  ${msg} (reverted)`); return; }
  throw new Error(`FAILED: ${msg}: did not revert`);
}

const gas: Record<string, bigint> = {};
async function deploy(w: ReturnType<typeof w1>, p: typeof pub1, file: string, name: string, args: unknown[] = []) {
  const a = artifact(file, name);
  const hash = await w.deployContract({ abi: a.abi, bytecode: a.bytecode, args } as any);
  const r = await p.waitForTransactionReceipt({ hash });
  gas[`deploy ${name}`] = r.gasUsed;
  return { address: r.contractAddress as Address, abi: a.abi };
}
async function send(w: any, p: any, c: { address: Address; abi: Abi }, fn: string, args: unknown[], label?: string, value?: bigint) {
  const { request } = await p.simulateContract({ account: w.account, address: c.address, abi: c.abi, functionName: fn, args, value });
  const hash = await w.writeContract(request);
  const r = await p.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`${fn} failed`);
  if (label) gas[label] = r.gasUsed;
  return r;
}

const termsT = { type: "tuple", components: [
  { name: "channelId", type: "bytes32" }, { name: "rollupId", type: "bytes32" },
  { name: "settlementContract", type: "address" }, { name: "executor", type: "address" },
  { name: "moduleCodeHash", type: "bytes32" }, { name: "participantRoot", type: "bytes32" },
  { name: "policyHash", type: "bytes32" }, { name: "closeDeadline", type: "uint64" },
] } as const;
const requestT = { type: "tuple", components: [
  { name: "channelId", type: "bytes32" }, { name: "termsHash", type: "bytes32" },
  { name: "anchorId", type: "bytes32" }, { name: "policyHash", type: "bytes32" },
  { name: "executionProfileHash", type: "bytes32" }, { name: "inputHash", type: "bytes32" },
  { name: "nonce", type: "uint64" },
] } as const;
const evidenceT = { type: "tuple", components: [
  { name: "l2BlockHash", type: "bytes32" }, { name: "l2Header", type: "bytes" },
  { name: "txIndex", type: "uint256" }, { name: "receipt", type: "bytes" },
  { name: "receiptProof", type: "bytes[]" }, { name: "logIndex", type: "uint256" },
  { name: "request", type: "bytes" }, { name: "outcome", type: "bytes" },
] } as const;
const eip712 = {
  FinalRequest: requestT.components.map((c) => ({ name: c.name, type: c.type })),
  ChannelTerms: termsT.components.map((c) => ({ name: c.name, type: c.type })),
  ChannelPolicy: [{ name: "anchorConfirmation", type: "uint8" }, { name: "maxAnchorLag", type: "uint32" }],
  ExecutionProfile: [
    { name: "rollupId", type: "bytes32" }, { name: "kind", type: "uint8" }, { name: "genesisHash", type: "bytes32" },
    { name: "programHash", type: "bytes32" }, { name: "forkSchemaHash", type: "bytes32" },
    { name: "daSchemaHash", type: "bytes32" }, { name: "executorCodeHash", type: "bytes32" },
  ],
} as const;

async function main() {
  const procs: ChildProcess[] = [L1_PORT, L2_PORT].map((port, i) =>
    spawn("anvil", ["--port", `${port}`, "--chain-id", `${[L1_ID, L2_ID][i]}`, "--hardfork", "prague", "--silent"], { stdio: "ignore" }));
  try {
    await new Promise((r) => setTimeout(r, 1500));
    await run();
  } finally {
    procs.forEach((p) => p.kill());
  }
}

async function run() {
  const { hashStruct } = await import("viem");
  const [alice, bob] = [aliceAcct, bobAcct].sort((a, b) => (BigInt(a.address) < BigInt(b.address) ? -1 : 1));
  const participants = [alice.address, bob.address] as Address[];
  const ROLLUP = keccak256(toHex("e2e-rollup"));

  // ---- L1 ----
  const fixture = await deploy(w1(), pub1, "AllocationFixture.sol", "AllocationFixture", [6000n]);
  const registry = await deploy(w1(), pub1, "MockAcceptedBlockRegistry.sol", "MockAcceptedBlockRegistry", [ops.address]);
  const anchors = await deploy(w1(), pub1, "AnchorRegistry.sol", "AnchorRegistry");
  // ---- L2 ----
  const inbox = await deploy(w2(), pub2, "L2AnchorInbox.sol", "L2AnchorInbox", [ops.address, BigInt(L1_ID)]);
  const split = await deploy(w2(), pub2, "SplitModule.sol", "SplitModule");
  const splitCodeHash = keccak256((await pub2.getCode({ address: split.address }))!);
  const profile = {
    rollupId: ROLLUP, kind: 0, genesisHash: (await pub2.getBlock({ blockNumber: 0n })).hash,
    programHash: keccak256(toHex("anvil-prague")), forkSchemaHash: keccak256(toHex("prague")),
    daSchemaHash: keccak256(toHex("none:mock-local")), executorCodeHash: keccak256(toHex("ChannelExecutor@e2e")),
  };
  const profileHash = hashStruct({ types: eip712, primaryType: "ExecutionProfile", data: profile });
  const executor = await deploy(w2(), pub2, "ChannelExecutor.sol", "ChannelExecutor", [profileHash, BigInt(L1_ID), inbox.address, [split.address]]);
  // The same SplitModule bytecode on L1, for emergency exits (same code hash).
  const splitL1 = await deploy(w1(), pub1, "SplitModule.sol", "SplitModule");
  const WINDOW = 600n;
  const settlement = await deploy(w1(), pub1, "ChannelSettlement.sol", "ChannelSettlement", [ROLLUP, profileHash, 0, registry.address, anchors.address, WINDOW, [splitL1.address]]);

  const policy = { anchorConfirmation: 0, maxAnchorLag: 64 }; // Latest: optimistic, local experiment only
  const policyHash = hashStruct({ types: eip712, primaryType: "ChannelPolicy", data: policy });
  const participantRoot = keccak256(encodeAbiParameters([{ type: "address[]" }], [participants]));

  async function openChannel(salt: Hex) {
    const now = (await pub1.getBlock()).timestamp;
    const tag = keccak256(toHex("skim-channels/channel-id/v0"));
    const channelId = keccak256(encodeAbiParameters(
      [{ type: "bytes32" }, { type: "uint256" }, { type: "address" }, { type: "address" }, { type: "bytes32" }],
      [tag, BigInt(L1_ID), settlement.address, alice.address, salt]));
    const terms = {
      channelId, rollupId: ROLLUP, settlementContract: settlement.address, executor: executor.address,
      moduleCodeHash: splitCodeHash, participantRoot, policyHash, closeDeadline: now + 3600n,
    };
    await send(w1(alice), pub1, settlement, "open", [encodeAbiParameters([termsT], [terms]), participants, [parseEther("1"), parseEther("1")], salt], "L1 open");
    for (const p of [alice, bob]) await send(w1(p), pub1, settlement, "fund", [channelId], "L1 fund", parseEther("1"));
    return { terms, termsHash: hashStruct({ types: eip712, primaryType: "ChannelTerms", data: terms }) };
  }

  const { terms, termsHash } = await openChannel(keccak256(toHex("channel-1")));
  check(true, `channel ${terms.channelId.slice(0, 10)}… opened and funded on L1 (2 ETH escrow)`);

  const input = encodeAbiParameters([{ type: "address" }, { type: "bytes32" }, { type: "uint256" }], [fixture.address, toHex(0, { size: 32 }), parseEther("2")]);
  async function callFor(blockHash: Hex) {
    const w = cli("witness", "--rpc", L1_URL, "--block-hash", blockHash, "--chain-id", `${L1_ID}`, "--read", `${fixture.address}:${toHex(0, { size: 32 })}`);
    await send(w2(), pub2, inbox, "post", [w.rawHeader], "L2 inbox post");
    const request = { channelId: terms.channelId, termsHash, anchorId: w.anchorId as Hex, policyHash, executionProfileHash: profileHash, inputHash: keccak256(input), nonce: 1n };
    const domain = { name: "SkimChannels", version: "0", chainId: L1_ID, verifyingContract: settlement.address };
    const signatures = await Promise.all([alice, bob].map((a) => a.signTypedData({ domain, types: { FinalRequest: eip712.FinalRequest }, primaryType: "FinalRequest", message: request })));
    const call = {
      terms: encodeAbiParameters([termsT], [terms]),
      policy: encodeAbiParameters([{ type: "tuple", components: [{ name: "a", type: "uint8" }, { name: "b", type: "uint32" }] }], [{ a: policy.anchorConfirmation, b: policy.maxAnchorLag }]),
      request: encodeAbiParameters([requestT], [request]), input, witness: w.package as Hex, participants, signatures,
    };
    return { call, request, witness: w };
  }
  const payouts = (o: Hex) => decodeAbiParameters([{ type: "uint256[]" }], o)[0];

  // ---- Execution A: preview at H0 ----
  const h0 = (await pub1.getBlock()).hash!;
  const a = await callFor(h0);
  const pA = payouts(await pub2.readContract({ address: executor.address, abi: executor.abi, functionName: "preview", args: [a.call] }) as Hex);
  check(pA[0] === parseEther("1.2") && pA[1] === parseEther("0.8"), "preview at H0 (shareBps 6000): 1.2 / 0.8");
  gas["witness package bytes (1 slot)"] = BigInt((a.witness.package.length - 2) / 2);

  // ---- L1 changes; Execution B at H1 on the same channel ----
  const r = await send(w1(), pub1, fixture, "setShareBps", [7000n]);
  const h1 = r.blockHash;
  const b = await callFor(h1);
  const pB = payouts(await pub2.readContract({ address: executor.address, abi: executor.abi, functionName: "preview", args: [b.call] }) as Hex);
  check(pB[0] === parseEther("1.4") && pB[1] === parseEther("0.6"), "preview at H1 (shareBps 7000): 1.4 / 0.6, no reopen");

  // ---- Final: real L2 transaction, mid-block among 30 other transactions ----
  const { request: execReq } = await pub2.simulateContract({ account: ops, address: executor.address, abi: executor.abi, functionName: "execute", args: [b.call] });
  await pub2.request({ method: "evm_setAutomine" as any, params: [false] as any });
  const filler = async (n: number) => {
    for (let i = 0; i < n; i++) await w2(carol).sendTransaction({ to: aliceAcct.address, value: 1n, data: toHex(`filler-${i}`) });
  };
  await filler(15);
  const txHash = await w2().writeContract(execReq);
  await filler(15);
  await pub2.request({ method: "evm_mine" as any, params: [] as any });
  await pub2.request({ method: "evm_setAutomine" as any, params: [true] as any });
  const execRcpt = await pub2.waitForTransactionReceipt({ hash: txHash });
  const l2Txs = (await pub2.getBlock({ blockHash: execRcpt.blockHash })).transactions.length;
  check(l2Txs === 31 && execRcpt.transactionIndex > 0, `execute is tx ${execRcpt.transactionIndex} of ${l2Txs} in its L2 block`);
  gas["L2 execute"] = execRcpt.gasUsed;
  const ev = cli("evidence", "--rpc", L2_URL, "--tx", txHash);
  check(ev.receiptsRoot === (await pub2.getBlock({ blockHash: ev.l2BlockHash })).receiptsRoot, "L2 receipt trie rebuilt to the block's receiptsRoot");
  const outcomeHex = encodeAbiParameters([{ type: "uint256[]" }], [pB]);
  const logIndex = 0;
  const evidence = encodeAbiParameters([evidenceT], [{
    l2BlockHash: ev.l2BlockHash, l2Header: ev.l2Header, txIndex: BigInt(ev.txIndex), receipt: ev.receipt,
    receiptProof: ev.receiptProof, logIndex: BigInt(logIndex), request: b.call.request, outcome: outcomeHex,
  }]);
  gas["evidence bytes (31-tx L2 block)"] = BigInt((evidence.length - 2) / 2);
  gas["receipt proof nodes"] = BigInt(ev.receiptProof.length);

  // BLOCKHASH(n) is only available from block n+1: an anchor is recorded after it.
  await pub1.request({ method: "evm_mine" as any, params: [] as any });
  // Not yet accepted on L1: rejected.
  await send(w1(), pub1, anchors, "record", [b.witness.rawHeader], "L1 anchor record");
  await expectRevert(pub1.simulateContract({ account: carol, address: settlement.address, abi: settlement.abi, functionName: "settle", args: [terms.channelId, evidence] }), "settle before the L2 block is accepted");

  // MOCK acceptance (operator assertion; M3 replaces this with native verification).
  const l2Block = await pub2.getBlock({ blockHash: ev.l2BlockHash });
  await send(w1(), pub1, registry, "mockAccept", [ROLLUP, ev.l2BlockHash, {
    parentHash: l2Block.parentHash, stateRoot: l2Block.stateRoot, receiptsRoot: l2Block.receiptsRoot,
    l1AnchorId: b.request.anchorId, executionProfileHash: profileHash, blockNumber: l2Block.number, accepted: true,
  }], "L1 mockAccept");

  await send(w1(carol), pub1, settlement, "settle", [terms.channelId, evidence], "L1 settle (31-tx L2 block)");
  const [wa, wb] = await Promise.all([alice, bob].map((p) => pub1.readContract({ address: settlement.address, abi: settlement.abi, functionName: "withdrawable", args: [p.address] }) as Promise<bigint>));
  check(wa === parseEther("1.4") && wb === parseEther("0.6"), "settled on L1: 1.4 / 0.6 credited");
  await expectRevert(pub1.simulateContract({ account: carol, address: settlement.address, abi: settlement.abi, functionName: "settle", args: [terms.channelId, evidence] }), "second settlement");
  const before = await pub1.getBalance({ address: alice.address });
  const wr = await send(w1(alice), pub1, settlement, "withdraw", [], "L1 withdraw");
  const after = await pub1.getBalance({ address: alice.address });
  check(after - before + wr.gasUsed * wr.effectiveGasPrice === parseEther("1.4"), "alice withdrew 1.4 ETH");

  // ---- Refund path: no evidence, deadline passes, anyone refunds ----
  const two = await openChannel(keccak256(toHex("channel-2")));
  await pub1.request({ method: "evm_increaseTime" as any, params: [3601] as any });
  await pub1.request({ method: "evm_mine" as any, params: [] as any });
  await send(w1(carol), pub1, settlement, "refund", [two.terms.channelId], "L1 refund");
  await expectRevert(pub1.simulateContract({ account: carol, address: settlement.address, abi: settlement.abi, functionName: "refund", args: [two.terms.channelId] }), "second refund");
  const rb = await pub1.readContract({ address: settlement.address, abi: settlement.abi, functionName: "withdrawable", args: [bob.address] }) as bigint;
  check(rb === parseEther("0.6") + parseEther("1"), "refund credited bob's 1 ETH deposit (on top of 0.6 unwithdrawn)");

  // ---- Emergency exit: no L2 at all. L1 re-executes the module against the H1 witness ----
  const three = await openChannel(keccak256(toHex("channel-3")));
  const exitReq = { channelId: three.terms.channelId, termsHash: three.termsHash, anchorId: b.request.anchorId, policyHash, executionProfileHash: profileHash, inputHash: keccak256(input), nonce: 1n };
  const exitDomain = { name: "SkimChannels", version: "0", chainId: L1_ID, verifyingContract: settlement.address };
  const exitSigs = await Promise.all([alice, bob].map((a) => a.signTypedData({ domain: exitDomain, types: { FinalRequest: eip712.FinalRequest }, primaryType: "FinalRequest", message: exitReq })));
  const exitReqBytes = encodeAbiParameters([requestT], [exitReq]);
  await send(w1(carol), pub1, settlement, "startExit", [three.terms.channelId, exitReqBytes, exitSigs], "L1 startExit");
  await expectRevert(pub1.simulateContract({ account: carol, address: settlement.address, abi: settlement.abi, functionName: "finalizeExit", args: [three.terms.channelId, exitReqBytes, input, b.witness.package] }), "finalizeExit inside the challenge window");
  await pub1.request({ method: "evm_increaseTime" as any, params: [Number(WINDOW)] as any });
  await pub1.request({ method: "evm_mine" as any, params: [] as any });
  const balBefore = await pub1.readContract({ address: settlement.address, abi: settlement.abi, functionName: "withdrawable", args: [alice.address] }) as bigint;
  await send(w1(carol), pub1, settlement, "finalizeExit", [three.terms.channelId, exitReqBytes, input, b.witness.package], "L1 finalizeExit");
  const balAfter = await pub1.readContract({ address: settlement.address, abi: settlement.abi, functionName: "withdrawable", args: [alice.address] }) as bigint;
  check(balAfter - balBefore === parseEther("1.4"), "emergency exit finalized on L1 alone: 1.4 credited (L1 re-executed the split)");

  // ---- Measurements ----
  mkdirSync(`${ROOT}experiments`, { recursive: true });
  const out = Object.fromEntries(Object.entries(gas).map(([k, v]) => [k, Number(v)]));
  writeFileSync(`${ROOT}experiments/e2e-mock-local.json`, JSON.stringify({
    note: "anvil prague L1+L2, MOCK block acceptance, Latest anchors (optimistic). Gas = receipt gasUsed; bytes = encoded length.",
    measurements: out,
  }, null, 2) + "\n");
  console.table(out);
  console.log("E2E PASSED");
}

main().catch((e) => { console.error(e); process.exit(1); });

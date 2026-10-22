// Read-and-Split settled through REAL native execution verification (profile
// native-reexecution-devnet): ethrex L1 with the EIP-8079-style EXECUTE precompile (0x0101) and
// an ethrex native L2 (lambdaclass/ethrex PR #6418). ethrex's NativeRollup.advance() re-executes
// every L2 block on L1; NativeRollupRegistry accepts our L2 block only from those verified state
// roots (EIP-2935 history proof). No mock registry or verifier is involved.
// Run: ETHREX=/path/to/ethrex/checkout npm run e2e-native  (needs a release build with l2 features)
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import {
  createPublicClient, createWalletClient, http, encodeAbiParameters, keccak256, defineChain, toHex,
  type Hex, type Address, type Abi, parseEther, decodeAbiParameters, hashStruct,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const ROOT = new URL("..", import.meta.url).pathname;
const ETHREX = process.env.ETHREX!;
const BIN = `${ETHREX}/target/release/ethrex`;
const CLI = `${ROOT}target/debug/skim-channels`;
const DATA = process.env.E2E_DATA ?? "/tmp/skim-channels-native";
const L1_URL = "http://127.0.0.1:28545", L2_URL = "http://127.0.0.1:21729";
const L1_KEY = "0x385c546456b6a603a1cfcaa9ec9494ba4832da08dd6bcf4de9a71e4a01b74924";
const L2_KEY = "0xbcdf20249abf0ed6d944c0288fad489e33f66b3960d9e6229c1cd214ed3bbe31";
const RELAYER = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const HISTORY = "0x0000F90827F1C53a10cb7A02335B175320002935" as Address;
const l1Ops = privateKeyToAccount(L1_KEY), l2Ops = privateKeyToAccount(L2_KEY);
const alice0 = privateKeyToAccount("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6");
const bob0 = privateKeyToAccount("0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a");

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
function artifact(file: string, name: string): { abi: Abi; bytecode: Hex } {
  const j = JSON.parse(readFileSync(`${ROOT}contracts/out/${file}/${name}.json`, "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
}
const cli = (...a: string[]) => JSON.parse(execFileSync(CLI, a, { encoding: "utf8" }));
function check(c: unknown, m: string) { if (!c) throw new Error(`FAILED: ${m}`); console.log(`ok  ${m}`); }
async function expectRevert(p: Promise<unknown>, m: string) {
  try { await p; } catch { console.log(`ok  ${m} (reverted)`); return; }
  throw new Error(`FAILED: ${m}: did not revert`);
}
async function rpcUp(url: string) {
  for (let i = 0; i < 120; i++) {
    try { await createPublicClient({ transport: http(url) }).getChainId(); return; } catch { await sleep(500); }
  }
  throw new Error(`${url} did not come up`);
}

const gas: Record<string, bigint> = {};
const procs: ChildProcess[] = [];

async function main() {
  rmSync(DATA, { recursive: true, force: true });
  mkdirSync(DATA, { recursive: true });
  procs.push(spawn(BIN, ["--network", `${ETHREX}/fixtures/genesis/l1_native.json`, "--http.port", "28545", "--http.addr", "127.0.0.1",
    "--authrpc.port", "28551", "--p2p.port", "30333", "--discovery.port", "30333", "--dev", "--datadir", `${DATA}/l1`],
    { cwd: ETHREX, stdio: ["ignore", "ignore", "ignore"] }));
  await rpcUp(L1_URL);
  const deployOut = execFileSync(BIN, ["l2", "deploy", "--eth-rpc-url", L1_URL, "--private-key", L1_KEY, "--native-rollups",
    "--native-rollups.relayer-pk", RELAYER, "--native-rollups.finality-delay", "0", "--l2-gas-limit", "15000000",
    "--genesis-l2-path", "fixtures/genesis/native_l2.json"], { cwd: ETHREX, encoding: "utf8" });
  const nativeAddr = (deployOut.match(/NativeRollup\.sol deployed at:\s*(0x[0-9a-fA-F]{40})/) ?? [])[1] as Address;
  check(nativeAddr, `ethrex NativeRollup.sol deployed at ${nativeAddr}`);
  procs.push(spawn(BIN, ["l2", "--native-rollups", "--native-rollups.contract-address", nativeAddr,
    "--native-rollups.relayer-pk", RELAYER, "--native-rollups.l1-pk", L1_KEY, "--network", "fixtures/genesis/native_l2.json",
    "--http.port", "21729", "--http.addr", "127.0.0.1", "--authrpc.port", "28552", "--p2p.port", "30334", "--discovery.port", "30334",
    "--datadir", `${DATA}/l2`, "--eth.rpc-url", L1_URL, "--no-monitor"], { cwd: ETHREX, stdio: ["ignore", "ignore", "ignore"] }));
  await rpcUp(L2_URL);

  const L1_ID = await createPublicClient({ transport: http(L1_URL) }).getChainId();
  const L2_ID = await createPublicClient({ transport: http(L2_URL) }).getChainId();
  const l1 = defineChain({ id: L1_ID, name: "l1", nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [L1_URL] } } });
  const l2 = defineChain({ id: L2_ID, name: "l2", nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [L2_URL] } } });
  const pub1 = createPublicClient({ chain: l1, transport: http() }), pub2 = createPublicClient({ chain: l2, transport: http() });
  const w1 = (a: any = l1Ops) => createWalletClient({ account: a, chain: l1, transport: http() });
  const w2 = (a: any = l2Ops) => createWalletClient({ account: a, chain: l2, transport: http() });
  const wait1 = (h: Hex) => pub1.waitForTransactionReceipt({ hash: h, timeout: 120_000 });
  const wait2 = (h: Hex) => pub2.waitForTransactionReceipt({ hash: h, timeout: 120_000 });
  async function deploy(w: any, p: any, file: string, name: string, args: unknown[] = []) {
    const a = artifact(file, name);
    const r = await p.waitForTransactionReceipt({ hash: await w.deployContract({ abi: a.abi, bytecode: a.bytecode, args }), timeout: 120_000 });
    if (r.status !== "success") throw new Error(`deploy ${name} failed`);
    return { address: r.contractAddress as Address, abi: a.abi };
  }
  async function send(w: any, p: any, c: { address: Address; abi: Abi }, fn: string, args: unknown[], label?: string, value?: bigint) {
    const { request } = await p.simulateContract({ account: w.account, address: c.address, abi: c.abi, functionName: fn, args, value });
    const r = await p.waitForTransactionReceipt({ hash: await w.writeContract(request), timeout: 120_000 });
    if (r.status !== "success") throw new Error(`${fn} failed`);
    if (label) gas[label] = r.gasUsed;
    return r;
  }

  const [alice, bob] = [alice0, bob0].sort((a, b) => (BigInt(a.address) < BigInt(b.address) ? -1 : 1));
  for (const p of [alice, bob]) await wait1(await w1().sendTransaction({ to: p.address, value: parseEther("5") }));
  const participants = [alice.address, bob.address] as Address[];
  const ROLLUP = keccak256(toHex("ethrex-native-l2"));
  const types = {
    FinalRequest: [
      { name: "channelId", type: "bytes32" }, { name: "termsHash", type: "bytes32" }, { name: "anchorId", type: "bytes32" },
      { name: "policyHash", type: "bytes32" }, { name: "executionProfileHash", type: "bytes32" }, { name: "inputHash", type: "bytes32" },
      { name: "nonce", type: "uint64" }],
    ChannelTerms: [
      { name: "channelId", type: "bytes32" }, { name: "rollupId", type: "bytes32" }, { name: "settlementContract", type: "address" },
      { name: "executor", type: "address" }, { name: "moduleCodeHash", type: "bytes32" }, { name: "participantRoot", type: "bytes32" },
      { name: "policyHash", type: "bytes32" }, { name: "closeDeadline", type: "uint64" }],
    ChannelPolicy: [{ name: "anchorConfirmation", type: "uint8" }, { name: "maxAnchorLag", type: "uint32" }],
    ExecutionProfile: [
      { name: "rollupId", type: "bytes32" }, { name: "kind", type: "uint8" }, { name: "genesisHash", type: "bytes32" },
      { name: "programHash", type: "bytes32" }, { name: "forkSchemaHash", type: "bytes32" }, { name: "daSchemaHash", type: "bytes32" },
      { name: "executorCodeHash", type: "bytes32" }],
  } as const;
  const tuple = (name: keyof typeof types) => ({ type: "tuple", components: types[name] }) as const;
  const evidenceT = { type: "tuple", components: [
    { name: "l2BlockHash", type: "bytes32" }, { name: "l2Header", type: "bytes" }, { name: "txIndex", type: "uint256" },
    { name: "receipt", type: "bytes" }, { name: "receiptProof", type: "bytes[]" }, { name: "logIndex", type: "uint256" },
    { name: "request", type: "bytes" }, { name: "outcome", type: "bytes" }] } as const;

  const profile = {
    rollupId: ROLLUP, kind: 1, genesisHash: (await pub2.getBlock({ blockNumber: 0n })).hash,
    programHash: keccak256(toHex("ethrex EXECUTE 0x0101 verify_stateless_new_payload (PR #6418)")),
    forkSchemaHash: keccak256(toHex("ethrex fixtures/genesis/native_l2.json")),
    daSchemaHash: keccak256(toHex("ethrex-native: SSZ StatelessInput in advance() calldata")),
    executorCodeHash: keccak256(toHex("ChannelExecutor@native-e2e")),
  };
  const profileHash = hashStruct({ types, primaryType: "ExecutionProfile", data: profile });

  // L1 (ethrex, EXECUTE enabled)
  const fixture = await deploy(w1(), pub1, "AllocationFixture.sol", "AllocationFixture", [6000n]);
  const anchors = await deploy(w1(), pub1, "AnchorRegistry.sol", "AnchorRegistry");
  const registry = await deploy(w1(), pub1, "NativeRollupRegistry.sol", "NativeRollupRegistry", [ROLLUP, profileHash, nativeAddr]);
  const splitL1 = await deploy(w1(), pub1, "SplitModule.sol", "SplitModule");
  const settlement = await deploy(w1(), pub1, "ChannelSettlement.sol", "ChannelSettlement", [ROLLUP, profileHash, 1, registry.address, anchors.address, 600n, [splitL1.address]]);
  // L2 (ethrex native)
  const inbox = await deploy(w2(), pub2, "L2AnchorInbox.sol", "L2AnchorInbox", [l2Ops.address, BigInt(L1_ID)]);
  const split = await deploy(w2(), pub2, "SplitModule.sol", "SplitModule");
  const executor = await deploy(w2(), pub2, "ChannelExecutor.sol", "ChannelExecutor", [profileHash, BigInt(L1_ID), inbox.address, [split.address]]);
  check(true, `contracts deployed on ethrex L1 (chain ${L1_ID}) and ethrex native L2 (chain ${L2_ID})`);

  const policy = { anchorConfirmation: 0, maxAnchorLag: 1000 };
  const policyHash = hashStruct({ types, primaryType: "ChannelPolicy", data: policy });
  const salt = keccak256(toHex("native-1"));
  const channelId = keccak256(encodeAbiParameters(
    [{ type: "bytes32" }, { type: "uint256" }, { type: "address" }, { type: "address" }, { type: "bytes32" }],
    [keccak256(toHex("skim-channels/channel-id/v0")), BigInt(L1_ID), settlement.address, alice.address, salt]));
  const terms = {
    channelId, rollupId: ROLLUP, settlementContract: settlement.address, executor: executor.address,
    moduleCodeHash: keccak256((await pub2.getCode({ address: split.address }))!),
    participantRoot: keccak256(encodeAbiParameters([{ type: "address[]" }], [participants])), policyHash,
    closeDeadline: (await pub1.getBlock()).timestamp + 7200n,
  };
  const termsHash = hashStruct({ types, primaryType: "ChannelTerms", data: terms });
  await send(w1(alice), pub1, settlement, "open", [encodeAbiParameters([tuple("ChannelTerms")], [terms]), participants, [parseEther("1"), parseEther("1")], salt]);
  for (const p of [alice, bob]) await send(w1(p), pub1, settlement, "fund", [channelId], undefined, parseEther("1"));

  const h1 = (await send(w1(), pub1, fixture, "setShareBps", [7000n])).blockHash;
  const wit = cli("witness", "--rpc", L1_URL, "--block-hash", h1, "--chain-id", `${L1_ID}`, "--read", `${fixture.address}:${toHex(0, { size: 32 })}`);
  check(true, `H1 witness from ethrex L1 eth_getProof, verified against the hash-checked header`);
  await send(w2(), pub2, inbox, "post", [wit.rawHeader]);
  const input = encodeAbiParameters([{ type: "address" }, { type: "bytes32" }, { type: "uint256" }], [fixture.address, toHex(0, { size: 32 }), parseEther("2")]);
  const request = { channelId, termsHash, anchorId: wit.anchorId as Hex, policyHash, executionProfileHash: profileHash, inputHash: keccak256(input), nonce: 1n };
  const domain = { name: "SkimChannels", version: "0", chainId: L1_ID, verifyingContract: settlement.address };
  const signatures = await Promise.all([alice, bob].map((a) => a.signTypedData({ domain, types: { FinalRequest: types.FinalRequest }, primaryType: "FinalRequest", message: request })));
  const call = {
    terms: encodeAbiParameters([tuple("ChannelTerms")], [terms]),
    policy: encodeAbiParameters([tuple("ChannelPolicy")], [policy]),
    request: encodeAbiParameters([tuple("FinalRequest")], [request]), input, witness: wit.package as Hex, participants, signatures,
  };
  const execRcpt = await send(w2(), pub2, executor, "execute", [call], "L2 execute (ethrex native)");
  const ev = cli("evidence", "--rpc", L2_URL, "--tx", execRcpt.transactionHash);
  check(true, `L2 receipt evidence: block ${ev.blockNumber}, tx ${ev.txIndex}, receipts root rebuilt`);
  const [payouts] = decodeAbiParameters([{ type: "uint256[]" }], (await pub2.readContract({ address: executor.address, abi: executor.abi, functionName: "preview", args: [call] })) as Hex);
  const outcome = encodeAbiParameters([{ type: "uint256[]" }], [payouts]);
  const evidence = encodeAbiParameters([evidenceT], [{ l2BlockHash: ev.l2BlockHash, l2Header: ev.l2Header, txIndex: BigInt(ev.txIndex),
    receipt: ev.receipt, receiptProof: ev.receiptProof, logIndex: 0n, request: call.request, outcome }]);

  await send(w1(), pub1, anchors, "record", [wit.rawHeader], "L1 anchor record");
  await expectRevert(pub1.simulateContract({ account: l1Ops, address: settlement.address, abi: settlement.abi, functionName: "settle", args: [channelId, evidence] }), "settle before L1 re-executed the L2 block");

  // Wait until ethrex's advancer has re-executed past our block on L1 (EXECUTE precompile).
  const nativeAbi = [{ type: "function", name: "blockNumber", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
    { type: "function", name: "stateRootHistory", inputs: [{ type: "uint256" }], outputs: [{ type: "bytes32" }], stateMutability: "view" }] as const;
  const target = BigInt(ev.blockNumber);
  let verified = 0n;
  for (let i = 0; i < 240 && verified <= target; i++) {
    verified = await pub1.readContract({ address: nativeAddr, abi: nativeAbi, functionName: "blockNumber" }) as bigint;
    if (verified <= target) await sleep(1000);
  }
  check(verified > target, `ethrex L1 re-executed L2 through block ${verified} (ours: ${target})`);
  const laterRoot = await pub1.readContract({ address: nativeAddr, abi: nativeAbi, functionName: "stateRootHistory", args: [verified] });
  const l2Later = await pub2.getBlock({ blockNumber: verified });
  check(laterRoot === l2Later.stateRoot, "L1-verified state root equals the L2's own state root at that height");

  const slot = toHex(target % 8191n, { size: 32 });
  const proof: any = await pub2.request({ method: "eth_getProof" as any, params: [HISTORY, [slot], toHex(verified)] as any });
  await send(w1(), pub1, registry, "acceptHistorical", [ev.l2Header, verified, proof.accountProof, proof.storageProof[0].proof], "L1 acceptHistorical (EIP-2935 proof)");
  await send(w1(), pub1, settlement, "settle", [channelId, evidence], "L1 settle (native profile)");
  const wa = await pub1.readContract({ address: settlement.address, abi: settlement.abi, functionName: "withdrawable", args: [participants[0]] }) as bigint;
  const wb = await pub1.readContract({ address: settlement.address, abi: settlement.abi, functionName: "withdrawable", args: [participants[1]] }) as bigint;
  check(wa === parseEther("1.4") && wb === parseEther("0.6"), "settled under native-reexecution-devnet: 1.4 / 0.6");
  await expectRevert(pub1.simulateContract({ account: l1Ops, address: settlement.address, abi: settlement.abi, functionName: "settle", args: [channelId, evidence] }), "second settlement");

  mkdirSync(`${ROOT}experiments`, { recursive: true });
  const out = Object.fromEntries(Object.entries(gas).map(([k, v]) => [k, Number(v)]));
  writeFileSync(`${ROOT}experiments/e2e-native-ethrex.json`, JSON.stringify({
    note: "ethrex L1 (EXECUTE 0x0101) + ethrex native L2, PR #6418 PoC; NativeRollupRegistry; no mocks in block acceptance. L2 anchor feed is still the labeled mock inbox.",
    measurements: out }, null, 2) + "\n");
  console.table(out);
  console.log("NATIVE E2E PASSED");
}

main().then(() => procs.forEach((p) => p.kill()), (e) => { console.error(e); procs.forEach((p) => p.kill()); process.exit(1); });

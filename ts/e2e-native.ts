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
  type Hex, type Address, type Abi, parseEther, decodeAbiParameters, hashStruct, encodePacked, concat, decodeFunctionData, getContractAddress,
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
// L1_KEY is ethrex's own deployer/advancer key: our L1 transactions use a different funded key
// so they never race the advancer for nonces.
const l1Ops = privateKeyToAccount(L2_KEY), l2Ops = privateKeyToAccount(L2_KEY);
const carol = privateKeyToAccount("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6");
const alice0 = privateKeyToAccount("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba");
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
  procs.push(spawn(BIN, ["--network", `${ETHREX}/fixtures/genesis/l1_native.json`, "--http.port", "28545", "--http.addr", "127.0.0.1", "--http.api", "eth,net,web3,debug",
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
    "--http.port", "21729", "--http.addr", "127.0.0.1", "--http.api", "eth,net,web3,debug", "--authrpc.port", "28552", "--p2p.port", "30334", "--discovery.port", "30334",
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
    // Explicit limit (under EIP-7825's 2^24 cap): estimates for large deployments under
    // Amsterdam pricing came out too tight on ethrex (a "success" receipt with no contract).
    const hash = await w.deployContract({ abi: a.abi, bytecode: a.bytecode, args, gas: p === pub1 ? 16_000_000n : undefined });
    const r = await p.waitForTransactionReceipt({ hash, timeout: 120_000 });
    if (r.status !== "success" || !r.contractAddress) {
      const tx = await p.getTransaction({ hash });
      const addr = getContractAddress({ from: tx.from, nonce: BigInt(tx.nonce) });
      const code = await p.getCode({ address: addr });
      throw new Error(`deploy ${name} failed: ${r.status}, gas ${r.gasUsed}/${tx.gas}, address ${r.contractAddress}, code at ${addr}: ${code ? (code.length - 2) / 2 : 0} B`);
    }
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
  for (const p of [alice, bob, carol]) await wait1(await w1().sendTransaction({ to: p.address, value: parseEther("5") }));
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
  // The permissionless, governed registry, verified by EXECUTE itself.
  const anchorSender = await deploy(w1(), pub1, "AnchorSender.sol", "AnchorSender", [nativeAddr, anchors.address]);
  const msgQueue = await deploy(w1(), pub1, "NativeRollupMessageQueue.sol", "NativeRollupMessageQueue", [nativeAddr]);
  const execV = await deploy(w1(), pub1, "ExecuteVerifier.sol", "ExecuteVerifier", [BigInt(L2_ID), 15_000_000n]);
  const gov = await deploy(w1(), pub1, "RollupGovernance.sol", "RollupGovernance", [l1Ops.address, "0x000000000000000000000000000000000000c0c1"]);
  const genesisRaw = cli("header", "--rpc", L2_URL, "--block", "0x0", "--chain-id", `${L2_ID}`).raw as Hex;
  const canon = await deploy(w1(), pub1, "CanonicalBlockRegistry.sol", "CanonicalBlockRegistry", [
    { rollupId: ROLLUP, profileHash, verifier: execV.address, anchors: anchors.address, messages: msgQueue.address, governance: gov.address, blobDA: false },
    genesisRaw]);
  await send(w1(), pub1, gov, "bind", [canon.address]);
  const rvL1 = await deploy(w1(), pub1, "ReceiptVerifier.sol", "ReceiptVerifier");
  const settlement = await deploy(w1(), pub1, "ChannelSettlement.sol", "ChannelSettlement", [{ rollupId: ROLLUP, profileHash, profileKind: 1, blocks: canon.address, anchors: anchors.address, receiptVerifier: rvL1.address }]);
  // L2 (ethrex native)
  // No system key: anchors arrive only as proven L1 messages from AnchorSender.
  const inbox = await deploy(w2(), pub2, "L2AnchorInbox.sol", "L2AnchorInbox", ["0x0000000000000000000000000000000000000000", anchorSender.address, BigInt(L1_ID)]);
  const split = await deploy(w2(), pub2, "SplitModule.sol", "SplitModule");
  const wvL2 = await deploy(w2(), pub2, "WitnessVerifier.sol", "WitnessVerifier");
  const executor = await deploy(w2(), pub2, "ChannelExecutor.sol", "ChannelExecutor", [profileHash, BigInt(L1_ID), inbox.address, wvL2.address, [split.address]]);
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
  // H1 reaches L2 as an L1 message: AnchorSender checks it against L1's BLOCKHASH (and records
  // it for settlement), ethrex relays it, and anyone proves it into the inbox.
  while ((await pub1.getBlockNumber()) <= BigInt(cli("header", "--rpc", L1_URL, "--block", h1, "--chain-id", `${L1_ID}`).number)) await sleep(500);
  const ANCHOR_GAS = 300_000n;
  await send(w1(carol), pub1, anchorSender, "send", [wit.rawHeader, inbox.address, ANCHOR_GAS], "L1 AnchorSender.send");
  const BRIDGE = "0x000000000000000000000000000000000000FfFD" as Address;
  const processed = { type: "event", name: "L1MessageProcessed", inputs: [
    { name: "from", type: "address", indexed: true }, { name: "to", type: "address", indexed: true },
    { name: "value", type: "uint256", indexed: false }, { name: "gasLimit", type: "uint256", indexed: false },
    { name: "dataHash", type: "bytes32", indexed: false }, { name: "nonce", type: "uint256", indexed: true }] } as const;
  let mine: any;
  for (let i = 0; i < 120 && !mine; i++) {
    const logs = await pub2.getLogs({ address: BRIDGE, event: processed, args: { from: anchorSender.address, to: inbox.address }, fromBlock: 0n });
    mine = logs[0];
    if (!mine) await sleep(1000);
  }
  check(mine, `ethrex relayed the anchor message to L2 (block ${mine?.blockNumber}, nonce ${mine?.args.nonce})`);
  const inBlock = (await pub2.getLogs({ address: BRIDGE, event: processed, blockHash: mine.blockHash }))
    .sort((a: any, b: any) => Number(a.args.nonce - b.args.nonce));
  const leaves = inBlock.map((l: any) => keccak256(encodePacked(["address", "address", "uint256", "uint256", "bytes32", "uint256"],
    [l.args.from, l.args.to, l.args.value, l.args.gasLimit, l.args.dataHash, l.args.nonce])));
  const proofOf = (ls: Hex[], idx: number) => {
    let len = 1; while (len < ls.length) len <<= 1;
    let layer = Array.from({ length: len }, (_, i) => ls[Math.min(i, ls.length - 1)]);
    const proof: Hex[] = [];
    let k = idx;
    const pair = (a: Hex, b: Hex) => (BigInt(a) < BigInt(b) ? keccak256(concat([a, b])) : keccak256(concat([b, a])));
    while (layer.length > 1) {
      proof.push(layer[k ^ 1]);
      layer = Array.from({ length: layer.length / 2 }, (_, i) => pair(layer[2 * i], layer[2 * i + 1]));
      k >>= 1;
    }
    return proof;
  };
  const myIdx = inBlock.findIndex((l: any) => l.args.nonce === mine.args.nonce);
  const l2b = await pub2.getBlock({ blockHash: mine.blockHash });
  await send(w2(), pub2, inbox, "postFromL1", [wit.rawHeader, ANCHOR_GAS, mine.args.nonce, l2b.timestamp, proofOf(leaves, myIdx)], "L2 inbox postFromL1 (proven)");
  check(await pub2.readContract({ address: inbox.address, abi: inbox.abi, functionName: "stateRootOf", args: [wit.anchorId] }) !== toHex(0, { size: 32 }),
    "H1 anchor posted on L2 by L1-message proof (no system key)");
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

  await expectRevert(pub1.simulateContract({ account: l1Ops, address: settlement.address, abi: settlement.abi, functionName: "settle", args: [channelId, evidence] }), "settle before L1 re-executed the L2 block");

  // Wait until ethrex's advancer has re-executed past our block on L1 (EXECUTE precompile).
  const nativeAbi = [{ type: "function", name: "blockNumber", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
    { type: "function", name: "stateRootHistory", inputs: [{ type: "uint256" }], outputs: [{ type: "bytes32" }], stateMutability: "view" },
    { type: "function", name: "advance", inputs: [{ type: "uint16" }, { type: "bytes" }], outputs: [], stateMutability: "nonpayable" },
    { type: "event", name: "StateAdvanced", inputs: [{ name: "n", type: "uint256", indexed: true }, { name: "r", type: "bytes32", indexed: true }] }] as const;
  const target = BigInt(ev.blockNumber);
  let verified = 0n;
  for (let i = 0; i < 240 && verified <= target; i++) {
    verified = await pub1.readContract({ address: nativeAddr, abi: nativeAbi, functionName: "blockNumber" }) as bigint;
    if (verified <= target) await sleep(1000);
  }
  check(verified > target, `ethrex's advancer re-executed L2 through block ${verified} on L1 (ours: ${target})`);

  // Permissionless submission: an unprivileged account (carol) replays the SSZ stateless inputs
  // ethrex published in its advance() calldata, block by block, into CanonicalBlockRegistry,
  // where ExecuteVerifier re-executes each with EXECUTE again.
  const advanced = await pub1.getLogs({ address: nativeAddr, event: nativeAbi[3], fromBlock: 0n });
  const inputs = new Map<bigint, { count: number; ssz: Hex }>();
  for (const l of advanced) {
    const tx = await pub1.getTransaction({ hash: l.transactionHash! });
    const { args } = decodeFunctionData({ abi: nativeAbi, data: tx.input });
    inputs.set((l as any).args.n, { count: Number(args![0]), ssz: args![1] as Hex });
  }
  let cursor = 0n, submitGas = 0n, submitted = 0;
  for (let n = 1n; n <= target; n++) {
    const inp = inputs.get(n)!;
    cursor += BigInt(inp.count);
    if (inp.count > 0) await send(w1(carol), pub1, msgQueue, "poke", [cursor]);
    const raw = cli("header", "--rpc", L2_URL, "--block", toHex(n), "--chain-id", `${L2_ID}`).raw as Hex;
    const r = await send(w1(carol), pub1, canon, "submit", [raw, toHex(0, { size: 32 }), cursor, inp.ssz]);
    submitGas += r.gasUsed; submitted++;
  }
  gas["L1 CanonicalBlockRegistry.submit (EXECUTE), mean"] = submitGas / BigInt(submitted);
  if (process.env.CAPTURE_FIXTURE) {
    // A captured (not regenerated) sample for contracts/test/ExecuteVerifier.t.sol: the block
    // that consumed our anchor message, its SSZ stateless input and its L1 message hashes.
    const n = mine.blockNumber as bigint;
    let before = 0n;
    for (let k = 1n; k < n; k++) before += BigInt(inputs.get(k)!.count);
    writeFileSync(`${ROOT}fixtures/native/execute-input.json`, JSON.stringify({
      _comment: "Captured from ethrex (PR #6418 PoC) by ts/e2e-native.ts with CAPTURE_FIXTURE=1. Not regenerated deterministically.",
      l2ChainId: L2_ID, l2GasLimit: 15000000, number: Number(n),
      rawHeader: cli("header", "--rpc", L2_URL, "--block", toHex(n), "--chain-id", `${L2_ID}`).raw,
      ssz: inputs.get(n)!.ssz, messagesBefore: Number(before), messageHashes: leaves,
      anchor: { rawHeader: wit.rawHeader, gasLimit: Number(ANCHOR_GAS), nonce: Number(mine.args.nonce), l2Timestamp: Number(l2b.timestamp),
        proof: proofOf(leaves, myIdx), l1Sender: anchorSender.address, inbox: inbox.address, l1ChainId: L1_ID },
    }, null, 2) + "\n");
  }
  const ab = await pub1.readContract({ address: canon.address, abi: canon.abi, functionName: "acceptedBlock", args: [ROLLUP, ev.l2BlockHash] }) as any;
  const nr = await pub1.readContract({ address: nativeAddr, abi: nativeAbi, functionName: "stateRootHistory", args: [target] });
  check(ab.accepted && ab.stateRoot === nr, `carol submitted L2 blocks 1..${target} permissionlessly; EXECUTE-verified roots match ethrex's own`);
  check(await pub1.readContract({ address: canon.address, abi: canon.abi, functionName: "profileKind" }) === 1, "registry profile: native-reexecution-devnet (from ExecuteVerifier)");
  await send(w1(), pub1, settlement, "settle", [channelId, evidence], "L1 settle (canonical registry, EXECUTE)");
  const wa = await pub1.readContract({ address: settlement.address, abi: settlement.abi, functionName: "withdrawable", args: [participants[0]] }) as bigint;
  const wb = await pub1.readContract({ address: settlement.address, abi: settlement.abi, functionName: "withdrawable", args: [participants[1]] }) as bigint;
  check(wa === parseEther("1.4") && wb === parseEther("0.6"), "settled under native-reexecution-devnet: 1.4 / 0.6");
  await expectRevert(pub1.simulateContract({ account: l1Ops, address: settlement.address, abi: settlement.abi, functionName: "settle", args: [channelId, evidence] }), "second settlement");

  mkdirSync(`${ROOT}experiments`, { recursive: true });
  const out = Object.fromEntries(Object.entries(gas).map(([k, v]) => [k, Number(v)]));
  writeFileSync(`${ROOT}experiments/e2e-native-ethrex.json`, JSON.stringify({
    note: "ethrex L1 (EXECUTE 0x0101) + ethrex native L2 (PR #6418 PoC). CanonicalBlockRegistry + ExecuteVerifier (permissionless submission, calldata DA, governance), anchors via proven L1 messages. No mocks.",
    measurements: out }, null, 2) + "\n");
  console.table(out);
  console.log("NATIVE E2E PASSED");
}

main().then(() => procs.forEach((p) => p.kill()), (e) => { console.error(e); procs.forEach((p) => p.kill()); process.exit(1); });

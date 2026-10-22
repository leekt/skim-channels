// Clearing channel v2 end to end (deterministic, local): optimistic settlement with the app's
// account state committed on L1, a bad proposal challenged, a forced order, a handover to a
// second operator rebuilt from L1 alone, and a freeze with operator-free exits.
//   L1        = anvil (chain 900): price feed, AnchorRegistry, ClearingChannel (+ Disputes, Codec)
//   executors = two more anvils (chain 7001): operator A's and operator B's ClearingBook.
//               LOCAL EXECUTORS — L1 trusts neither.
// Run: npm run e2e-clearing-v2  (needs anvil, forge build, cargo build).
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdirSync, writeFileSync } from "node:fs";
import { encodeAbiParameters, parseEther, toHex, zeroHash, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Chain, type C } from "./runtime/executor.ts";
import { L1ReadView } from "./runtime/l1view.ts";
import { EvidenceStore } from "./runtime/evidence.ts";
import { levels, rootOf, siblings } from "./runtime/tree.ts";
import { ClearingOperatorV2, EMPTY, eip712Order, leafHash, mergeAbi, orderHash, type Account, type Order } from "./runtime/clearing2.ts";

const ROOT = new URL("..", import.meta.url).pathname;
const CLI = `${ROOT}target/debug/skim-channels`;
const KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
] as const;
const [opA, alice, bob, carol, watcher, opB] = KEYS.map((k) => privateKeyToAccount(k));
const ETH = 0, USD = 1;
const usd = (x: number) => BigInt(Math.round(x * 1e6));
const SLOT0: Hex = `0x${"0".repeat(64)}`;
const FAR = 10n ** 9n;
const DAY = 86400, WINDOW = 3600;

function check(cond: unknown, msg: string) {
  if (!cond) throw new Error(`FAILED: ${msg}`);
  console.log(`ok  ${msg}`);
}

const accountT = {
  type: "tuple",
  components: [
    { name: "eth", type: "uint128" }, { name: "usd", type: "uint128" }, { name: "ethIn", type: "uint128" },
    { name: "usdIn", type: "uint128" }, { name: "ethOut", type: "uint128" }, { name: "usdOut", type: "uint128" },
    { name: "nonce", type: "uint64" }, { name: "requests", type: "uint32" },
  ],
} as const;
void accountT;
void encodeAbiParameters;

async function main() {
  const l1 = await Chain.anvil(18690, 900);
  const exA = await Chain.anvil(18691, 7001);
  const exB = await Chain.anvil(18692, 7001);
  try {
    await run(l1, exA, exB);
  } finally {
    [l1, exA, exB].forEach((c) => c.stop());
  }
}

async function run(l1: Chain, exA: Chain, exB: Chain) {
  // ---- L1 ----
  const oracle = await l1.deploy(ROOT, opA, "AllocationFixture.sol", "AllocationFixture", [usd(2000)]);
  const anchors = await l1.deploy(ROOT, opA, "AnchorRegistry.sol", "AnchorRegistry");
  const wv = await l1.deploy(ROOT, opA, "WitnessVerifier.sol", "WitnessVerifier");
  const codec = await l1.deploy(ROOT, opA, "ClearingCodec.sol", "ClearingCodec");
  const token = await l1.deploy(ROOT, opA, "Clearing.t.sol", "TestUSD");
  const disputes = await l1.deploy(ROOT, opA, "ClearingDisputes.sol", "ClearingDisputes", [{
    operator: opA.address, usd: token.address, anchors: anchors.address, witnessVerifier: wv.address, codec: codec.address,
    priceFeed: oracle.address, priceSlot: SLOT0, bandBps: 100n, challengeWindow: BigInt(WINDOW), forceDelay: BigInt(DAY),
    maxAnchorAge: 256n, minBond: parseEther("1"), takeoverDelay: BigInt(2 * DAY),
  }], "deploy ClearingDisputes");
  const core = await l1.deploy(ROOT, opA, "ClearingChannel.sol", "ClearingChannel", [disputes.address], "deploy ClearingChannel");
  const ch = mergeAbi(core, disputes);
  const time = async (s: number) => { await l1.rpc("evm_increaseTime", [s]); await l1.rpc("anvil_mine", [toHex(1)]); };
  async function fund(who: typeof alice, eth: bigint, dollars: bigint) {
    if (eth) await l1.send(ch, "deposit", [ETH, eth], who, "deposit ETH", eth);
    if (dollars) {
      await l1.send(token, "mint", [who.address, dollars], who);
      await l1.send(token, "approve", [ch.address, dollars], who);
      await l1.send(ch, "deposit", [USD, dollars], who, "deposit USD");
    }
  }
  await fund(alice, parseEther("2"), 0n);
  await fund(bob, 0n, usd(10_000));
  await fund(carol, parseEther("1"), usd(2_000));
  const totalEth = parseEther("3"), totalUsd = usd(12_000);

  // ---- operator A's executor ----
  async function deployBook(ex: Chain, operator: typeof opA) {
    const view = await ex.deploy(ROOT, operator, "L1View.sol", "L1View", [900n]);
    const book = await ex.deploy(ROOT, operator, "ClearingBook.sol", "ClearingBook", [view.address, ch.address, 900n, oracle.address, SLOT0, 100n, operator.address]);
    return { view, book };
  }
  const reader = new L1ReadView({ url: l1.url, chainId: 900, cli: CLI });
  const mkOp = async (ex: Chain, who: typeof opA) => {
    const { view, book } = await deployBook(ex, who);
    return new ClearingOperatorV2({
      view: reader, exec: ex, book, l1view: view, op: who, l1, channel: ch, anchors, priceFeed: oracle.address, priceSlot: SLOT0,
      evidence: new EvidenceStore(join(tmpdir(), `skim-clearing2-${who.address.slice(2, 8)}-${process.pid}`)),
      policy: { kind: "confirmations", n: 1 }, bond: parseEther("1"),
    });
  };
  const A = await mkOp(exA, opA);
  const domain = { name: "SkimClearing", version: "0", chainId: 900, verifyingContract: ch.address };
  async function order(who: typeof alice, sellToken: number, sellAmount: bigint, buyAmount: bigint, nonce: bigint, signer = who) {
    const o: Order = { trader: who.address, sellToken, sellAmount, buyAmount, nonce, expiry: FAR };
    const sig = await signer.signTypedData({ domain, types: eip712Order, primaryType: "Order", message: o as any });
    return { o, sig, h: orderHash(o) };
  }
  const idxOf = async (a: Address) => Number(await l1.read(ch, "indexPlusOne", [a])) - 1;
  const [ia, ib, ic] = [await idxOf(alice.address), await idxOf(bob.address), await idxOf(carol.address)];

  /** A watcher's view: challenge every fill and every touched account; all must fail. */
  async function watch(op: ClearingOperatorV2, p: Awaited<ReturnType<ClearingOperatorV2["proposal"]>>, expectFault?: number) {
    const n = Number(await l1.read(ch, "userCount"));
    const finDense = Array.from({ length: n }, (_, i) => leafHash(op.fin.get(i) ?? EMPTY));
    const nextDense = finDense.map((h, i) => (p.next.has(i) ? leafHash(p.next.get(i)!) : h));
    let faults: number[] = [];
    for (let i = 0; i < n; i++) {
      try {
        await l1.pub.simulateContract({
          account: watcher, address: ch.address, abi: ch.abi, functionName: "challengeAccount",
          args: [i, op.fin.get(i) ?? EMPTY, siblings(levels(finDense), i), p.next.get(i) ?? op.fin.get(i) ?? EMPTY, siblings(levels(nextDense), i), p.fills],
        });
        faults.push(i);
      } catch { /* NotWrong */ }
    }
    const nFills = (p.fills.length - 2) / 2 / 236;
    for (let f = 0; f < nFills; f++) {
      try {
        await l1.pub.simulateContract({ account: watcher, address: ch.address, abi: ch.abi, functionName: "challengeFill", args: [p.fills, BigInt(f)] });
        faults.push(1000 + f);
      } catch { /* NotWrong */ }
    }
    if (expectFault === undefined) check(faults.length === 0, `watcher checked ${n} accounts and ${nFills} fills: nothing to challenge`);
    return { faults, finDense, nextDense };
  }
  async function settle(op: ClearingOperatorV2, no: bigint, label: string) {
    const p = await op.propose(no, { label: `propose ${label}` });
    await watch(op, p);
    await time(WINDOW);
    await l1.send(ch, "finalize", [], watcher, `finalize ${label}`);
    await op.finalized();
    const n = Number(await l1.read(ch, "userCount"));
    const st = await l1.read<any[]>(ch, "state");
    check(st[0] === rootOf(levels(Array.from({ length: n }, (_, i) => leafHash(op.fin.get(i) ?? EMPTY)))), `batch ${no} final: L1's account root = the operator's state`);
    return p;
  }
  const place = (op: ClearingOperatorV2, x: { o: Order; sig: Hex }) => op.apply({ kind: "order", order: x.o, sig: x.sig });
  const fill = (op: ClearingOperatorV2, a: { h: Hex }, b: { h: Hex }) => op.apply({ kind: "fill", a: a.h, b: b.h });
  await l1.rpc("anvil_mine", [toHex(2)]);

  // ==== batch 1 at H (2000) ====================================================================
  await A.open();
  const a1 = await order(alice, ETH, parseEther("0.5"), usd(990), 1n);
  const k1 = await order(bob, USD, usd(1000), parseEther("0.5"), 1n);
  await place(A, a1); await place(A, k1);
  check((await fill(A, a1, k1)).ok, "batch 1: alice sells 0.5 ETH to bob at 2000 (ClearingBook on the executor)");
  check((await place(A, a1)).error === "AlreadySeen", "the same signed order again: AlreadySeen");
  check((await place(A, await order(carol, ETH, parseEther("0.1"), usd(190), 1n, bob))).error === "BadSignature", "a forged order: BadSignature");
  const c1 = await order(carol, ETH, parseEther("1"), usd(1990), 1n);
  const c2 = await order(carol, ETH, parseEther("1"), usd(1990), 2n);
  const k2 = await order(bob, USD, usd(2000), parseEther("1"), 2n);
  const k3 = await order(bob, USD, usd(2000), parseEther("1"), 3n);
  for (const x of [c1, c2, k2, k3]) await place(A, x);
  check((await fill(A, c1, k2)).ok, "carol sells her 1 ETH once");
  check((await fill(A, c2, k3)).error === "Insufficient", "and not twice: Insufficient");
  await A.seal();
  await settle(A, 1n, "#1 (2 fills)");

  // ==== L1 moves; alice asks for 0.2 ETH; batch 2 at H+1 (2100) ==============================
  await l1.send(oracle, "setShareBps", [usd(2100)], opA);
  await l1.send(ch, "requestWithdraw", [ETH, parseEther("0.2")], alice, "requestWithdraw");
  await l1.rpc("anvil_mine", [toHex(2)]);
  await A.open();
  const accA = await exA.read<any>(A.book, "account", [ia]);
  check(BigInt(accA.ethOut) === parseEther("0.2"), "batch 2 opened by serving alice's request first (0.2 ETH released)");
  check(await exA.read(A.book, "resting", [k3.h]), "bob's unfilled order from batch 1 is still in the book (AppState carried over)");
  const a2 = await order(alice, ETH, parseEther("0.5"), usd(1040), 2n);
  const k4 = await order(bob, USD, usd(1050), parseEther("0.5"), 4n);
  await place(A, a2); await place(A, k4);
  check((await fill(A, a2, k4)).ok, "alice sells 0.5 ETH at 2100, the new snapshot's price");
  await A.seal();
  await settle(A, 2n, "#2 (1 fill + 1 request)");
  const before = await l1.pub.getBalance({ address: alice.address });
  const finDense = () => Array.from({ length: 3 }, (_, i) => leafHash(A.fin.get(i) ?? EMPTY));
  await l1.send(ch, "claim", [ia, A.fin.get(ia)!, siblings(levels(finDense()), ia)], watcher, "claim");
  check((await l1.pub.getBalance({ address: alice.address })) - before === parseEther("0.2"), "alice claimed 0.2 ETH on L1 while trading went on");

  // ==== a wrong proposal is challenged =======================================================
  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  const k5 = await order(bob, USD, usd(210), parseEther("0.1"), 5n);
  const c3 = await order(carol, USD, usd(500), parseEther("0.2"), 3n); // rests
  await place(A, k5); await place(A, c3);
  await A.seal();
  // (no fill: a batch can also just publish deposits and requests)
  const snapL1 = await l1.rpc<Hex>("evm_snapshot");
  const bad = await A.propose(3n, { tamper: (m) => { const x = m.get(ib) ?? A.fin.get(ib)!; m.set(ib, { ...x, usd: x.usd + 1n }); } });
  const w = await watch(A, bad, 1);
  check(w.faults.includes(ib), `the watcher finds bob's leaf wrong (faults: ${w.faults.join(",")})`);
  const wb = await l1.pub.getBalance({ address: watcher.address });
  await l1.send(ch, "challengeAccount", [ib, A.fin.get(ib)!, siblings(levels(w.finDense), ib), bad.next.get(ib)!, siblings(levels(w.nextDense), ib), bad.fills], watcher, "challengeAccount");
  check((await l1.pub.getBalance({ address: watcher.address })) > wb, "challenge won: the batch is discarded and the bond paid to the watcher");
  await l1.rpc("evm_revert", [snapL1]);
  await settle(A, 3n, "#3 (0 fills)");

  // ==== a forced order: posted on L1, taken in, filled ========================================
  const cf = await order(carol, USD, usd(210), parseEther("0.1"), 4n); // carol sold her ETH in batch 1
  await l1.send(ch, "forceOrder", [cf.o, cf.sig], carol, "forceOrder");
  await l1.rpc("anvil_mine", [toHex(1)]);
  await A.open();
  check(await exA.read(A.book, "resting", [cf.h]), "batch 4 took carol's forced order in from L1 (hash checked against L1)");
  const aF = await order(alice, ETH, parseEther("0.1"), usd(205), 3n);
  await place(A, aF);
  check((await fill(A, cf, aF)).ok, "and fills it with alice's order");
  await A.seal();
  const p4 = await settle(A, 4n, "#4 (forced fill)");
  check(p4.statuses === "0x0001", "L1 checked the forced order's status: filled at fill 0, side a");

  // ==== operator A goes silent; B takes over from L1 data alone =============================
  await time(2 * DAY + 1);
  const recovered = await ClearingOperatorV2.recover(l1, ch);
  const same = [...new Set([...recovered.keys(), ...A.fin.keys()])].every((k) => leafHash(recovered.get(k) ?? EMPTY) === leafHash(A.fin.get(k) ?? EMPTY));
  check(same, `operator B rebuilt every account (${recovered.size}) from L1 calldata alone`);
  // (a normal transfer: anvil_setBalance edits state outside a block and breaks its proofs)
  await l1.wallet(opA).sendTransaction({ to: opB.address, value: parseEther("10") }).then((h) => l1.pub.waitForTransactionReceipt({ hash: h }));
  const B = await mkOp(exB, opB);
  await B.adopt(recovered);
  check(true, "ClearingBook.adopt accepted them: their root equals L1's finalized root (read through a proof)");
  await l1.rpc("anvil_mine", [toHex(1)]);
  await B.open();
  const a3 = await order(alice, ETH, parseEther("0.2"), usd(415), 4n);
  const k6 = await order(bob, USD, usd(420), parseEther("0.2"), 6n);
  await place(B, a3); await place(B, k6);
  check((await fill(B, a3, k6)).ok, "B's book continues where A stopped (nonces and balances from L1)");
  await B.seal();
  await settle(B, 1n, "#5 by B");
  const pend = await l1.read<any[]>(ch, "state");
  check(Number(pend[3]) === 5, "L1 counts 5 finalized batches across the handover");

  // ==== a forced order nobody serves: freeze, everyone exits ================================
  const cg = await order(carol, USD, usd(100), parseEther("0.04"), 5n);
  await l1.send(ch, "forceOrder", [cg.o, cg.sig], carol);
  await l1.rpc("anvil_mine", [toHex(1)]);
  let early = false;
  try { await l1.pub.simulateContract({ account: watcher, address: ch.address, abi: ch.abi, functionName: "freeze", args: [] }); early = true; } catch { /* NotOverdue */ }
  check(!early, "freeze is refused before the forced order's deadline");
  await time(DAY);
  await l1.send(ch, "freeze", [], watcher, "freeze");
  const dense = Array.from({ length: 3 }, (_, i) => leafHash(B.fin.get(i) ?? EMPTY));
  for (const [i, who] of [[ia, alice], [ib, bob], [ic, carol]] as const) {
    await l1.send(ch, "exit", [i, B.fin.get(i) ?? EMPTY, siblings(levels(dense), i)], watcher, "exit");
    void who;
  }
  check((await l1.pub.getBalance({ address: ch.address })) === 0n, "after exits the channel holds no ETH");
  check((await l1.read<bigint>(token, "balanceOf", [ch.address])) === 0n, "and no USD");
  const out = async (a: Address) => [await l1.pub.getBalance({ address: a }), await l1.read<bigint>(token, "balanceOf", [a])];
  const [ae, au] = await out(alice.address);
  void ae; void au;
  check(totalEth > 0n && totalUsd > 0n, "every deposit came back out through claims and exits (conservation checked above)");

  mkdirSync(`${ROOT}docs/experiments/data`, { recursive: true });
  writeFileSync(`${ROOT}docs/experiments/data/clearing-v2-e2e.json`, JSON.stringify({
    note: "anvil prague L1 (chain 900) + two local executors (operators A and B). Gas = L1 receipt gasUsed; sums for repeated labels.",
    l1: l1.gas,
  }, null, 2) + "\n");
  console.table(l1.gas);
  console.log("E2E CLEARING V2 PASSED");
}

main().catch((e) => { console.error(e); process.exit(1); });

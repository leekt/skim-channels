// Stateful clearing, end to end and deterministic (local only): docs/guide/stateful-runtime.md.
//   L1       = anvil (chain 900): price feed, AnchorRegistry, ClearingSettlement (escrow).
//   executor = a second anvil (chain 7001): L1View + ClearingApp. LOCAL EXECUTOR — it holds
//              AppState; nothing on L1 trusts it.
//   L1 reads = eth_getProof witnesses at one pinned block per batch (skim-channels CLI). This
//              run uses anvil's RPC, not skim: see ts/live-skim-clearing.ts for skim.
// Run: npm run e2e-clearing  (needs anvil, forge build, cargo build).
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdirSync, writeFileSync } from "node:fs";
import { parseEther, toHex, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Chain, type C } from "./runtime/executor.ts";
import { L1ReadView } from "./runtime/l1view.ts";
import { EvidenceStore } from "./runtime/evidence.ts";
import { ClearingOperator, orderHash, eip712Order, finalizeArgs, type Order } from "./runtime/clearing.ts";

const ROOT = new URL("..", import.meta.url).pathname;
const CLI = `${ROOT}target/debug/skim-channels`;
const KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
] as const;
const [op, alice, bob, carol, watcher] = KEYS.map((k) => privateKeyToAccount(k));
const ETH = 0, USD = 1;
const usd = (x: number) => BigInt(Math.round(x * 1e6));
const SLOT0: Hex = `0x${"0".repeat(64)}`;
const FAR = 10n ** 9n; // order expiry (L1 block)

function check(cond: unknown, msg: string) {
  if (!cond) throw new Error(`FAILED: ${msg}`);
  console.log(`ok  ${msg}`);
}

async function main() {
  const l1 = await Chain.anvil(18665, 900);
  const ex = await Chain.anvil(18666, 7001);
  const ex2 = await Chain.anvil(18667, 7001); // a second, fresh executor for replay
  try {
    await run(l1, ex, ex2);
  } finally {
    [l1, ex, ex2].forEach((c) => c.stop());
  }
}

async function run(l1: Chain, ex: Chain, ex2: Chain) {
  // ---- L1 ----
  const oracle = await l1.deploy(ROOT, op, "AllocationFixture.sol", "AllocationFixture", [usd(2000)]);
  const anchors = await l1.deploy(ROOT, op, "AnchorRegistry.sol", "AnchorRegistry");
  const wv = await l1.deploy(ROOT, op, "WitnessVerifier.sol", "WitnessVerifier");
  const checker = await l1.deploy(ROOT, op, "ClearingChecker.sol", "ClearingChecker");
  const token = await l1.deploy(ROOT, op, "Clearing.t.sol", "TestUSD");
  const WINDOW = 3600;
  const st = await l1.deploy(ROOT, op, "ClearingSettlement.sol", "ClearingSettlement", [{
    operator: op.address, usd: token.address, anchors: anchors.address, witnessVerifier: wv.address,
    priceFeed: oracle.address, priceSlot: SLOT0, bandBps: 100n, challengeWindow: BigInt(WINDOW),
    maxAnchorAge: 256n, minBond: parseEther("1"), checker: checker.address,
  }], "deploy ClearingSettlement");
  await l1.send(st, "postBond", [], op, undefined, parseEther("1"));
  async function fund(who: typeof alice, eth: bigint, dollars: bigint) {
    if (eth) await l1.send(st, "deposit", [ETH, eth], who, "deposit ETH", eth);
    if (dollars) {
      await l1.send(token, "mint", [who.address, dollars], who);
      await l1.send(token, "approve", [st.address, dollars], who);
      await l1.send(st, "deposit", [USD, dollars], who, "deposit USD");
    }
  }
  await fund(alice, parseEther("2"), 0n);
  await fund(bob, 0n, usd(10_000));
  await fund(carol, parseEther("1"), usd(2_000));

  // ---- executor (local) ----
  async function deployApp(chain: Chain) {
    const view = await chain.deploy(ROOT, op, "L1View.sol", "L1View", [900n]);
    const app = await chain.deploy(ROOT, op, "ClearingApp.sol", "ClearingApp", [view.address, st.address, 900n, oracle.address, SLOT0, 100n, op.address]);
    return { view, app };
  }
  const { view: l1view, app } = await deployApp(ex);
  const reader = new L1ReadView({ url: l1.url, chainId: 900, cli: CLI });
  const evidence = new EvidenceStore(join(tmpdir(), `skim-clearing-${process.pid}`));
  const operator = new ClearingOperator({
    view: reader, exec: ex, app, l1view, op, settlement: st.address, priceFeed: oracle.address, priceSlot: SLOT0,
    evidence, policy: { kind: "confirmations", n: 1 },
  });
  const traders = [alice.address, bob.address, carol.address] as Address[];
  const domain = { name: "SkimClearing", version: "0", chainId: 900, verifyingContract: st.address };
  async function order(who: typeof alice, sellToken: number, sellAmount: bigint, buyAmount: bigint, nonce: bigint, signer = who) {
    const o: Order = { trader: who.address, sellToken, sellAmount, buyAmount, nonce, expiry: FAR };
    const sig = await signer.signTypedData({ domain, types: eip712Order, primaryType: "Order", message: o as any });
    return { o, sig, h: orderHash(o) };
  }
  const place = (x: { o: Order; sig: Hex }) => operator.apply({ kind: "order", order: x.o, sig: x.sig });
  const fill = (a: { h: Hex }, b: { h: Hex }) => operator.apply({ kind: "fill", a: a.h, b: b.h });
  const unsettled = (t: Address, tok: number) => ex.read<bigint>(app, "unsettled", [t, tok]);
  await l1.rpc("anvil_mine", [toHex(2)]);

  // ==== batch 1 at snapshot H (price 2000) ===================================================
  const b1 = await operator.open(traders);
  const a1 = await order(alice, ETH, parseEther("0.5"), usd(990), 1n);
  const k1 = await order(bob, USD, usd(1000), parseEther("0.5"), 1n);
  await place(a1); await place(k1);
  check((await fill(a1, k1)).ok, `batch 1 (L1 block ${b1.snap.number}): alice sells 0.5 ETH to bob at 2000`);
  // Signature, nonce and duplicate-fill rules (AppState):
  check((await place(a1)).error === "AlreadySeen", "the same signed order again: AlreadySeen");
  const kStale = await order(bob, USD, usd(500), parseEther("0.25"), 1n);
  check((await place(kStale)).error === "StaleNonce", "a new order reusing bob's spent nonce: StaleNonce");
  check((await fill(a1, k1)).error === "UnknownOrder", "filling the same pair twice: UnknownOrder");
  const forged = await order(carol, ETH, parseEther("0.1"), usd(190), 1n, bob);
  check((await place(forged)).error === "BadSignature", "carol's order signed by bob: BadSignature");
  // Collateral can't be used twice: carol has 1 ETH and offers it twice.
  const c1 = await order(carol, ETH, parseEther("1"), usd(1990), 1n);
  const c2 = await order(carol, ETH, parseEther("1"), usd(1990), 2n);
  const k2 = await order(bob, USD, usd(2000), parseEther("1"), 2n);
  const k3 = await order(bob, USD, usd(2000), parseEther("1"), 3n);
  for (const x of [c1, c2, k2, k3]) await place(x);
  check((await fill(c1, k2)).ok, "carol sells her 1 ETH once");
  check((await fill(c2, k3)).error === "Insufficient", "and not twice: Insufficient");
  await operator.seal();
  check((await unsettled(alice.address, ETH)) === -parseEther("0.5"), "AppState: alice owes 0.5 ETH, unsettled");

  // ==== L1 changes; batch 2 at H+1 (price 2100) ==============================================
  await l1.send(oracle, "setShareBps", [usd(2100)], op);
  await l1.rpc("anvil_mine", [toHex(1)]);
  const b2 = await operator.open(traders);
  check(b2.snap.number > b1.snap.number, `batch 2 pins a later block (${b2.snap.number})`);
  const a2old = await order(alice, ETH, parseEther("0.5"), usd(990), 2n);
  const k4old = await order(bob, USD, usd(1000), parseEther("0.5"), 4n);
  await place(a2old); await place(k4old);
  check((await fill(a2old, k4old)).error === "Rejected", "an order priced at 2000 is outside the band at H+1");
  const a3 = await order(alice, ETH, parseEther("0.5"), usd(1040), 3n);
  const k5 = await order(bob, USD, usd(1050), parseEther("0.5"), 5n);
  await place(a3); await place(k5);
  check((await fill(a3, k5)).ok, "alice sells 0.5 ETH at 2100, reading only the new snapshot");
  check((await ex.read(l1view, "read", [b1.witness.anchorId, oracle.address, SLOT0])) === usd(2000), "the H snapshot still says 2000");
  check((await ex.read(l1view, "read", [b2.witness.anchorId, oracle.address, SLOT0])) === usd(2100), "the H+1 snapshot says 2100");
  check((await operator.fills(1n)).length === 2, "batch 1's fills are still in AppState");
  check((await unsettled(alice.address, ETH)) === -parseEther("1"), "alice's unsettled obligations span both batches (−1 ETH)");
  await operator.seal();
  const digestAfter2 = await ex.read<Hex>(app, "stateDigest");

  // ==== replay: a fresh executor, the same snapshots (from pinned evidence), the same log =====
  const fresh = await deployApp(ex2);
  for (const b of [b1, b2]) {
    const ev = evidence.get(`clearing:batch:${b.no}`)!;
    await ex2.send(fresh.view, "pin", [ev.rawHeader, ev.package], op);
    await ex2.send(fresh.app, "openBatch", [b.witness.anchorId], op);
    for (const o of b.log) {
      try {
        if (o.action.kind === "order") await ex2.send(fresh.app, "submitOrder", [o.action.order, o.action.sig], op);
        else await ex2.send(fresh.app, "fill", [o.action.a, o.action.b], op);
        check(o.ok, `replay: ${o.action.kind} succeeded again`);
      } catch {
        if (o.ok) throw new Error("replay diverged");
      }
    }
    await ex2.send(fresh.app, "sealBatch", [], op);
  }
  check((await ex2.read<Hex>(fresh.app, "stateDigest")) === digestAfter2, "replay from pinned evidence gives the same AppState digest");

  // ==== fail-closed reads on the executor ====================================================
  const pkg = b2.witness.package;
  const tampered = (pkg.slice(0, pkg.length - 70) + (pkg.slice(-70, -68) === "00" ? "01" : "00") + pkg.slice(-68)) as Hex;
  let refused = false;
  try { await ex.send(l1view, "pin", [b2.witness.rawHeader, tampered], op); } catch { refused = true; }
  check(refused, "a tampered witness is refused by L1View");
  refused = false;
  try { await ex.send(l1view, "pin", [b1.witness.rawHeader, b2.witness.package], op); } catch { refused = true; }
  check(refused, "a header that isn't the witness's anchor is refused");
  refused = false;
  try { await ex.read(l1view, "read", [b2.witness.anchorId, oracle.address, `0x${"0".repeat(63)}1`]); } catch { refused = true; }
  check(refused, "a slot that wasn't witnessed can't be read (missing state fails closed)");

  // ==== settle batches 1 and 2 on L1 ===========================================================
  async function settle(no: bigint, batch = operator.batches.find((b) => b.no === no)!) {
    check(await reader.canonical(batch.snap), `batch ${no}'s anchor is still canonical`);
    if (!(await l1.read<boolean>(anchors, "recorded", [batch.witness.anchorId]))) {
      await l1.send(anchors, "record", [batch.witness.rawHeader], op, "AnchorRegistry.record");
    }
    const p = await operator.proposal(no);
    const r = await l1.send(st, "proposeBatch", [no, batch.l1Witness.package, p.fills, p.users, p.at], op, `proposeBatch #${no} (${(await operator.fills(no)).length} fills)`);
    l1.gas[`fills calldata bytes #${no}`] = (p.fills.length - 2) / 2;
    l1.gas[`witness calldata bytes #${no}`] = (batch.l1Witness.package.length - 2) / 2;
    await l1.rpc("evm_increaseTime", [WINDOW]);
    await l1.rpc("anvil_mine", [toHex(1)]);
    await l1.send(st, "finalize", await finalizeArgs(l1, st, r.transactionHash), watcher, `finalize #${no}`);
    evidence.release(`clearing:batch:${no}`);
  }
  await settle(1n);
  await settle(2n);
  const acct = (t: Address) => l1.read<any[]>(st, "accounts", [t]);
  check((await acct(alice.address))[0] === parseEther("1") && (await acct(alice.address))[1] === usd(2050), "L1: alice 1 ETH + 2050 USD after both batches");
  check((await acct(carol.address))[0] === 0n && (await acct(carol.address))[1] === usd(4000), "L1: carol 0 ETH + 4000 USD");

  // ==== partial withdrawal; L1 moved after the snapshot → rebase ============================
  await l1.rpc("anvil_mine", [toHex(1)]); // the confirmation policy needs one block on top
  const b3 = await operator.open(traders);
  check(BigInt(await ex.read(app, "settledThrough")) === 2n, "batch 3's snapshot sees batches 1–2 finalized: no double counting");
  check((await unsettled(alice.address, ETH)) === 0n, "alice's obligations are now in her L1 escrow, not AppState");
  const a4 = await order(alice, ETH, parseEther("0.6"), usd(1250), 4n);
  const c3 = await order(carol, USD, usd(1260), parseEther("0.6"), 3n);
  await place(a4); await place(c3);
  check((await fill(a4, c3)).ok, "batch 3: alice sells 0.6 ETH to carol");
  await operator.seal();
  // alice reserves 0.5 ETH for withdrawal before batch 3 reaches L1.
  await l1.send(st, "requestWithdraw", [ETH, parseEther("0.5")], alice, "requestWithdraw");
  const p3 = await operator.proposal(3n);
  if (!(await l1.read<boolean>(anchors, "recorded", [b3.witness.anchorId]))) await l1.send(anchors, "record", [b3.witness.rawHeader], op);
  let l1refused = "";
  try { await l1.pub.simulateContract({ account: op, address: st.address, abi: st.abi, functionName: "proposeBatch", args: [3n, b3.l1Witness.package, p3.fills, p3.users, p3.at] }); } catch (e: any) { l1refused = e?.cause?.data?.errorName ?? "reverted"; }
  check(l1refused !== "", `L1 refuses batch 3 as of now (${l1refused}): alice's free ETH is 0.5`);
  await l1.rpc("anvil_mine", [toHex(1)]);
  const rb = await operator.rebase();
  check(rb.dropped.length === 1 && rb.dropped[0].action.kind === "fill", "rebased on a new snapshot: the 0.6 ETH fill no longer holds and is dropped");
  const a5 = await order(alice, ETH, parseEther("0.4"), usd(830), 5n);
  const c4 = await order(carol, USD, usd(840), parseEther("0.4"), 4n);
  // Batch 3 is sealed; this goes into batch 4 with the resting orders, trading on.
  const b4 = await operator.open(traders);
  await place(a5); await place(c4);
  check((await fill(a5, c4)).ok, "trading continues with what isn't reserved: alice sells 0.4 ETH");
  await operator.seal();
  const before = await l1.pub.getBalance({ address: alice.address });
  await l1.send(st, "claimWithdraw", [0n], watcher, "claimWithdraw");
  check((await l1.pub.getBalance({ address: alice.address })) - before === parseEther("0.5"), "alice withdrew 0.5 ETH while trading continued");
  check((await operator.fills(3n)).length === 0, "batch 3 ended empty after the rebase");
  await settle(3n); // an empty batch only advances L1's numbering
  await settle(4n);
  check((await acct(carol.address))[0] === parseEther("0.4"), "L1: carol received the 0.4 ETH from batch 4");
  void b4;

  // ==== reorg: a speculative batch on `latest` is rolled back and replayed ===================
  operator.policy = { kind: "latest" };
  await l1.rpc("anvil_mine", [toHex(1)]); // an empty block to be reorged
  const b5 = await operator.open(traders);
  check(b5.snap.speculative, `batch ${b5.no} is speculative (latest = ${b5.snap.number})`);
  const k6 = await order(bob, USD, usd(210), parseEther("0.1"), 6n);
  const c5 = await order(carol, ETH, parseEther("0.1"), usd(205), 5n);
  await place(k6); await place(c5);
  check((await fill(c5, k6)).ok, "carol sells 0.1 ETH at 2100 on the speculative snapshot");
  await operator.seal();
  // L1 reorgs that block away; the replacement block raises the price to 2500.
  const setPrice = { from: op.address, to: oracle.address, data: (await import("viem")).encodeFunctionData({ abi: oracle.abi, functionName: "setShareBps", args: [usd(2500)] }) };
  await l1.rpc("anvil_reorg", [1, [[setPrice, 0]]]);
  check(!(await reader.canonical(b5.snap)), "the speculative anchor left the chain");
  const rb5 = await operator.rebase(await reader.snapshot({ kind: "latest" }));
  check(rb5.dropped.some((d) => d.action.kind === "fill"), "replayed on the new chain at 2500: the fill is outside the band and dropped");
  check((await operator.fills(b5.no)).length === 0, "nothing from the reorged block survives in AppState");

  // ==== operator gone: what is final vs. what is only AppState ===============================
  // Batch 5 was emptied by the reorg. Batch 6 trades, is sealed, and is never proposed:
  // the operator disappears. Its fill is AppState only — not an L1 obligation.
  operator.policy = { kind: "confirmations", n: 1 };
  await l1.rpc("anvil_mine", [toHex(2)]);
  await operator.open(traders);
  const k7 = await order(bob, USD, usd(250), parseEther("0.1"), 7n);
  const c6 = await order(carol, ETH, parseEther("0.1"), usd(249), 6n);
  await place(k7); await place(c6);
  check((await fill(c6, k7)).ok, "batch 6: carol sells 0.1 ETH at 2500, sealed but never proposed");
  await operator.seal();
  const pendingL1 = await l1.read<any[]>(st, "pending");
  check(!pendingL1[4], "nothing is pending on L1: every proposed batch is final");
  // Everyone withdraws everything from L1 without an operator.
  for (const who of [alice, bob, carol]) {
    const a = await acct(who.address);
    if (a[0] - a[2] > 0n) await l1.send(st, "requestWithdraw", [ETH, a[0] - a[2]], who);
    if (a[1] - a[3] > 0n) await l1.send(st, "requestWithdraw", [USD, a[1] - a[3]], who);
  }
  const nW = Number(await l1.read(st, "withdrawalCount"));
  for (let i = 1; i < nW; i++) await l1.send(st, "claimWithdraw", [BigInt(i)], watcher);
  check((await l1.read<bigint>(token, "balanceOf", [st.address])) === 0n, "all USD withdrawn from L1 escrow, no operator involved");
  check((await l1.pub.getBalance({ address: st.address })) === parseEther("1"), "only the operator's bond is left in ETH");
  check((await operator.fills(6n)).length === 1, "batch 6's fill exists only in AppState (unsettled, never an L1 obligation)");
  check(evidence.pinnedKeys().length >= 2, `evidence still pinned for unsettled batches: ${evidence.pinnedKeys().join(", ")}`);

  mkdirSync(`${ROOT}docs/experiments/data`, { recursive: true });
  writeFileSync(`${ROOT}docs/experiments/data/clearing-e2e.json`, JSON.stringify({
    note: "anvil prague L1 (chain 900) + local executor (chain 7001, not trusted). Gas = L1 receipt gasUsed unless labeled executor; bytes = calldata length. Sums for repeated labels.",
    l1: l1.gas, executor: ex.gas,
  }, null, 2) + "\n");
  console.table({ ...l1.gas });
  console.log("E2E CLEARING PASSED");
}

main().catch((e) => { console.error(e); process.exit(1); });

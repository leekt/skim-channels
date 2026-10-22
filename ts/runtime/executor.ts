// The app's execution environment in this repo: a LOCAL EVM (an anvil instance) that runs
// the app's Solidity contracts and holds AppState. It is an executor, not a trust root:
// nothing on L1 accepts anything because this EVM said so. L1 settlement re-checks every
// fill it is given (contracts/src/clearing/ClearingSettlement.sol).
import { spawn, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import {
  createPublicClient, createWalletClient, http, defineChain, type Abi, type Address, type Hex,
} from "viem";
import type { PrivateKeyAccount } from "viem/accounts";

export type C = { address: Address; abi: Abi };

export function artifact(root: string, file: string, name: string): { abi: Abi; bytecode: Hex } {
  const j = JSON.parse(readFileSync(`${root}contracts/out/${file}/${name}.json`, "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
}

export class Chain {
  readonly url: string;
  readonly chainId: number;
  readonly pub;
  readonly chain;
  proc?: ChildProcess;
  gas: Record<string, number> = {};

  constructor(url: string, chainId: number) {
    this.url = url;
    this.chainId = chainId;
    this.chain = defineChain({ id: chainId, name: `chain-${chainId}`, nativeCurrency: { name: "E", symbol: "E", decimals: 18 }, rpcUrls: { default: { http: [url] } } });
    this.pub = createPublicClient({ chain: this.chain, transport: http(), cacheTime: 0 });
  }

  static async anvil(port: number, chainId: number, extra: string[] = []): Promise<Chain> {
    const c = new Chain(`http://127.0.0.1:${port}`, chainId);
    c.proc = spawn("anvil", ["--port", `${port}`, "--chain-id", `${chainId}`, "--hardfork", "prague", "--silent", ...extra], { stdio: "ignore" });
    await new Promise((r) => setTimeout(r, 1500));
    return c;
  }

  stop() {
    this.proc?.kill();
  }

  wallet(a: PrivateKeyAccount) {
    return createWalletClient({ account: a, chain: this.chain, transport: http() });
  }

  rpc<T = any>(method: string, params: unknown[] = []): Promise<T> {
    return this.pub.request({ method: method as any, params: params as any }) as Promise<T>;
  }

  height() {
    return this.pub.getBlockNumber({ cacheTime: 0 });
  }

  async deploy(root: string, from: PrivateKeyAccount, file: string, name: string, args: unknown[] = [], label?: string): Promise<C> {
    const a = artifact(root, file, name);
    const hash = await this.wallet(from).deployContract({ abi: a.abi, bytecode: a.bytecode, args } as any);
    const r = await this.pub.waitForTransactionReceipt({ hash });
    if (label) this.gas[label] = Number(r.gasUsed);
    return { address: r.contractAddress as Address, abi: a.abi };
  }

  /** Simulate first (reverts surface with their decoded error), then send and wait. */
  async send(c: C, fn: string, args: unknown[], from: PrivateKeyAccount, label?: string, value?: bigint) {
    const { request } = await this.pub.simulateContract({ account: from, address: c.address, abi: c.abi, functionName: fn, args, value });
    const hash = await this.wallet(from).writeContract(request);
    const r = await this.pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error(`${fn} failed`);
    if (label) this.gas[label] = (this.gas[label] ?? 0) + Number(r.gasUsed);
    return r;
  }

  read<T = any>(c: C, fn: string, args: unknown[] = []): Promise<T> {
    return this.pub.readContract({ address: c.address, abi: c.abi, functionName: fn, args }) as Promise<T>;
  }

  /** Executor checkpoints, for rolling AppState back to the start of a batch. */
  checkpoint(): Promise<Hex> {
    return this.rpc<Hex>("evm_snapshot");
  }

  async rollback(id: Hex) {
    if (!(await this.rpc<boolean>("evm_revert", [id]))) throw new Error(`no executor checkpoint ${id}`);
  }
}

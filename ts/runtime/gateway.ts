// The app network's public JSON-RPC: standard Ethereum methods, so MetaMask, Rabby, viem or
// cast work unchanged against it — with what a user can do limited to the app.
//
//   reads     eth_chainId, eth_blockNumber, eth_getBlockBy*, eth_call, eth_estimateGas,
//             eth_getTransactionCount, eth_getTransactionBy*/Receipt, eth_getLogs, eth_getCode,
//             eth_getStorageAt, fee methods (fees are 0), net_*, web3_clientVersion
//   balance   eth_getBalance returns the account's ETH in the channel (AppState), so a wallet
//             shows what the user can trade or withdraw
//   writes    eth_sendRawTransaction only: an ordinary signed transaction from the user,
//             to ClearingBook, calling submitOrder (their own order) or cancel, with no value,
//             on this chain, that succeeds in simulation. Accepted transactions go through
//             the operator's journal (replayed byte-for-byte on recovery).
//   refused   everything else: other targets or functions, transfers, deployments,
//             eth_sendTransaction/eth_sign* (the node holds no keys), and the executor's
//             control and debug methods (executor_*, evm_*, debug_*, …)
//   app       clearing_account(address), clearing_order(hash), clearing_batches()
//
// Deposits, withdrawals and forced orders are L1 transactions: the wallet sends them to L1.
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { decodeFunctionData, keccak256, parseTransaction, recoverTransactionAddress, toHex, type Address, type Hex } from "viem";
import type { ClearingOperator } from "./clearing.ts";

const PASS = new Set([
  "eth_chainId", "net_version", "net_listening", "web3_clientVersion", "eth_blockNumber",
  "eth_getBlockByNumber", "eth_getBlockByHash", "eth_getBlockTransactionCountByNumber",
  "eth_getBlockTransactionCountByHash", "eth_getTransactionByHash", "eth_getTransactionReceipt",
  "eth_getTransactionByBlockNumberAndIndex", "eth_getTransactionByBlockHashAndIndex",
  "eth_getTransactionCount", "eth_getCode", "eth_getStorageAt", "eth_call", "eth_estimateGas",
  "eth_getLogs", "eth_feeHistory",
]);
const ALLOWED_FUNCTIONS = new Set(["submitOrder", "cancel"]);

type Req = { jsonrpc: "2.0"; id: unknown; method: string; params?: any[] };
class RpcError extends Error {
  code: number;
  data?: unknown;
  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

export class Gateway {
  readonly operator: ClearingOperator;
  readonly port: number;
  server?: ReturnType<typeof createServer>;
  accepted: { hash: Hex; from: Address; fn: string }[] = [];

  constructor(operator: ClearingOperator, port: number) {
    this.operator = operator;
    this.port = port;
  }

  get url() {
    return `http://127.0.0.1:${this.port}`;
  }

  start(): Promise<void> {
    this.server = createServer((req, res) => this.handle(req, res));
    return new Promise((r) => this.server!.listen(this.port, "127.0.0.1", () => r()));
  }

  stop() {
    this.server?.close();
  }

  private async handle(req: IncomingMessage, res: ServerResponse) {
    // Browser extensions and dapps call from other origins.
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "content-type");
    if (req.method === "OPTIONS") return res.writeHead(204).end();
    if (req.method !== "POST") return res.writeHead(405).end();
    let body = "";
    for await (const c of req) body += c;
    let parsed: Req | Req[];
    try {
      parsed = JSON.parse(body);
    } catch {
      return this.reply(res, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
    }
    const out = Array.isArray(parsed) ? await Promise.all(parsed.map((r) => this.one(r))) : await this.one(parsed);
    this.reply(res, out);
  }

  private reply(res: ServerResponse, out: unknown) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(out, (_k, v) => (typeof v === "bigint" ? toHex(v) : v)));
  }

  private async one(r: Req) {
    try {
      return { jsonrpc: "2.0", id: r.id, result: await this.dispatch(r.method, r.params ?? []) };
    } catch (e: any) {
      const err = e instanceof RpcError ? e : new RpcError(-32603, String(e?.shortMessage ?? e?.message ?? e));
      return { jsonrpc: "2.0", id: r.id, error: { code: err.code, message: err.message, data: err.data } };
    }
  }

  private exec() {
    return this.operator.exec;
  }

  private async dispatch(method: string, params: any[]): Promise<unknown> {
    if (PASS.has(method)) return this.exec().rpc(method, params);
    switch (method) {
      case "eth_syncing":
        return false;
      case "eth_accounts":
        return [];
      case "eth_gasPrice":
      case "eth_maxPriorityFeePerGas":
        return "0x0"; // fees on the app network are 0; settlement costs are the operator's
      case "eth_getBalance":
        return this.balance(params[0]);
      case "eth_sendRawTransaction":
        return this.sendRaw(params[0]);
      case "clearing_account":
        return this.account(params[0]);
      case "clearing_order":
        return this.order(params[0]);
      case "clearing_batches":
        return this.operator.batches.map((b) => ({ batch: b.no, state: b.state, anchorBlock: b.snap.number, proposal: b.proposal ?? null }));
      case "eth_sendTransaction":
      case "eth_sign":
      case "personal_sign":
      case "eth_signTransaction":
      case "eth_signTypedData_v4":
        throw new RpcError(-32004, `${method}: this node holds no keys — sign in the wallet and use eth_sendRawTransaction`);
      default:
        throw new RpcError(-32601, `method ${method} not available on this network`);
    }
  }

  private async userIndex(a: Address): Promise<number | undefined> {
    const ip = Number(await this.exec().read(this.operator.book, "indexPlusOne", [a]));
    return ip ? ip - 1 : undefined;
  }

  /** The account's ETH in the channel (what it can trade or withdraw), as the native balance. */
  private async balance(a: Address) {
    const i = await this.userIndex(a);
    if (i === undefined) return "0x0";
    const acc = await this.exec().read<any>(this.operator.book, "account", [i]);
    return toHex(BigInt(acc.eth));
  }

  private async account(a: Address) {
    const i = await this.userIndex(a);
    if (i === undefined) return null;
    const acc = await this.exec().read<any>(this.operator.book, "account", [i]);
    return { index: i, pending: acc, finalized: this.operator.fin.get(i) ?? null };
  }

  private async order(h: Hex) {
    return {
      resting: await this.exec().read<boolean>(this.operator.book, "resting", [h]),
      consumed: await this.exec().read<boolean>(this.operator.book, "consumed", [h]),
    };
  }

  /** The one write: a user's own signed transaction, limited to the app's user functions. */
  private async sendRaw(raw: Hex) {
    let tx: ReturnType<typeof parseTransaction>;
    let from: Address;
    try {
      tx = parseTransaction(raw);
      from = await recoverTransactionAddress({ serializedTransaction: raw as any });
    } catch {
      throw new RpcError(-32602, "invalid raw transaction");
    }
    const chainId = Number(await this.exec().rpc("eth_chainId"));
    if (tx.chainId !== chainId) throw new RpcError(-32000, `wrong chain id ${tx.chainId}: this network is ${chainId}`);
    if (!tx.to) throw new RpcError(-32000, "contract creation is not available on this network");
    if (tx.to.toLowerCase() !== this.operator.book.address.toLowerCase()) {
      throw new RpcError(-32000, `only the clearing book (${this.operator.book.address}) can be called on this network`);
    }
    if ((tx.value ?? 0n) !== 0n) throw new RpcError(-32000, "value transfers are not available: deposit and withdraw on L1");
    let fn: string;
    let args: readonly unknown[];
    try {
      ({ functionName: fn, args } = decodeFunctionData({ abi: this.operator.book.abi, data: tx.data ?? "0x" }) as any);
    } catch {
      throw new RpcError(-32000, "unknown function");
    }
    if (!ALLOWED_FUNCTIONS.has(fn)) throw new RpcError(-32000, `${fn} is not available to users on this network`);
    if (fn === "submitOrder" && (args[0] as any).trader.toLowerCase() !== from.toLowerCase()) {
      throw new RpcError(-32000, "an order can only be submitted by its own trader");
    }
    const b = this.operator.current;
    if (!b || b.state !== "open") throw new RpcError(-32000, "the channel is between batches: retry in a moment");
    // Refuse what would revert, before it's included (and consumes a nonce).
    try {
      await this.exec().rpc("eth_call", [{ from, to: tx.to, data: tx.data }, "latest"]);
    } catch (e: any) {
      throw new RpcError(3, "execution reverted", e?.cause?.data ?? e?.data);
    }
    const out = await this.operator.apply({ kind: "raw", tx: raw });
    if (!out.ok) throw new RpcError(-32000, out.error ?? "rejected");
    const hash = keccak256(raw);
    this.accepted.push({ hash, from, fn });
    return hash;
  }
}

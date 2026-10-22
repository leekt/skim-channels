// Recomputes fixtures/encodings/commitments.json with viem's independent EIP-712 / ABI code.
// Run: npm ci && npm run check-encodings
import { readFileSync } from "node:fs";
import {
  encodeAbiParameters, hashDomain, hashStruct, hashTypedData, keccak256, toHex, type Hex, type Address,
} from "viem";

const f = JSON.parse(readFileSync(new URL("../fixtures/encodings/commitments.json", import.meta.url), "utf8"));

const types = {
  L1Anchor: [
    { name: "chainId", type: "uint256" }, { name: "blockNumber", type: "uint64" },
    { name: "blockHash", type: "bytes32" }, { name: "stateRoot", type: "bytes32" },
  ],
  ChannelTerms: [
    { name: "channelId", type: "bytes32" }, { name: "rollupId", type: "bytes32" },
    { name: "settlementContract", type: "address" }, { name: "executor", type: "address" },
    { name: "moduleCodeHash", type: "bytes32" }, { name: "participantRoot", type: "bytes32" },
    { name: "policyHash", type: "bytes32" }, { name: "closeDeadline", type: "uint64" },
  ],
  ChannelPolicy: [{ name: "anchorConfirmation", type: "uint8" }, { name: "maxAnchorLag", type: "uint32" }],
  FinalRequest: [
    { name: "channelId", type: "bytes32" }, { name: "termsHash", type: "bytes32" },
    { name: "anchorId", type: "bytes32" }, { name: "policyHash", type: "bytes32" },
    { name: "executionProfileHash", type: "bytes32" }, { name: "inputHash", type: "bytes32" },
    { name: "nonce", type: "uint64" },
  ],
  ExecutionProfile: [
    { name: "rollupId", type: "bytes32" }, { name: "kind", type: "uint8" },
    { name: "genesisHash", type: "bytes32" }, { name: "programHash", type: "bytes32" },
    { name: "forkSchemaHash", type: "bytes32" }, { name: "daSchemaHash", type: "bytes32" },
    { name: "executorCodeHash", type: "bytes32" },
  ],
} as const;

let failed = 0;
function eq(name: string, got: string, want: string) {
  const ok = got.toLowerCase() === want.toLowerCase();
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `\n  got  ${got}\n  want ${want}`}`);
}

const a = f.anchor;
const anchor = { chainId: BigInt(a.chainId), blockNumber: BigInt(a.blockNumber), blockHash: a.blockHash, stateRoot: a.stateRoot };
eq("anchor.encoded", encodeAbiParameters(types.L1Anchor, [anchor.chainId, anchor.blockNumber, a.blockHash, a.stateRoot]), a.encoded);
eq("anchor.id", hashStruct({ types, primaryType: "L1Anchor", data: anchor }), a.id);

eq("policy.hash", hashStruct({ types, primaryType: "ChannelPolicy", data: f.policy }), f.policy.hash);

const p = f.profile;
eq("profile.hash", hashStruct({ types, primaryType: "ExecutionProfile", data: p }), p.hash);

const t = { ...f.terms, closeDeadline: BigInt(f.terms.closeDeadline) };
eq("terms.hash", hashStruct({ types, primaryType: "ChannelTerms", data: t }), f.terms.hash);

const r = { ...f.request, nonce: BigInt(f.request.nonce) };
const domain = { name: "SkimChannels", version: "0", chainId: f.l1ChainId, verifyingContract: f.settlement as Address };
eq("request.domainSeparator", hashDomain({ domain, types: { EIP712Domain: [
  { name: "name", type: "string" }, { name: "version", type: "string" },
  { name: "chainId", type: "uint256" }, { name: "verifyingContract", type: "address" },
] } }), f.request.domainSeparator);
eq("request.signingHash", hashTypedData({ domain, types, primaryType: "FinalRequest", message: r }), f.request.signingHash);

const tag = keccak256(toHex("skim-channels/channel-id/v0"));
eq("channelId", keccak256(encodeAbiParameters(
  [{ type: "bytes32" }, { type: "uint256" }, { type: "address" }, { type: "address" }, { type: "bytes32" }],
  [tag, BigInt(f.l1ChainId), f.settlement, f.opener, f.salt],
)), f.channelId);
eq("participantRoot", keccak256(encodeAbiParameters([{ type: "address[]" }], [f.participants as Address[]])), f.participantRoot as Hex);

if (failed) { console.error(`${failed} mismatch(es)`); process.exit(1); }
console.log("all commitments match");

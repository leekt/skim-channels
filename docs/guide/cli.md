# CLI reference

`skim-channels` (`cargo build -p channel-runner`; binary at `target/debug/skim-channels`). Every command prints one JSON object.

## `header`

```console
$ skim-channels header --rpc URL --block <number|tag|0xhash> --chain-id N
{"raw":"0xf9…","hash":"0x…","number":…,"stateRoot":"0x…","anchorId":"0x…"}
```

A hash-checked raw header and its anchor id. It prefers the node's raw bytes (`debug_getRawHeader`, by number), and falls back to rebuilding from JSON (skim). Either way, the bytes must hash to the block hash.

## `witness`

```console
$ skim-channels witness --rpc URL --block-hash 0x… --chain-id N \
    --read 0xADDRESS:0xSLOT[:0xSLOT…] [--read …] [--code 0xADDRESS]
{"anchorId":"0x…","rawHeader":"0x…","package":"0x…","packageHash":"0x…"}
```

A witness package at that block's authenticated root, as `abi.encode(WitnessPackage)`, ready for `ChannelExecutor` or `EmergencyExit`. Every proof is re-verified locally, and nothing unverified is returned.

## `evidence`

```console
$ skim-channels evidence --rpc L2_URL --tx 0xTXHASH
{"l2BlockHash":"0x…","l2Header":"0x…","txIndex":…,"receipt":"0x…","receiptProof":[…],"receiptsRoot":"0x…","blockNumber":…}
```

Receipt-inclusion evidence for settlement:
- it uses the node's raw receipts (`debug_getRawReceipts`) where available;
- the whole block's receipt trie must rebuild to the header's receipts root before a proof is cut from it.

The caller adds the signed request and the outcome.

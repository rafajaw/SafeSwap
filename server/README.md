# SafeSwap relayer (Deno)

A single Deno process that (1) serves the built frontend and (2) exposes `POST /relay`, the gasless EIP-7702 relayer.

```
deno task start      # serve frontend/dist + /relay
deno task dev        # same, with --watch
deno task check      # type-check
```

Configure via environment (see `.env.example`). The relayer private key is the system's only secret and lives here,
server-side, by design. Load it however you prefer, e.g. `deno run --env-file=.env --allow-net --allow-read --allow-env relay_server.ts`.

## What `/relay` does

`POST /relay` accepts the JSON body produced by `safeswap.gasless.relay(op)` in the SDK:

```jsonc
{
  "chain_id":           130,
  "user":               "0x...",       // the user's EOA (7702 delegation target + EIP-712 verifyingContract)
  "intent": {                           // the SafeSwapGaslessBond the user signed off-chain
    "helper":          "0x<delegate>",
    "relayer":         "0x<relayer>",
    "relayer_fee":     { "token": "0x...", "amount": "..." },
    "stake":           { "token": "0x...", "amount": "..." },
    "create_deadline": "...",
    "commitment_hash": "0x..."
  },
  "gasless_type_hash":  "0x...",        // re-derived + equality-checked on-chain
  "action_struct_hash": "0x...",        // the protocol action's struct hash
  "signature":          "0x...",        // SafeSwapGaslessBond, signed off-chain by the user
  "execution_data":     { "fundings": [...], "stake": {...}, "salt": "...", "protocol": "0x...", "call": "0x..." },
  "authorization":      { "chainId": 130, "address": "0x<delegate>", "nonce": 0, "r": "0x...", "s": "0x...", "yParity": 0 }
}
```

The relayer **validates before spending any gas**: right chain, the intent pins this relayer and its delegate, the protocol
is the SafeSwap Router or NFT, the commit deadline is in the future, the `SafeSwapGaslessBond` signature recovers to `user`,
and the estimated gas cost is under the `$1` ceiling (fail-closed if no native price is configured). Only then does it
**commit** (`create_bond_from_user_stake`, staking the user's own tokens and paying this relayer its signed fee), **wait**
the reveal delay, and **execute** (`execute_bond_from_user`) — two type-0x04 transactions that run the delegate as the
user's EOA. The user stakes and funds from their own EOA balance; the relayer attaches no value and only sponsors gas.
Native stake/fundings are paid from the EOA's balance via `{ value: ... }`, so native operations are supported. All on-chain
output flows to the `user`.

The response is a `GaslessRelayResult` (`status`, `commitment_hash`, `create_tx_hash`, `execute_tx_hash`).

> **Build-to-spec note.** SafeSwap is not yet deployed; the addresses above are placeholders. This server is complete to
> spec but unverified end-to-end against a live chain — it needs deployed contracts and a funded relayer key on Unichain.
> The two 7702 phases can't be live-`estimateGas`-d before delegation, so `relayer.ts` uses conservative static gas ceilings.

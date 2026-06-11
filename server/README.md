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
  "chain_id":           1301,
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
  "authorization":      { "chainId": 1301, "address": "0x<delegate>", "nonce": 0, "r": "0x...", "s": "0x...", "yParity": 0 }
}
```

The relayer **validates before spending any gas**: right chain, the intent pins this relayer and its delegate, the protocol
is the SafeSwap Router or NFT, the commit deadline is in the future, the `SafeSwapGaslessBond` signature recovers to `user`,
and the estimated gas cost is under the `$1` ceiling (fail-closed if no native price is configured). Only then does it
**commit** (`create_bond_from_user_stake`, staking the user's own tokens and paying this relayer its signed fee) and
**return immediately** with a `GaslessCommit` (`id` = the commitment hash, `create_tx_hash`, `status: "committed"`,
`target_executable_at`). The reveal-delay wait and **execute** (`execute_bond_from_user`) then happen in a background worker.
The user stakes and funds from their own EOA balance; the relayer attaches no value and only sponsors gas. Native
stake/fundings are paid from the EOA's balance via `{ value: ... }`, so native operations are supported. All output flows to
the `user`.

## Address-keyed activity (server-authoritative)

The relayer is the source of truth for a user's gasless ops, so the client never needs local storage:

- `GET /activity/:address` → `{ in_progress, recent }` for that user (each in-progress carries `eta_seconds`).
- `GET /status/:id` → a single bond's public state (`status`, tx hashes, timestamps, `eta_seconds`).

The **worker** (`start_worker`) drains committed bonds to execution — the single mechanism for both fresh execution and
**crash recovery**: a bond committed by *any* process (including one that died mid-flight) is picked up, so the user's locked
stake is never stranded. The store is **postgres** when `DATABASE_URL` is set (durable; `SELECT … FOR UPDATE SKIP LOCKED` to
claim, plus an **advisory-lock leader** so only one container submits at a time — keeping the single relayer EOA's nonces
collision-free across green/blue), or an in-process **memory store** otherwise (local dev / tests). The `gasless_bond` table
is auto-created on boot. *(The postgres path is unverified against a live DB until the docker deploy pass; the memory path is
the one exercised locally.)*

**Authorizations.** The client only signs a 7702 authorization when the EOA is *not* already delegated to this delegate, so
`request.authorization` may be `null`; the relayer then submits without an `authorizationList`. The execute always submits
without one (the commit already delegated the EOA).

> **Note.** SafeSwap is deployed on Unichain Sepolia (chain 1301); the canonical contract addresses are hardcoded in
> `config.ts` (identical on every chain), so the only per-chain config is the RPC, chain id, relayer key, and native price.
> The two 7702 phases can't be live-`estimateGas`-d before delegation, so `relayer.ts` uses conservative static gas ceilings.

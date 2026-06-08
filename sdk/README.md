# @safeswap/sdk

**MEV protection for traders. Repricing revenue for LPs.**

TypeScript client SDK for SafeSwap — BondRoute-protected Uniswap V4 pool operations.

Single-file, viem-based wrapper around `@bondroute/sdk`.

SafeSwap is two BondRoute-protected contracts: a canonical **SwapRouter** (swaps, quoting, hook registry) and an **NFT
position manager** (LP lifecycle). The SDK mirrors that split with two objects on one shared instance:

| Object | Wraps | Operations |
|---|---|---|
| `safeswap.swaps` | SwapRouter | exact-input / exact-output swaps, quoting, pool ids, hook resolution |
| `safeswap.positions` | NFT position manager | create / add / remove / collect LP positions, position getters |

A single `SafeSwap.init()` embeds one BondRoute instance, so storage is scanned once and `on_pending_bond` recovers
unfinished bonds from **both** surfaces in one pass.

## Verified Signing Preview

Every prepared operation exposes the canonical on-chain REFERENCE_2 wallet message:

```typescript
const operation  =  await safeswap.swaps.prepare_swap_exact_input( params );
const preview    =  await operation.get_signing_preview();

console.log( preview.fields );
const signature  =  await operation.sign_verified_execution();
```

The SDK reads ordered display values from the immutable shared `SafeSwapSigningDescriptor`, combines them with BondRoute's
validated type string and raw envelope, and recomputes the complete EIP-712 digest. It rejects the preview or signature if
that digest differs from BondRoute's on-chain signing digest.

## Install

```bash
npm install viem @bondroute/sdk
# Copy sdk/SafeSwap.ts into your project, or install the package once published:
# npm install @safeswap/sdk
```

## Quick Start

```typescript
import { SafeSwap } from "@safeswap/sdk";

const safeswap = await SafeSwap.init({
    public_client,
    wallet_client,
    account,
    on_pending_bond: ( bond ) => bond.resume(),

    // Optional, useful on local deployments and forks:
    router_address:    "0x...",
    nft_address:       "0x...",
    bondroute_address: "0x...",
});

// A swap
const swap = await safeswap.swaps.prepare_swap_exact_input({
    input:  { token: USDC, exact_amount: 1000_000_000n },
    output: { token: WETH, minimum_amount: 390_000_000_000_000_000n },
    pool_info: { base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 },
});

await swap.render_description();
await swap.dispatch();
if(  swap.status === "executed"  ) { /* swap.execution_logs */ }
```

`SafeSwap` delegates the bond lifecycle — persistence, recovery, approvals, balance checks, gas bumping, settlement — to the
embedded BondRoute SDK. After `dispatch()` resolves, switch on `operation.status`.

## Pool configuration

Every operation takes a `pool_info` that selects the dynamic-fee config hook and the pool's tick spacing:

```typescript
type PoolInfo = {
    base_fee_bps:   number;   // base LP fee in bps, 0..999 (0.00%..9.99%)
    rebate_percent: number;   // LP capture share of repricing surplus, 0..90 in 10% steps
    tick_spacing:   number;
};
```

`base_fee_bps` and `rebate_percent` together identify the permissionlessly-deployed config hook clone (each profile is its own
hook address, hence its own pool id). The hook charges `base fee + capture% × surplus` as a native V4 dynamic fee that accrues
path-fairly to the LPs a swap crosses.

## Swaps

```typescript
// Exact input: fixed input, minimum output
const op = await safeswap.swaps.prepare_swap_exact_input({
    input:  { token: USDC, exact_amount: 1000_000_000n },
    output: { token: WETH, minimum_amount: 390_000_000_000_000_000n },
    pool_info: { base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 },
});

// Exact output: exact output, capped input
const op = await safeswap.swaps.prepare_swap_exact_output({
    input:  { token: USDC, maximum_amount: 1100_000_000n },
    output: { token: WETH, exact_amount: 400_000_000_000_000_000n },
    pool_info: { base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 },
});
```

The input token and amount come from the bond funding. The LP fee (base + repricing surplus share) is applied natively by the
hook; the returned operation surfaces the user's net amounts after the separate SafeSwap protocol fee.

### Quoting

Quotes run the **same** simulator and fee formula the hook uses at execution time, so the quoted total fee equals the
executed fee:

```typescript
const { expected_net_output, total_fee_pips, movement_bps } = await safeswap.swaps.quote_swap_exact_input({
    token_in: USDC, token_out: WETH, pool_info, amount_in: 1000_000_000n,
});

const { required_input, total_fee_pips, movement_bps } = await safeswap.swaps.quote_swap_exact_output({
    token_in: USDC, token_out: WETH, pool_info, exact_output_amount: 400_000_000_000_000_000n,
});
```

`total_fee_pips` is the total LP fee in Uniswap V4 pips (100 pips = 1 bps).

### Pool ids and hooks

```typescript
const pool_id = await safeswap.swaps.get_pool_id( USDC, WETH, pool_info );  // tokens in any order
const hook    = await safeswap.swaps.get_hook_address( 30, 50 );            // registered clone for (base_fee_bps, rebate_percent)
```

## Positions (NFT LP)

The NFT position manager owns the V4 positions (salt = token id). The user holds the LP NFT.

```typescript
// Create a new position — mints one NFT to the user
const op = await safeswap.positions.prepare_create_position({
    pool_info: { base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 },
    sqrt_price_lower_x96,
    sqrt_price_upper_x96,
    liquidity: 500_000_000_000_000n,
    sqrt_price_x96: 79228162514264337593543950336n,   // initial price if the pool is new
    a: { token: USDC, amount: 1000_000_000n, minimum_deposited: 990_000_000n },
    b: { token: WETH, amount: 400_000_000_000_000_000n, minimum_deposited: 396_000_000_000_000_000n },
});
await op.dispatch();
const token_id = safeswap.positions.get_minted_token_id( op );   // bigint | null

// Add liquidity — each amount is both the explicit SafeSwap maximum deposit and the matching BondRoute funding cap;
// minimum_deposited is the paired execution floor for that same token.
await safeswap.positions.prepare_add_liquidity({
    token_id,
    liquidity: 250_000_000_000_000n,
    a: { token: USDC, amount: 500_000_000n, minimum_deposited: 495_000_000n },
    b: { token: WETH, amount: 200_000_000_000_000_000n, minimum_deposited: 198_000_000_000_000_000n },
});

// Remove liquidity — released tokens go to the owner; no fundings
await safeswap.positions.prepare_remove_liquidity({
    token_id,
    liquidity: 250_000_000_000_000n,
    a: { token: USDC, minimum_received: 495_000_000n },
    b: { token: WETH, minimum_received: 198_000_000_000_000_000n },
});

// Collect accrued fees — no fundings
await safeswap.positions.prepare_collect_fees({
    token_id,
    a: { token: USDC, minimum_received: 0n },
    b: { token: WETH, minimum_received: 0n },
});
```

### Position getters

```typescript
const info  = await safeswap.positions.get_lp_position( token_id );                 // immutable metadata (hook, tokens, ticks, config)
const state = await safeswap.positions.get_position_state( pool_id, token_id, info.tick_lower, info.tick_upper );  // live V4 liquidity + fee growth
```

## Stake Token Selection

The position operations (`prepare_create_position`, `prepare_add_liquidity`, `prepare_remove_liquidity`,
`prepare_collect_fees`) accept an optional `preferred_stake_token`. Swaps do not — a swap's bond stake is always a share of
its single input funding.

If you pass `preferred_stake_token`, it must be one of the two pool tokens and is used exactly.

If you omit it, the SDK prepares two candidate bonds (one quoted with pool token0 as the stake preference, one with token1),
checks current wallet balances for both, and returns an affordable bond. If both are affordable, native token wins when it is
one of the pool tokens; otherwise token0 by address order. If neither is affordable, token0 is returned so BondRoute's normal
balance error can report the shortfall.

This makes omitted stake preference balance-sensitive. Pass `preferred_stake_token` when the stake token must be deterministic.

## Bond Lifecycle

Every `prepare_*` returns a dispatchable operation backed by a BondRoute `Bond`. Inspect it before dispatch:

```typescript
const description       = await op.render_description();
const fundings          = op.execution_data.fundings;
const stake             = op.execution_data.stake;
const constraints       = op.constraints;
const missing_balances  = await op.get_missing_balances();
const missing_approvals = await op.get_missing_approvals();
const native_create     = op.get_native_value_for_create();
const native_execute    = op.get_native_value_for_execute();

await op.dispatch();
```

For custom flows, drive the lifecycle manually:

```typescript
await op.approve_if_needed();
await op.create();
await op.wait_until_executable();
await op.execute();
```

Bond management helpers live on the `SafeSwap` instance and span both surfaces:

```typescript
const pending = await safeswap.list_pending();
const stop    = safeswap.watch_bond( op, ( snapshot ) => updateUi( snapshot ) );
const json    = safeswap.serialize_bond( op );
const back    = safeswap.deserialize_bond( json );
```

## Reverts

The SDK exports `SAFESWAP_ABI`, `parse_safeswap_revert()`, and `explain_safeswap_revert()` for protocol revert handling:

```typescript
import { parse_safeswap_revert, explain_safeswap_revert } from "@safeswap/sdk";

if(  op.status === "protocol_reverted"  )
{
    const parsed  = parse_safeswap_revert( op.revert_output );   // discriminated by parsed.kind
    const message = explain_safeswap_revert( op.revert_output ); // human-readable string
}
```

Parsed kinds include `slippage_exceeded`, `maximum_input_exceeded`, `one_sided_deposit_mismatch`,
`modify_liquidity_tokens_mismatch`, `invalid_liquidity_modification`, `position_info_mismatch`, `position_unauthorized`,
`pool_initialization_price_mismatch`, `hook_config_not_registered`, `unauthorized`, `unsupported_call`, `invalid`,
`transfer_failed`, and `unknown`.

## Address Overrides

Defaults are the canonical same-across-chains addresses: `SAFESWAP_ROUTER_ADDRESS`, `SAFESWAP_NFT_ADDRESS`, and BondRoute's
own canonical address. Pass `router_address`, `nft_address`, or `bondroute_address` to `SafeSwap.init()` only when targeting
non-canonical deployments (forks, testnets, local).

## Validation

The SDK rejects obviously-malformed inputs before quoting — distinct tokens, positive amounts, tick alignment, and a
`pool_info` whose `base_fee_bps` is 0..999 and `rebate_percent` is a 10% step in 0..90. Everything else — fee math, token
ordering, funding counts, slippage — remains the chain layer's source of truth.

## Testing

```bash
bun install
bun test
bun run typecheck
```

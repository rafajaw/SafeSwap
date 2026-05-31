# @safeswap/sdk

TypeScript client SDK for SafeSwap — BondRoute-protected Uniswap V4 pool operations.

Single-file, viem-based wrapper around `@bondroute/sdk`.
The SafeSwap and BondRoute contracts use their canonical same-across-chains addresses by default.
Optional overrides are available for tests, forks, and local deployments.

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
    safeswap_address:  "0x...",
    bondroute_address: "0x...",
});

const operation = await safeswap.prepare_swap_exact_input({
    input: { token: USDC, exact_amount: 1000_000_000n },
    output: { token: WETH, minimum_amount: 390_000_000_000_000_000n },
    pool_info: { fee: 3000, tick_spacing: 60 },
});

await operation.render_description();
operation.execution_data.fundings;
operation.execution_data.stake;
operation.constraints;
await operation.get_missing_balances();
await operation.get_missing_approvals();

await operation.dispatch();
```

`SafeSwap` delegates bond lifecycle, persistence, recovery, approvals, balance checks, gas bumping, and settlement handling to the embedded BondRoute SDK.
After `dispatch()` resolves, switch on `operation.status`.

## Address Overrides

By default the SDK uses:

```typescript
SAFESWAP_ADDRESS
```

Pass `safeswap_address` or `bondroute_address` to `SafeSwap.init()` only when targeting non-canonical deployments.

## Bond Lifecycle

Preparing an operation returns a dispatchable SafeSwap operation backed by a BondRoute `Bond`. Inspect it before dispatch to render confirmation UI or handle missing wallet state:

```typescript
const operation = await safeswap.prepare_swap_exact_input({ ... });

const description = await operation.render_description();
const fundings = operation.execution_data.fundings;
const stake = operation.execution_data.stake;
const constraints = operation.constraints;
const missing_balances = await operation.get_missing_balances();
const missing_approvals = await operation.get_missing_approvals();
const native_create_value = operation.get_native_value_for_create();
const native_execute_value = operation.get_native_value_for_execute();

await operation.dispatch();
```

For custom flows, drive the lifecycle manually:

```typescript
await operation.approve_if_needed();
await operation.create();
await operation.wait_until_executable();
await operation.execute();
```

Use `watch_bond()` or `operation.get_status()` to update UI while the operation is creating, waiting, executing, or settled.

## Reverts

The SDK exports `SAFESWAP_ABI`, `parse_safeswap_revert()`, and `explain_safeswap_revert()` for protocol revert handling:

```typescript
import { parse_safeswap_revert, explain_safeswap_revert } from "@safeswap/sdk";

if( operation.status === "protocol_reverted" )
{
    const parsed = parse_safeswap_revert( operation.revert_output );
    const message = explain_safeswap_revert( operation.revert_output );
}
```

## Operations

All operations return a prepared operation; call `operation.dispatch()` to create, wait, and execute.

```typescript
await safeswap.prepare_swap_exact_input({ ... });
await safeswap.prepare_swap_exact_output({ ... });
await safeswap.prepare_add_liquidity({ ... });
await safeswap.prepare_remove_liquidity({ ... });
await safeswap.prepare_donate({ ... });
```

```typescript
await safeswap.prepare_swap_exact_output({
    input: { token: USDC, maximum_amount: 1100_000_000n },
    output: { token: WETH, exact_amount: 400_000_000_000_000_000n },
    pool_info: { fee: 3000, tick_spacing: 60 },
});

await safeswap.prepare_add_liquidity({
    a: { token: USDC, amount: 1000_000_000n, minimum_added: 990_000_000n },
    b: { token: WETH, amount: 400_000_000_000_000_000n, minimum_added: 396_000_000_000_000_000n },
    pool_info: { fee: 3000, tick_spacing: 60 },
    tick_lower: -887220,
    tick_upper: 887220,
});

await safeswap.prepare_remove_liquidity({
    a: { token: USDC, minimum_received: 990_000_000n },
    b: { token: WETH, minimum_received: 396_000_000_000_000_000n },
    pool_info: { fee: 3000, tick_spacing: 60 },
    tick_lower: -887220,
    tick_upper: 887220,
    liquidity: 500_000_000_000_000n,
});

await safeswap.prepare_donate({
    a: { token: USDC, amount: 100_000_000n },
    b: { token: WETH, amount: 40_000_000_000_000_000n },
    pool_info: { fee: 3000, tick_spacing: 60 },
});
```

## Stake Token Selection

`prepare_add_liquidity`, `prepare_remove_liquidity`, and `prepare_donate` accept `preferred_stake_token`.

If you pass `preferred_stake_token`, the SDK requires it to be one of the two pool tokens and uses it exactly.

If you omit `preferred_stake_token`, the SDK prepares two candidate bonds: one quoted with pool token0 as the stake preference and one quoted with pool token1.
It checks current wallet balances for both candidates and returns an affordable bond.
If both candidates are affordable, native token wins when it is one of the pool tokens; otherwise token0 by address order wins.
If neither candidate is affordable, token0 by address order is returned so BondRoute's normal balance error can report the shortfall.

This means omitted stake preference is balance-sensitive. Pass `preferred_stake_token` when the stake token must be deterministic.

The SDK intentionally leaves most SafeSwap parameter validation to the chain layer.
Contract quote/execution logic remains the source of truth for fee tiers, ticks, token ordering, funding counts, and slippage constraints.

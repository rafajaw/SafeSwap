# SafeSwap

**MEV-protected pools. Repricing revenue for LPs.**

SafeSwap enforces every swap and liquidity operation through [BondRoute](https://bondroute.xyz)'s commit-reveal bond
mechanism, eliminating MEV extraction at the protocol level. On top of that, when a swap moves the pool price, SafeSwap
charges a configured share of the estimated repricing surplus to LPs — turning repricing from arbitrageur extraction into
LP revenue, without an oracle or trusted sequencer. See `LVR_DETERRENCE.md` and `REPRICING_REBATE_ADDRESS_CONFIG.md`.

## How it works

[BondRoute](https://bondroute.xyz) is a singleton on-chain contract that enforces a simple invariant: **creating a bond commits you to attempting execution, or you forfeit your stake.** There is no cancellation path.

SafeSwap plugs into this:

1. User creates a bond through BondRoute — posting only a commitment hash and a stake. Everything else (protocol, function, parameters, funded tokens, user address) is hidden inside the hash.
2. After a minimum block delay, the user reveals and executes. BondRoute calls SafeSwap's protected function with the bond context.
3. The `SafeSwapRouter` executes the action; the pool's `SafeSwapHook` rejects any V4 callback whose `sender` is not the canonical router, so only BondRoute-routed actions can touch SafeSwap pools.

This gives two layers of protection:

- **Reserved execution** — intent is hidden until reveal, and a block delay separates commitment from execution. Attackers can't see what to frontrun.
- **Abandonment cost** — creating speculative bonds to farm multiple outcomes costs real stake on every abandoned bond. The economics make MEV extraction irrational.

All bonds flow through the same BondRoute singleton. Attackers observing the mempool see only opaque commitment hashes and stake amounts — they cannot distinguish which protocol, function, or user a bond targets.

No off-chain relayers. No trusted sequencers. No special permissions.

## Architecture

A canonical router, a shared LP-position NFT, and many permissionlessly-deployed config hooks (one per rebate profile).

```
Orchestrator, HookRegistry, BondRouteProtected -> User -> BondRouteIntegration -> SafeSwapRouter
Treasury -> SafeSwapRouter
SafeSwapHook (standalone, one instance per rebate profile)
SafeSwapNft (standalone, shared)
```

| Contract | Role |
|---|---|
| `SafeSwapRouter.sol` | Canonical BondRoute-protected entrypoint: swaps, liquidity, donate, rebate engine, registry, treasury |
| `SafeSwapHook.sol` | Per-profile Uniswap V4 config hook; gates pool actions to the router; rebate profile encoded in its address |
| `SafeSwapNft.sol` | Shared ERC721 LP-position registry across all pools and profiles |
| `Orchestrator.sol` | PoolManager integration: pool init + unlock-callback dispatch |
| `HookRegistry.sol` | Permissionless hook registration + resolution (runtime-codehash + address-bit + V4-permission auth) |
| `BondRouteIntegration.sol` | BondRoute selectors, quote, validation, and signing-info dispatch |
| `User.sol` | User-facing functions + off-chain getters (incl. rebate preview) |
| `Treasury.sol` | Protocol-fee withdrawal + role transfer |
| `BondRouteProtected.sol` | Commit-reveal bond mechanism (inherited from BondRoute) |

Libraries (external, delegatecall-linked `execute`): `ExactInputSwapLib`, `ExactOutputSwapLib`, `ModifyLiquidityLib`, `DonateLib`, `SafeSwapCommon`

### Pool identity & capture profiles

A SafeSwap pool is a dynamic-fee Uniswap V4 pool whose hook clone address encodes `(base_fee_bps, capture_percent)`, so each
profile yields a distinct `PoolId` for otherwise-identical pool parameters. Users select a pool by `(base_fee_bps,
capture_percent, tick_spacing)`; the router resolves the hook from its registry.

### LP repricing rebate

`total fee = base LP fee + protocol fee + repricing fee`, where `repricing fee = capture_percent × estimated repricing
surplus`. The surplus is valued at the simulated post-swap price and paid through V4's dynamic LP fee path, so LPs earn from
the repricing they make possible while swappers keep explicit minimum-output / maximum-input protection. Capture profiles
range `0%..90%`.

## Operations

| Function | Description |
|---|---|
| `bonded_swap_exact_input` | Swap a known input amount for at least `minimum_output_amount` (net of protocol fee + rebate) |
| `bonded_swap_exact_output` | Swap up to the funded amount to receive exactly `exact_output_amount` |
| `bonded_create_position` | Open a new NFT-backed liquidity position (initializing the pool if needed) |
| `bonded_add_liquidity` | Add liquidity to an existing position (by token id) |
| `bonded_remove_liquidity` | Withdraw liquidity from a position (by token id) |
| `collect_fees` | Directly collect accrued fees for a position (by token id; owner or approved operator) |
| `donate` | Donate tokens to a pool's in-range liquidity providers |
| `register_hook` / `get_hook` | Register a deployed config hook / resolve the hook for a rebate profile |
| `withdraw_protocol_fees` | Treasury withdraws accumulated protocol fees |

## Protocol fee

A deterministic surcharge replaces stochastic MEV loss. The swapper pays `max(0.01%, 10% of LP fee)` of the swap output; LPs are unaffected and keep their full LP fee through Uniswap V4's internal accounting.

| Pool | Protocol fee | Replaces typical MEV loss of |
|---|---|---|
| 0.01% stablecoin | 0.01% | 0.05–0.25% (CEX–DEX arb, JIT-LP sandwich) |
| 0.05% blue-chip | 0.01% | 0.5–2% |
| 0.30% volatile | 0.03% | 0.5–2% routinely, 2–5% on large trades |
| 1.00% long-tail | 0.10% | 2–10%+ |

Across every tier, the fee is between **5× and 200× cheaper** than the MEV the user would otherwise bear — and predictable rather than variable. Even users routing through private relays or solver auctions still lose 0.10–0.50% in residual MEV and solver spread; SafeSwap eliminates that entirely.

Fees accumulate in the hook contract and are withdrawn by the collector.

## Gas overhead

A protected swap costs ~80-130k gas more than a direct Uniswap V4 swap:

| Component | Gas |
|---|---|
| BondRoute (ERC20 stake, warm) | ~62k |
| SafeSwap execution | ~67k |
| Uniswap V4 pool swap | ~100-150k |
| **Total** | **~230-280k** |

Hook callbacks alone add under 4k gas each.

## Build & test

```sh
foundryup -v stable
forge build
forge test
```

228 tests across 18 suites: unit, integration, fuzz, invariant, canonical BondRoute, and real pool tests against the actual Uniswap V4 PoolManager.

## License

MIT

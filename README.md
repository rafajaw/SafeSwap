# SafeSwap

**Trustless MEV-free swaps and liquidity on Uniswap V4.**

SafeSwap is a Uniswap V4 hook that enforces every swap and liquidity operation through [BondRoute](https://bondroute.xyz)'s commit-reveal bond mechanism, eliminating MEV extraction at the protocol level.

## How it works

[BondRoute](https://bondroute.xyz) is a singleton on-chain contract that enforces a simple invariant: **creating a bond commits you to attempting execution, or you forfeit your stake.** There is no cancellation path.

SafeSwap plugs into this:

1. User creates a bond through BondRoute — posting only a commitment hash and a stake. Everything else (protocol, function, parameters, funded tokens, user address) is hidden inside the hash.
2. After a minimum block delay, the user reveals and executes. BondRoute calls SafeSwap's protected function with the bond context.
3. SafeSwap's `beforeSwap` / `beforeAddLiquidity` / `beforeRemoveLiquidity` hooks reject any call not originating from a valid bond execution.

This gives two layers of protection:

- **Reserved execution** — intent is hidden until reveal, and a block delay separates commitment from execution. Attackers can't see what to frontrun.
- **Abandonment cost** — creating speculative bonds to farm multiple outcomes costs real stake on every abandoned bond. The economics make MEV extraction irrational.

All bonds flow through the same BondRoute singleton. Attackers observing the mempool see only opaque commitment hashes and stake amounts — they cannot distinguish which protocol, function, or user a bond targets.

No off-chain relayers. No trusted sequencers. No special permissions.

## Architecture

```
BondRouteProtected, UniswapHook -> User -> Collector -> SafeSwap
```

| Contract | Role |
|---|---|
| `SafeSwap.sol` | Entry point - BondRoute interface overrides |
| `User.sol` | User-facing functions (swap, liquidity) + off-chain getters |
| `Collector.sol` | Fee withdrawal + role transfer |
| `UniswapHook.sol` | PoolManager integration, V4 callbacks, protected context |
| `BondRouteProtected.sol` | Commit-reveal bond mechanism (inherited from BondRoute) |

Libraries: `ExactInputSwapLib`, `ExactOutputSwapLib`, `AddLiquidityLib`, `RemoveLiquidityLib`, `SafeSwapCommon`

## Operations

| Function | Description |
|---|---|
| `swap_exact_input` | Swap a known input amount for at least `minimum_amount_out` |
| `swap_exact_output` | Swap up to the funded amount to receive exactly `amount_out` |
| `add_liquidity` | Provide liquidity to a pool within a tick range |
| `remove_liquidity` | Withdraw liquidity from a position |
| `withdraw_fees` | Collector withdraws accumulated protocol fees |

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

202 tests across 15 suites: unit, integration, fuzz, invariant, and real pool tests against the actual Uniswap V4 PoolManager.

## License

MIT

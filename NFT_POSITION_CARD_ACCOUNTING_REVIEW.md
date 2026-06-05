# SafeSwap LP NFT Card & Accounting Review

## Goal

Turn the SafeSwap LP NFT into a useful investor-facing position certificate, not just decorative metadata.

The card should help a buyer compare LP NFTs by showing:

- current claimable fees;
- lifetime fees earned;
- position age;
- fee run-rate / yield estimate;
- current in-range status;
- price range, ideally in human price terms rather than raw ticks.

The design must stay honest: avoid claiming exact APY or saved MEV unless the denominator and accounting are defensible.

## Current Direction

The NFT already stores immutable position identity:

- `hook`;
- `token0`;
- `token1`;
- `base_fee_bps`;
- `rebate_percent`;
- `tick_spacing`;
- `tick_lower`;
- `tick_upper`.

The descriptor can read live V4 state:

- current `sqrtPriceX96`;
- current tick;
- current position liquidity;
- current fee growth inside the tick range.

The proposed minimal persistent accounting is:

- `opened_at`;
- lifetime realized fees for both pool tokens.

Everything else can be computed live from V4 state.

## Storage Options

### Option A: Current Minimal Fee Totals

Store:

```solidity
struct FeeTotals {
    uint256 token0;
    uint256 token1;
}
```

Cost:

- 2 storage slots;
- first nonzero write: about 40k gas if both become nonzero;
- later nonzero-to-nonzero updates: about 10k gas for both.

Pros:

- simple;
- exact lifetime realized fees by token;
- supports a useful “Lifetime earned” card row.

Cons:

- no opened date;
- no annualized yield;
- currently uses full `uint256` when `uint128` is likely sufficient.

### Option B: Packed Fees + Opened Date

Store:

```solidity
struct FeeTotals {
    uint128 token0;
    uint128 token1;
}
```

Add:

```solidity
uint40 opened_at;
```

Packing target:

- `fees0 | fees1` in one slot;
- `opened_at` packed into the position metadata record if storage layout is reorganized.

Cost:

- 1 new storage slot for fees;
- likely 0 new slots for `opened_at` if packed carefully;
- first fee realization: about 20k gas;
- later fee updates: about 5k gas.

Pros:

- enough for claimable + lifetime fees + age + annualized estimates;
- cheapest useful investor-card option.

Cons:

- no deposit/withdraw history;
- yield denominator must be computed from current liquidity, not historical capital basis.

### Option C: Full Per-Token Capital Accounting

Store:

```solidity
uint128 deposited0;
uint128 deposited1;

uint128 withdrawn0;
uint128 withdrawn1;

uint128 fees0;
uint128 fees1;
```

Packing:

- deposited pair: 1 slot;
- withdrawn pair: 1 slot;
- fees pair: 1 slot;
- `opened_at` packed elsewhere.

Cost:

- 3 new accounting slots;
- first write to each slot is about 20k gas;
- later updates about 5k gas per touched slot.

Pros:

- strongest asset-history card;
- supports deposited capital, withdrawn capital, net capital, lifetime fees.

Cons:

- storage-heavy;
- LP actions pay more gas;
- not required for a useful APY estimate if current capital value is acceptable.

### Option D: Time-Weighted Capital Accounting

Store normalized values:

```solidity
uint128 fees_value;
uint128 current_capital_value;
uint128 capital_seconds;
uint40 opened_at;
uint40 last_accounted_at;
```

Purpose:

```text
annualized_yield = fees_value * 365 days / capital_seconds
```

Pros:

- handles mid-position liquidity changes more correctly;
- gives a defensible time-weighted yield estimate.

Cons:

- requires normalizing token values at every LP action;
- more complex;
- depends on pool spot price at accounting time;
- likely 2-3 slots and more math.

## Recommended v1 Storage

Use Option B:

```solidity
struct FeeTotals {
    uint128 token0;
    uint128 token1;
}
```

Add `opened_at` as `uint40`, packed into the position record if possible.

Rationale:

- only one new slot for the fee totals;
- no swap pays this storage cost;
- LP position actions pay for the better position certificate;
- sufficient for current claimable fees, lifetime earned fees, age, and live yield estimate.

## Who Pays the Storage Cost

Normal swaps do not touch SafeSwap NFT accounting.

Swap path:

```text
SafeSwapRouter.swap_exact_input/output
  -> PoolManager.unlock
  -> PoolManager.swap
  -> SafeSwapHookImpl.beforeSwap
```

SafeSwap hook `beforeSwap` is `view`; it computes the dynamic fee override and writes no SafeSwap storage.

NFT accounting updates only on:

- `create_position`;
- `add_liquidity`;
- `remove_liquidity`;
- `collect_fees`.

Storage written during a swap is in:

- BondRoute execution/status accounting;
- Uniswap V4 PoolManager pool state, fee growth, tick crossing state, and balances.

SafeSwapRouter and SafeSwapHook do not add persistent swap accounting writes.

## Correct Fee Realization

Fee accounting must happen before every existing-position liquidity change.

Sequence:

```text
1. Read old liquidity and old feeGrowthInsideLast.
2. Read current feeGrowthInside.
3. Compute accrued fees using OLD liquidity:
   fee0 = (currentGrowth0 - lastGrowth0) * oldLiquidity / Q128
   fee1 = (currentGrowth1 - lastGrowth1) * oldLiquidity / Q128
4. Add those fees to lifetime fee totals.
5. Call modifyLiquidity(add/remove/collect).
```

Why:

- before add: prevents old fees being credited to newly added liquidity;
- before remove: prevents old fees being lost or understated after liquidity decreases;
- before collect: records the fees that are about to be collected.

This makes lifetime fee totals robust across add/remove/collect.

## Yield and APY Definitions

Fees alone are not yield.

```text
yield = income / capital
```

To estimate yield without storing deposit history:

1. Read current liquidity.
2. Compute current principal amounts from:

```text
current sqrt price
tick_lower
tick_upper
liquidity
```

3. Convert principal and fees into one token using current pool price.
4. Compute:

```text
fee_value = lifetime_fees + claimable_fees, normalized at current pool price
capital_value = current principal value, normalized at current pool price
lifetime_yield = fee_value / capital_value
annualized_yield = lifetime_yield * 365 days / position_age
monthly_pace = annualized_yield / 12
```

Suggested label:

```text
APY estimate at current pool price
```

Avoid presenting it as exact APY unless time-weighted capital accounting is added.

## Liquidity Change Caveat

Using current capital value as the denominator can skew interpretation when liquidity changes mid-life.

Example add:

```text
Day 1: $10k liquidity earns $1k fees.
Day 31: LP adds $90k liquidity.
Current capital = $100k.
Displayed yield = 1%.
Original capital actually earned 10%.
```

Example remove:

```text
Day 1: $100k liquidity earns $1k fees.
Day 31: LP removes $90k liquidity.
Current capital = $10k.
Displayed yield = 10%.
```

Therefore, the cheap v1 metric should be labelled as:

```text
Yield on current liquidity
```

or:

```text
APY estimate at current pool price
```

For true time-weighted APY, add `capital_seconds` accounting or compute it off-chain from events.

## Price Range Display

Raw ticks are developer-facing.

Current:

```text
Ticks: -120 to 120
```

Preferred investor-facing card:

```text
Market
Current 3,002 USDC/ETH
Range   2,850 - 3,150
```

or:

```text
Price range
2,850 - 3,150 USDC per ETH
```

Storage needed: none.

Required live inputs:

- `sqrtPriceX96`;
- `tick_lower`;
- `tick_upper`;
- token decimals.

Caveat:

- on-chain price formatting adds bytecode and math;
- if descriptor size becomes a concern, keep raw ticks for v1 and render human prices in frontend.

## Number Formatting

Do not show raw base units or abbreviations like `m`/`t` for token amounts.

The descriptor should:

- call `decimals()` safely;
- use 18 decimals for native ETH;
- fall back to 18 if ERC20 metadata is missing/reverting;
- render normalized token amounts with limited precision;
- show very small nonzero values as `<0.0001`.

Checked vendored libraries:

- OpenZeppelin `Strings` only formats integers/hex;
- Solmate `LibString` only formats integers;
- no library in `lib/` formats ERC20 base units into decimal token amounts.

So a local formatter is reasonable.

## Proposed Card Layout

```text
SafeSwap LP
ETH / USDC

Claimable fees
0.0093 ETH
180.5 USDC

Lifetime earned
0.078 ETH / 2,450 USDC

Yield estimate
8.0% lifetime
24.3% annualized

Market
Current 30,000 USDC/ETH
Range   28,500 - 31,500

Opened 120d ago
In Range
Fee: 0.05% + 20% rebate
```

If current capital value is zero:

```text
Closed
Yield n/a
```

If position age is too short:

```text
APY n/a
```

## Open Questions for Review

1. Should v1 show “APY estimate” or the more conservative “Yield on current liquidity”?
2. Is one extra fee slot plus packed `opened_at` acceptable for mainnet LP actions?
3. Should `fees0/fees1` be `uint128`, and what overflow assumptions are acceptable?
4. Should human price range be rendered on-chain, or left to frontend/indexer to save descriptor bytecode?
5. Should accounting events be emitted for richer off-chain trailing-month charts and time-weighted APY?
6. Should the NFT card include both raw fee attributes and human-formatted fee attributes for marketplaces?


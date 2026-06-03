# SafeSwap Repricing Rebate — Executive Summary & Dev Playbook

## 1. Core idea

SafeSwap currently protects pool actions by requiring them to go through BondRoute wrapping.

That is useful as an access-control / execution-discipline layer, but by itself it does **not** solve LVR. A bonded arbitrageur can still move a stale pool and capture most of the repricing value.

The proposed upgrade is:

> **When a swap moves the pool price, SafeSwap charges an additional fee proportional to that price movement and rebates it to LPs.**

This is an oracle-free anti-LVR mechanism.

It does **not** try to know the external fair price.

It simply says:

> **If you move the pool, you pay LPs for moving the pool.**

---

# 2. Mechanism in one sentence

```text
total swap fee = base LP fee + repricing rebate fee
```

Where:

```text
repricing rebate fee = price movement caused by swap × repricingRebateBps
```

Example:

```text
swap moves pool price by 2%
repricingRebateBps = 5000 // 50%
repricing rebate fee = 1%
```

So the trader pays an extra `1%`, and that value accrues to LPs.

---

# 3. Why this exists

## The LVR problem

In a classic AMM:

```text
external market price moves
pool price lags
arbitrageur moves the pool
LPs sell/buy along the stale curve
arbitrageur captures the repricing surplus
```

The AMM LP is not merely rebalancing.

The LP is being rebalanced **through stale prices**.

That is the wound.

## SafeSwap’s current protection gap

If SafeSwap only requires BondRoute wrapping:

```text
external price moves
pool is stale
arb uses valid BondRoute path
pool moves
LPs still leak repricing value
```

The action is authorized, but not necessarily economically fair to LPs.

So SafeSwap needs to transform:

```text
protected access
```

into:

```text
priced access
```

The repricing rebate does that.

---

# 4. Design philosophy

## Do not use an external price oracle

We intentionally avoid:

```text
Chainlink
CEX prices
TWAP comparisons
external fair value
off-chain keepers
trusted sequencers
validator auctions
```

Reason:

```text
oracle risk
latency
manipulation
unsupported long-tail assets
centralization
complexity
```

The mechanism only uses the pool’s own internal state:

```text
price before swap
price after swap
tick movement
```

This keeps it deterministic, permissionless, and easy to reason about.

---

# 5. What the mechanism actually measures

It does **not** measure:

```text
true LVR
external mispricing
arbitrage profit
fair price deviation
```

It measures:

```text
pool price displacement caused by this swap
```

That is enough.

The thesis is:

> **Pool displacement is the observable on-chain proxy for repricing risk.**

If bots race to move the pool toward a focal price, SafeSwap does not need to know that focal price.

It simply collects a toll on the path.

---

# 6. Why linear pricing

The recommended v1 is **linear**:

```text
repricing fee = k × price movement
```

or:

```text
repricing fee = price movement × repricingRebateBps / 10_000
```

Linear is robust because splitting does not materially reduce the total fee.

Example:

```text
one swap moves 5%
fee = k × 5%
```

Split into five swaps:

```text
swap 1 moves 1% → k × 1%
swap 2 moves 1% → k × 1%
swap 3 moves 1% → k × 1%
swap 4 moves 1% → k × 1%
swap 5 moves 1% → k × 1%

total = k × 5%
```

So batching, multicall, and trade slicing do not trivially bypass the mechanism.

A convex curve may be theoretically better for extreme moves, but it introduces splitting attacks unless you track cumulative movement. Do not start there.

---

# 7. Naming

Use:

```solidity
repricingRebateBps
```

Definition:

> `repricingRebateBps` is the share of pool price displacement charged as an additional swap fee and rebated to LPs.

Example:

```solidity
repricingRebateBps = 5000;
```

Meaning:

```text
LPs receive 50% of the price movement caused by the swap as a repricing rebate.
```

Use “rebate” because DeFi users understand it as value returned to the party that would otherwise be exploited.

In docs, first mention should be explicit:

> **LP repricing rebate**.

After that, `repricingRebateBps` is acceptable.

---

# 8. Parameterization

SafeSwap should not hardcode 50%.

The pool creator should choose `repricingRebateBps`.

This allows the market to discover the equilibrium.

Examples:

```text
USDC/USDT:
  low repricing rebate, maybe 5%–10%

ETH/USDC:
  medium repricing rebate, maybe 25%–50%

SHIB/USDC:
  high repricing rebate, maybe 50%–80%

new meme token:
  high repricing rebate, maybe 75%–100%
```

The correct value depends on:

```text
asset volatility
liquidity depth
user tolerance
routing competition
LP risk appetite
flow toxicity
```

There is no universal number.

---

# 9. Discrete profiles

Do not allow every possible bps value initially.

If `repricingRebateBps` is arbitrary from `0` to `10_000`, liquidity can fragment across too many pools.

Recommended discrete profiles:

```text
0
1000  // 10%
2500  // 25%
5000  // 50%
7500  // 75%
10000 // 100%
```

Optional expanded set:

```text
0
500
1000
2500
5000
7500
10000
```

This gives enough market choice without creating 10,000 indistinguishable pool variants.

---

# 10. Pool identity model

SafeSwap should conceptually extend the pool key.

A normal Uniswap v4 pool is identified by something like:

```text
token0
token1
fee
tickSpacing
hook
```

SafeSwap should wrap this into:

```solidity
struct SafeSwapPoolParams {
    Currency currency0;
    Currency currency1;
    uint24 baseFee;
    int24 tickSpacing;
    uint16 repricingRebateBps;
}
```

Then SafeSwap resolves the appropriate hook / pool configuration.

The economic pool identity becomes:

```text
token pair + base fee + tick spacing + repricing rebate profile
```

So the market can have:

```text
SHIB/USDC, base 0.30%, rebate 25%
SHIB/USDC, base 0.30%, rebate 50%
SHIB/USDC, base 0.30%, rebate 75%
```

LPs choose where to provide liquidity.

Routers choose where execution is best.

The equilibrium emerges.

---

# 11. Hook deployment model

idk we gotta discuss this but i think we could track the rebate tier using the salt like use the lowest order byte of the salt to encode rebate bps? or something akin to it

---

# 13. Formula

## Conceptual formula

```text
totalFee = baseFee + repricingRebateFee
```

Where:

```text
repricingRebateFee = priceMovement × repricingRebateBps / 10_000
```

## Tick-based formula

Use tick movement, not reserve ratio.

```text
tickDelta = abs(tickAfter - tickBefore)
```

Each tick corresponds approximately to a price ratio of `1.0001`.

So:

```text
priceMovement = 1.0001^tickDelta - 1
```

Rule of thumb:

```text
100 ticks ≈ 1% price movement
```

Approximate bps:

```text
movementBps ≈ tickDelta
```

Because:

```text
1 tick ≈ 1 basis point
```

More precisely, 1 tick is about `0.01%`, which is 1 bps.

For v1, the tick approximation may be acceptable if handled carefully.

Then:

```solidity
repricingFeeBps = movementBps * repricingRebateBps / 10_000;
```

Example:

```text
tickDelta = 200
movement ≈ 200 bps = 2%

repricingRebateBps = 5000

repricingFeeBps = 200 * 5000 / 10000 = 100 bps = 1%
```

Then:

```text
totalFeeBps = baseFeeBps + repricingFeeBps
```

---

# 14. Use tick movement, not token ratio

Do **not** use:

```text
token0 balance / token1 balance
```

Reason:

In concentrated liquidity AMMs, reserve ratio can be misleading because liquidity is distributed across ranges.

Use:

```text
sqrtPriceX96
tick
```

Prefer:

```solidity
abs(tickAfter - tickBefore)
```

That is the clean internal measure of pool price displacement.

---

# 15. Current-swap fee must be charged

The fee must apply to the swap that causes the movement.

Bad:

```text
afterSwap observes large movement
future swaps pay more
```

Good:

```text
beforeSwap estimates movement
current swap pays repricing rebate
```

Otherwise the first mover captures the value and teaches the hook too late.

---

# 16. The circularity problem

There is a technical circularity:

```text
fee affects amount in/out
amount affects tickAfter
tickAfter affects fee
```

For v1, use a simple deterministic approximation.

Recommended approach:

```text
1. Estimate tickAfter using base fee or pre-fee amount.
2. Compute tickDelta.
3. Compute repricing fee.
4. Apply total fee to current swap.
```

This may slightly over/undercharge but is simple.

Alternative later:

```text
bounded iterative calculation
```

Do not introduce unnecessary complexity in v1.

---

# 17. Exact-input vs exact-output

## Exact-input swaps

Easier.

Given:

```text
amountIn
baseFee
current liquidity
current tick
```

Estimate how far the swap moves the price.

Then compute the repricing fee.

## Exact-output swaps

Harder.

The user demands:

```text
amountOut
```

Required input depends on fee, and fee depends on movement.

Options:

```text
support exact-input first
or handle exact-output conservatively
or route exact-output through quote simulation
```

For v1, if timeline is tight, prioritize exact-input correctness.

---

# 18. Fee destination

The repricing rebate should go mostly or entirely to LPs.

Product claim:

> **SafeSwap rebates LPs when traders reprice the pool.**

If the protocol takes a large cut, the story weakens.

Recommended v1:

```text
100% of repricing rebate to LPs
```

Optional later:

```text
90% LPs
10% protocol
```

But do not start with protocol extraction if the goal is LVR protection credibility.

---

# 19. Relationship to base fee

The base fee and repricing rebate are both swap fees, but they price different things.

## Base fee

```text
price of ordinary liquidity access
```

Applies to every swap.

## Repricing rebate

```text
price of moving the pool
```

Applies proportionally to price/tick movement.

Implementation may return one total fee, but the conceptual split matters:

```text
totalFee = baseFee + repricingFee
```

This allows the protocol and LPs to reason clearly.

---

# 20. Core examples

## Example A: deep stable pair

```text
Pair: USDC/USDT
Base fee: 0.01%
Swap moves price: 0.02%
repricingRebateBps: 1000 // 10%
Repricing fee: 0.002%
Total fee: 0.012%
```

Result:

```text
deep stable pools remain cheap
```

## Example B: ETH/USDC

```text
Pair: ETH/USDC
Base fee: 0.05%
Swap moves price: 0.50%
repricingRebateBps: 5000 // 50%
Repricing fee: 0.25%
Total fee: 0.30%
```

Result:

```text
large/repricing trades pay meaningful LP compensation
```

## Example C: SHIB/USDC

```text
Pair: SHIB/USDC
Base fee: 0.30%
Swap moves price: 4.00%
repricingRebateBps: 5000 // 50%
Repricing fee: 2.00%
Total fee: 2.30%
```

Result:

```text
fragile speculative liquidity charges a fragile-liquidity price
```

This is intuitive. Users trading meme assets already tolerate larger spreads/slippage than stablecoin traders.

---

# 21. Strategic thesis

The mechanism is common sense:

```text
deep liquidity barely moves → low extra fee
thin/volatile liquidity moves a lot → high extra fee
```

So SafeSwap does not need to classify tokens.

It does not need to say:

```text
SHIB is risky
USDC is safe
```

It simply charges based on observed pool displacement.

That is neutral and permissionless.

---

# 22. How this compares to Angstrom

## Angstrom

```text
uses sequencing / auctions / batch logic
searchers compete for repricing rights
auction discovers value
LPs receive part of MEV
```

Pros:

```text
better price discovery
direct MEV/LVR internalization
```

Cons:

```text
more trust assumptions
off-chain sequencing/validators
liveness/censorship questions
greater complexity
```

## SafeSwap repricing rebate

```text
uses deterministic hook fee
no external price
no sequencer
no auction
charges posted toll per unit of pool movement
```

Pros:

```text
simpler
trustless
oracle-free
robust to splitting if linear
easy to reason about
```

Cons:

```text
does not discover exact MEV value
may undercharge/overcharge relative to true LVR
needs parameter tuning
```

The clean positioning:

> **Angstrom auctions the right to reprice. SafeSwap posts a deterministic toll for repricing.**

---

# 23. What this does not claim

Avoid overclaiming.

Do not claim:

```text
SafeSwap fully solves LVR
SafeSwap detects toxic trades
SafeSwap knows fair price
SafeSwap guarantees LP profit
SafeSwap captures exact arbitrage surplus
```

Correct claims:

```text
SafeSwap charges for pool price displacement.
SafeSwap rebates LPs when traders reprice the pool.
SafeSwap is oracle-free.
SafeSwap makes bots pay LPs when they move the pool toward a focal price.
SafeSwap reduces uncompensated repricing leakage.
```

---

# 24. Pros

## 1. Oracle-free

No fair price needed.

Works for:

```text
blue chips
long-tail assets
meme tokens
new launches
thin markets
```

## 2. Trustless and deterministic

No sequencer.

No validator set.

No off-chain auction.

No external feed.

## 3. Robust to splitting if linear

A linear fee charges roughly the same total over multiple smaller moves as over one large move.

## 4. Adapts to liquidity depth

Large notional in deep pool:

```text
small tick movement → small repricing fee
```

Small notional in thin pool:

```text
large tick movement → large repricing fee
```

## 5. LP-aligned

Repricing fee goes to LPs.

This directly improves the LP value proposition.

## 6. Easy to explain

> **Every tick moved pays LPs.**

## 7. Permissionless fee discovery

Different pools can choose different `repricingRebateBps`.

LPs and routers find the equilibrium.

---

# 25. Cons / risks

## 1. It charges all price-moving flow

It cannot distinguish:

```text
toxic arb
honest large demand
portfolio rebalance
```

But this is acceptable because all price-moving flow consumes inventory.

Better framing:

> It charges for movement, not intent.

## 2. May reduce routing volume

If total fee is too high, routers may avoid the pool.

This is why `repricingRebateBps` must be market-discovered and discrete.

## 3. May slow price correction

If fee captures too much, arbitrage may stop early.

The pool could remain stale longer.

This is parameter-sensitive.

## 4. Does not know fair price

It cannot tell whether movement is toward fair value or away from fair value.

It only prices movement.

## 5. Linear may undercharge extreme moves

Linear is robust, but maybe soft for violent repricing.

Convex can be explored later with cumulative movement tracking.

## 6. Implementation circularity

Fee depends on movement; movement depends on fee.

Need deterministic approximation or bounded solving.

## 7. Router integration

Aggregators need to understand/quote the dynamic fee accurately.

If not, users may see failed trades or unexpected output.

---

# 26. Suggested v1 scope

Keep v1 brutally simple.

## Include

```text
SafeSwapParams with repricingRebateBps
discrete rebate profiles
immutable hook instance per rebate profile
linear tick-movement fee
base fee + repricing fee
fee capped by maxFee
repricing fee goes to LPs
exact-input support
quote helper
```

## Exclude for v1

```text
external price oracle
auction
batching
convex fee curves
per-pool mutable config
complex BondRoute logic changes
slashing based on LVR
cumulative movement windows
ML/volatility models
```

This is a clean shipping target.

---

# 27. Suggested contract components

## SafeSwapFactory

Responsibilities:

```text
deploy/resolve hook for rebate profile
initialize SafeSwap pool
validate discrete repricingRebateBps
construct PoolKey
expose pool discovery helpers
```

Possible interface:

```solidity
struct SafeSwapPoolParams {
    Currency currency0;
    Currency currency1;
    uint24 baseFee;
    int24 tickSpacing;
    uint16 repricingRebateBps;
}

function createSafeSwapPool(
    SafeSwapPoolParams calldata params,
    uint160 sqrtPriceX96
) external returns (PoolKey memory key, PoolId poolId);
```

## SafeSwapHook

Immutable:

```solidity
uint16 public immutable repricingRebateBps;
uint24 public immutable maxFee;
```

Callback:

```text
beforeSwap
```

Responsibilities:

```text
estimate tick movement
compute repricing fee
return/apply dynamic fee
ensure BondRoute-only path if current architecture requires it
```

## SafeSwapQuoter

Needed for UX/routers.

Responsibilities:

```text
quote expected tick movement
quote repricing fee
quote total fee
quote output amount
```

This is important. If routers cannot quote it, they will avoid it.

---

# 28. Pseudocode

High-level only.

```solidity
function computeFee(
    int24 tickBefore,
    int24 estimatedTickAfter,
    uint24 baseFee
) internal view returns (uint24 totalFee) {
    uint256 tickDelta = absTickDelta(tickBefore, estimatedTickAfter);

    uint256 movementBps = tickDeltaToBps(tickDelta);

    uint256 repricingFeeBps =
        movementBps * repricingRebateBps / 10_000;

    uint256 feeBps = baseFeeBps(baseFee) + repricingFeeBps;

    feeBps = min(feeBps, maxFeeBps);

    return toV4FeeUnits(feeBps);
}
```

Conceptual conversion:

```text
tickDelta ≈ movementBps
```

Need precise handling depending on desired accuracy and Uniswap fee units.

---

# 29. Tick movement calculation

Preferred:

```text
tickDelta = abs(tickAfter - tickBefore)
```

Approx:

```text
movementBps ≈ tickDelta
```

Because 1 tick ≈ 1 bps.

Precise:

```text
movement = 1.0001^tickDelta - 1
movementBps = movement × 10_000
```

For most expected movement ranges, approximation may be enough, but senior dev should decide based on precision/gas tradeoff.

---

# 30. Fee cap

Always cap.

Example:

```text
maxFee = 5%
```

or profile-specific:

```text
stable: 0.50%
blue-chip: 2%
long-tail: 5%–10%
```

Unbounded fees create bad UX and edge-case risk.

Config could be tied to hook profile.

Example hook profiles:

```text
SafeSwap 10, max 1%
SafeSwap 25, max 2%
SafeSwap 50, max 5%
SafeSwap 75, max 7.5%
SafeSwap 100, max 10%
```

Keep simple initially.

---

# 31. Interaction with base fee

Uniswap v4 supports dynamic fees, but design needs to decide how base fee is represented.

Possible model:

```text
baseFee is the normal pool fee
repricing fee is hook-added dynamic component
total fee returned by hook
```

If using v4 dynamic fees, pool must be initialized accordingly.

The hook should never allow:

```text
totalFee < baseFee
```

The movement fee only adds.

---

# 32. Router / quoting implications

Routers need a deterministic quote.

They must know:

```text
current tick
current liquidity distribution
amount in/out
base fee
repricingRebateBps
estimated total fee
```

If quoting is hard, adoption suffers.

Provide an official quoter/helper.

Essential user-facing quote fields:

```text
base fee
estimated repricing rebate
total fee
expected price movement
expected output
```

This is also great for UX because users can see:

> “This swap moves the pool 3.2%; LP repricing rebate: 1.6%.”

That is educational and defensible.

---

# 33. UX copy

For LPs:

> “Earn extra fees when swaps move the pool price.”

For traders:

> “This pool charges a repricing rebate when your swap moves the price. The rebate compensates LPs for repricing risk.”

For advanced UI:

```text
Base fee: 0.30%
Pool movement: 2.00%
LP repricing rebate: 1.00%
Total fee: 1.30%
```

For pool creation:

```text
Repricing rebate:
  0%     Normal AMM behavior
  10%    Light LP protection
  25%    Moderate LP protection
  50%    Strong LP protection
  75%    Very strong LP protection
  100%   Maximum LP repricing capture
```

---

# 34. Nash / market-discovery story

This is important.

SafeSwap is not deciding the “correct” fee.

It provides competing pool profiles.

If rebate too low:

```text
LPs are undercompensated
liquidity migrates away
```

If rebate too high:

```text
traders/arbs route away
volume falls
```

Equilibrium:

```text
LP compensation high enough
trader execution still competitive
pool remains liquid
```

This is the core economic narrative.

> **SafeSwap lets the market price LVR protection.**

---

# 35. Main attack vectors and responses

## Attack: “This is just higher fees.”

Response:

> Yes, intentionally. But the fee is not flat. It is proportional to pool repricing. Deep liquid trades pay little extra; fragile repricing pays more.

## Attack: “This duplicates price impact.”

Response:

> Price impact determines the trader’s execution path. The repricing rebate compensates LPs for inventory/repricing risk. They are related but not identical.

## Attack: “It punishes honest large traders.”

Response:

> It charges price-moving traders, not large traders. A large trade in deep liquidity pays little. A trade that moves the pool pays because it consumes repricing capacity.

## Attack: “It does not know fair price.”

Response:

> Correct. It is oracle-free. It prices displacement, not truth. Bots reveal the focal price by moving the pool and pay LPs for the movement.

## Attack: “It can slow arbitrage.”

Response:

> Yes, if configured too aggressively. That is why rebate profiles are permissionless and market-discovered.

## Attack: “Why would routers use this?”

Response:

> They will use it when net execution is competitive. Deep SafeSwap pools may remain cheap. For fragile pools, the higher fee is the honest price of liquidity.

---

# 36. Metrics to measure after deployment

Do not only measure volume.

Measure:

```text
gross volume
base fees earned
repricing rebates earned
average tick movement per swap
LP net returns versus comparable non-SafeSwap pools
liquidity migration between rebate profiles
router share
arb frequency
time-to-reprice after large movement
failed swap rate
average total fee paid by pair class
```

Most important:

```text
LP fees + repricing rebates
versus
LP outcome if simply held assets
```

But that is harder.

At minimum, report:

```text
repricing rebate revenue as % of total LP revenue
```

That proves whether the mechanism matters.

---

# 37. Recommended MVP

## MVP goal

Prove that SafeSwap can charge an oracle-free LP repricing rebate based on tick movement.

## MVP features

```text
1. SafeSwap pool creation wrapper
2. discrete repricingRebateBps profiles
3. hook instance per profile
4. linear tick-movement fee
5. exact-input support
6. fee cap
7. official quote helper
8. analytics events
```

## Events

Emit events that make analytics easy:

```solidity
event RepricingRebateCharged(
    PoolId indexed poolId,
    address indexed sender,
    int24 tickBefore,
    int24 tickAfter,
    uint256 tickDelta,
    uint256 movementBps,
    uint16 repricingRebateBps,
    uint256 repricingFeeAmount0,
    uint256 repricingFeeAmount1
);
```

The exact fields depend on v4 accounting, but analytics must be first-class.

---

# 38. Open implementation questions for senior dev

These are the points to resolve before coding.

## 1. Exact fee unit compatibility

Uniswap v4 dynamic fee units and max fee constraints must be mapped precisely.

Need define:

```text
baseFee representation
repricingFee representation
totalFee return path
```

## 2. Post-swap tick estimation

How does the hook estimate `tickAfter` in `beforeSwap`?

Options:

```text
simulate with base fee
use swap math libraries
quote helper path
conservative approximation
```

This is the hardest technical detail.

## 3. Exact-output support

Support now or defer?

If support now, define deterministic solving.

## 4. Fee accrual mechanics

Does the extra dynamic fee naturally accrue to LPs through Uniswap v4 fee accounting?

Or does hook need custom accounting / donation / settlement?

This must be verified against v4 hook mechanics.

## 5. BondRoute wrapping

Current SafeSwap requires BondRoute wrapping.

For this playbook, do not change BondRoute.

But senior dev must ensure the repricing fee logic composes with the existing “only wrapped actions allowed” gate.

## 6. Discrete profile registry

Where are allowed profiles stored?

Options:

```text
hardcoded constants
factory registry
governance-updatable registry
permissionless but UI-recognized profiles
```

Recommended v1:

```text
hardcoded small set
```

## 7. Hook address derivation

Factory should resolve/deploy deterministic hook address for each profile.

Need account for v4 hook permission bits/address mining.

---

# 39. Recommended v1 architecture

```text
SafeSwapFactory
  - validates SafeSwapPoolParams
  - resolves hook for repricingRebateBps
  - initializes v4 pool
  - exposes pool key helpers

SafeSwapHookProfile
  - immutable repricingRebateBps
  - immutable maxFee
  - beforeSwap:
      enforce SafeSwap/BondRoute gate
      estimate tick movement
      compute total dynamic fee
      apply/return fee
  - emit analytics

SafeSwapQuoter
  - quotes swaps with estimated repricing fee
  - returns movement + fee breakdown
```

---

# 40. Final product positioning

SafeSwap should be described as:

> **A Uniswap v4 pool-action firewall with oracle-free LP repricing rebates.**

Or more simply:

> **SafeSwap rebates LPs when traders move the pool price.**

Core line:

> **Every tick moved pays LPs.**

Longer version:

> **SafeSwap does not need to know the external fair price. When bots or users move a pool toward a focal price, the pool charges a configurable share of that price displacement and rebates it to LPs. Deep liquid markets stay cheap; fragile markets charge more.**

---

# 41. Final recommendation

Build the v1 around this exact mechanism:

```text
totalFee = baseFee + repricingFee

repricingFee = observed/estimated pool price movement × repricingRebateBps
```

Use:

```text
tick movement
linear pricing
discrete rebate profiles
immutable hook instances
LP-directed fee accrual
official quoting
analytics events
```

Do **not** add oracles, auctions, convex curves, or complex BondRoute changes yet.

The sharp thesis:

> **SafeSwap turns pool repricing from arbitrageur extraction into LP revenue, without needing an oracle or trusted sequencer.**

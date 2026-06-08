# SafeSwap Dynamic-Fee LP Repricing Rebate — Implementation Plan

> Binding spec for the mechanism. Companions: **`LVR_DETERRENCE.md`** (why / economics) and
> **`REPRICING_REBATE_ADDRESS_CONFIG.md`** (topology, hook-address encoding, registry). This is a new system — no backwards
> compatibility required.

## Context: the pivot, and the calibration fix

The first cut measured a swap's real tick movement after the fact and `donate`d to LPs. `donate` only credits LPs in range at
the post-swap tick, missing the crossed-and-exited LPs — exactly the repriced ones. So we pivoted to a native V4 **dynamic LP
fee** (design A): the hook simulates the swap in `beforeSwap` and returns `base fee + repricing fee` as an override, which
accrues **path-fairly** to every range the swap crosses.

A second, independent correction: the repricing fee must be a share of the **surplus** the swap extracts, not a fee *rate*
proportional to price displacement. Charging `capture% × movement` as a rate over-captures by ~2× (a flat rate hits the whole
input; the surplus is only the price-impact triangle ≈ ½·movement·input), so a "50%" dial would take ~100% of the surplus and
"90%" would make repricing unprofitable — defeating the freshness incentive the 90% ceiling exists to protect. See
`LVR_DETERRENCE.md` §4. **`capture%` is the share of estimated surplus paid to LPs.**

## Decisions (confirmed)

1. **Design A — the hook prices the swap.** `beforeSwap` runs `SwapSimulator`, computes the repricing fee from the estimated
   **surplus**, returns the V4 override fee. Trustless: depends only on pool state + the hook code.
2. **Pools are `DYNAMIC_FEE_FLAG`.** Base fee lives in the hook address, not `PoolKey.fee`.
3. **Hook address is BCD `0xF d d d 0xC r 0`** (3 base-fee digits → `base_fee_bps` 0..999; 2 readable capture digits,
   with the ones digit forced to zero → `capture_percent = 10·r`, 0..90) + 14 permission bits. See the architecture doc.
   `REQUIRED_PERMISSIONS = 0x2A80`
   (no `beforeDonate`).
4. **Capture is a share of surplus, delivered as a native dynamic LP fee.** No measure-and-donate; the fee accrues per swap
   step. The **90% ceiling** guarantees arbitrageurs keep ≥10% of the surplus.
5. **Splitting:** no formula-level claim. BondRoute (per-swap stake + commit-reveal + delay) is the deterrent; no cumulative
   tracking in v1 (immutable simplicity). See `LVR_DETERRENCE.md` §5.
6. **Quoting:** SafeSwap exposes `__OFF_CHAIN__quote_swap` running the **same** `SwapSimulator` + fee formula, so quote and
   execution agree by construction. `BondRoute_quote_call` (stake / fundings / timing) is unchanged in spirit.

## Mechanism

```
beforeSwap(sender, key, params, hookData):
    require sender == ROUTER
    base_fee_pips = base_fee_bps * 100

    (tick_before, tick_after, sqrt_after, counterpart) = SwapSimulator.simulate(
        manager, key, params.zeroForOne, params.amountSpecified, base_fee_pips)

    # Resolve the two legs from the V4 amount convention:
    #   exact-input  (amountSpecified < 0): amount_in = |amountSpecified|, amount_out = counterpart
    #   exact-output (amountSpecified > 0): amount_out =  amountSpecified , amount_in  = counterpart
    (amount_in, amount_out) = legs(params.amountSpecified, counterpart)

    # surplus = output valued at the post-swap (terminal) price, minus input paid, in INPUT-token units (≥ 0).
    #   zeroForOne (in=token0, out=token1): surplus = amount_out / price_after − amount_in
    #   oneForZero (in=token1, out=token0): surplus = amount_out * price_after − amount_in
    #   where price_after = (sqrt_after / 2^96)^2  (token1 per token0); use FullMath, no /2 approximation.
    surplus = max(0, value_at(amount_out, sqrt_after, params.zeroForOne) − amount_in)

    # Express the captured surplus as the single flat V4 fee rate the swap needs:
    #   repricing_pips = capture% · (surplus / amount_in) · 1e6  =  surplus · capture_percent · 10_000 / amount_in
    repricing_pips = surplus * capture_percent * 10_000 / amount_in
    swap_fee_pips  = base_fee_pips + repricing_pips
    require( swap_fee_pips < 1_000_000 )

    return ( selector, ZERO_DELTA, OVERRIDE_FEE_FLAG | swap_fee_pips )
```

- The fee is **direction-neutral**: a move up and the same move down charge the same share of surplus (the only difference is
  multiply-vs-divide by `price_after` when valuing the output).
- Simulating with the base fee is a deliberate second-order approximation (the fee-vs-movement feedback is small); the swap
  then reads the same warmed slots. Quote uses the identical path.
- Zero movement, zero liquidity, or non-positive surplus → `repricing_pips = 0` → just the base fee.
- `swap_fee_pips >= SwapMath.MAX_SWAP_FEE` (1e6) reverts instead of silently under-capturing LPs.

## Work breakdown (deltas from the current displacement-rate code)

### `contracts/Common/SwapSimulator.sol`
- **Already returns** `tick_before, tick_after, sqrt_price_after_x96, amount_calculated` — enough for surplus: terminal price
  from `sqrt_price_after_x96`, and the two legs from `amount_specified` + `amount_calculated`. No new return values needed.
- Add a focused test suite (`test/Common/SwapSimulator.t.sol`, **currently missing**): exact-in/out, single-range and
  multi-range crossings, both directions, zero-liquidity, and that simulated `(tick, amounts, sqrt)` match a real swap.

### `contracts/Common/SafeSwapCommon.sol`
- Replace `compute_repricing_fee_pips(tick_before, tick_after, rebate_percent, base_fee_pips)` with the **surplus** version:
  `compute_repricing_fee_pips(amount_in, amount_out, sqrt_price_after_x96, zero_for_one, capture_percent, base_fee_pips) →
  uint24 swap_fee_pips`. Use `FullMath.mulDiv` for `value_at(...)` and the pip conversion; clamp surplus at 0; revert when
  the configured capture would require a 100%+ V4 fee.
- `base_fee_units` stays.

### `contracts/Common/Definitions.sol`
- Remove the old displacement-derived fee-rate caps. Keep `PIPS_PER_BPS`, `PERCENT_DENOMINATOR`, and `BPS_DENOMINATOR`.
  Rewrite the "LP REPRICING REBATE" comment block to the surplus framing.

### `contracts/Hook/SafeSwapHookImpl.sol`
- `beforeSwap`: call `simulate`, derive legs, call the new `compute_repricing_fee_pips`, return the override. Update the
  docstring from "movement" to "surplus". Gating unchanged.

### `contracts/Router/{SafeSwapRouter (User),Nft}` + libraries
- `__OFF_CHAIN__quote_swap(token_in, token_out, base_fee_bps, capture_percent, tick_spacing, zero_for_one, amount)` →
  `{ expected_surplus, base_fee_pips, repricing_pips, total_fee_pips, expected_net_output }` via the same `SwapSimulator` +
  formula. Keep `__OFF_CHAIN__get_pool_id`.
- Swap libs: build `PoolKey.fee = DYNAMIC_FEE_FLAG`; pool charges `base + repricing` via the override; protocol fee taken from
  output as today using `base_fee_units(base_fee_bps)`.

### Docs
- The three `.md` design docs now carry the surplus framing (this change). Keep code comments in lockstep when editing the
  files above.

## Testing

- **Unit (the headline calibration test):** for a seeded real pool, assert the repricing fee ≈ `capture% × surplus` — e.g.
  C50 leaves ~half the surplus to the trader (the old displacement-rate code took ~all of it). Include `capture% = 0` and `90`.
- **Symmetry:** an up-move and the equal down-move charge the same share of surplus (`zeroForOne` vs `oneForZero`).
- **Splitting (documents behavior, not a guarantee):** one big move vs N small moves — the summed captured fee is *less* for
  the split path; assert the direction and document it (the formula is not splitting-proof; BondRoute is the deterrent).
- **Path-fairness:** a swap crossing range A (exited) and B (final) raises `feeGrowthInside` for **both** — the reason for the
  dynamic-fee pivot.
- **Quoter:** `__OFF_CHAIN__quote_swap` fee == executed fee; net output matches.
- **Registry:** `(base_fee_bps, capture_percent)` keying; codehash / address-config / permission / duplicate rejections.
- **Accounting:** `pool_output == user_output + protocol_fee` (repricing is inside the pool's LP fee).
- **Simulator suite** (above) and **migrate the legacy suite** to this topology.

## Verification

1. `forge build` clean; router under EIP-170; confirm hook clone size.
2. `forge test` — unit + simulator + hook + path-fairness + quoter green.
3. Real-pool gas check: per-swap overhead ≈ ~9k + ~4k per initialized tick crossed (as benchmarked).
4. Calibration + symmetry tests green (the reason for the surplus fix).

## Open items

- **Resolved:** no low SafeSwap-specific repricing cap; revert at the V4 100% fee boundary.
- **Resolved:** use two-pass quote simulation for exact input and exact output.
- **`SafeSwapHookProxy`**: the EIP-1167 stub contract + deploy script + published codehash are not built yet (tests synthesize
  the clone via `vm.etch`).
- Keep the donate branch as a fallback only until path-fairness + calibration are confirmed end-to-end.

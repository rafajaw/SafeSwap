# SafeSwap Dynamic-Fee LP Repricing Rebate — Implementation Plan

## Context

The first cut of the repricing rebate (`feat/repricing-rebate`) measured a swap's **real** tick movement after the fact
and `donate`d the rebate to LPs. That is exact in magnitude and cheap, but `donate` credits only the LPs **in range at the
post-swap tick** — it systematically **fails to compensate the LPs whose ranges the swap crossed and exited**, which are
exactly the LPs that got repriced. We benchmarked the alternative and decided the trade is worth it:

- A native v4 **dynamic LP fee** accrues **per swap step to each crossed range**, so it compensates LPs **proportional to the
  volume they served** — path-fair, the property `donate` lacks.
- Its only real cost is that the fee must be set in `beforeSwap` **before** the realized movement is known, so the hook must
  **simulate** the swap to estimate the post-swap tick. `SwapSimulator` (already built and benchmarked) does this for a
  measured **~9,000 gas fixed + ~4,000 per initialized tick crossed** — cents on L1, dust on L2. Acceptable for correctly
  paying the wrecked LP.

This plan pivots SafeSwap from *measure-and-donate* to **dynamic-fee (design A)**: the **hook itself** runs `SwapSimulator`
in `beforeSwap` and returns `OVERRIDE_FEE = baseFee + repricingFee`. It builds on `bench/dynamic-fee-simulator` (router +
config-hook registry + `SwapSimulator`).

This is a new system — no backwards compatibility required.

## Decisions (confirmed)

1. **Design A — the hook prices the swap.** `beforeSwap` runs `SwapSimulator`, computes `repricingFee` from the estimated
   movement, and returns the v4 override fee. **Trustless**: LP compensation depends only on pool state + the audited hook
   code, never on a router-supplied number.
2. **Pools are `DYNAMIC_FEE_FLAG`.** The base fee no longer lives in `PoolKey.fee`; it moves into the hook config.
3. **Hook address is BCD with mnemonic markers: `0xF` (Fee), 3 base-fee digits, `0xC` (Capture), 1 rebate digit.**
   (`0x55` dropped — the hook isn't user-facing. `F` = "Fee" marks the base LP fee; `C` = "Capture" marks the share of
   displacement the pool captures for LPs. With `C` owning the capture dimension there's no fee ambiguity. Both `0xF` and
   `0xC` are >9, so neither marker can be confused with a `0..9` data digit and the config self-parses.)
   - `0xF 030 C 5` → base **0.30%**, capture/rebate **50%**
   - `0xF 150 C 9` → base **1.50%**, capture/rebate **90%**
   - `0xF 001 C 1` → base **0.01%**, capture/rebate **10%**

   Top 24 bits `[F][d2][d1][d0][C][r]` (`bits 136..159`) · free salt bits · low 14 bits = v4 permission bitmap. Decode:
   assert `digit0 == 0xF` and `digit4 == 0xC`, and `d2,d1,d0,r <= 9`; then `base_fee_bps = 100*d2 + 10*d1 + d0`
   (0..999 → **0.00%..9.99%**), `rebate_percent = 10*r` (0..90 → `rebate_bps = rebate_percent * 100`). 38 mined bits
   (24 config + 14 perms), GPU vanity-mine (~minutes), one-time per config.

   - The **90% rebate ceiling is economically intended**: leaving >=10% of the displacement to arbitrageurs preserves their
     incentive to keep the pool price fresh (a 100% rebate would halt price correction). 10% steps also block odd/predatory
     rebate values.
4. **No base-fee allowlist — base fee is open (any whole bps <= 9.99%).** Fragmentation is rate-limited by *real friction*,
   not a governance tier list: every `(fee, rebate)` hook must be GPU-mined, deployed, registered, and seeded by a first LP.
   That cost stops 999-way splitting and doubles as a competitiveness escape hatch (an LP on a dead 0.30% pool can stand up
   0.25% to pull flow) — mirroring v4's permissionless-fee philosophy. The rebate axis stays discrete for free (1 nibble = 10% steps).
4. **Rebate = native LP fee, not a donation.** The swap libs drop measure-and-donate; the rebate is delivered entirely by
   the `beforeSwap` fee override and accrues path-fairly through v4's per-step fee accounting.
5. **Quoting:** the standard V4Quoter cannot quote SafeSwap pools (hook rejects `sender != ROUTER`), so SafeSwap exposes its
   own `__OFF_CHAIN__quote_swap` that runs the **same** `SwapSimulator` → quote and execution agree by construction.
6. **`BondRoute_quote_call` is unchanged in spirit** — stake (% of input), fundings, timing; no simulator. Fee/output
   preview is the separate `__OFF_CHAIN__quote_swap`.

## Topology (decided: Option B — split) — supersedes any single-router wording below

Two BondRoute-protected contracts, because V4 position ownership = the `modifyLiquidity` caller, so the whole position
lifecycle must live in one contract:

- **SwapRouter** (`BondRouteProtected` #1): `swap_exact_input`, `swap_exact_output`, `register_hook`/`get_hook`, treasury,
  `__OFF_CHAIN__quote_swap`/`get_pool_id`. Owns no positions. The dynamic-fee quoter (`SwapSimulator`) fits here because
  the position lifecycle is no longer in this contract.
- **PositionManagerNFT** (`BondRouteProtected` #2): `create_position`, `add_liquidity`, `remove_liquidity`, `collect_fees`,
  ERC721, position getters. **Owns the V4 positions** (it is the `modifyLiquidity` caller; salt = tokenId) and has its own
  unlock-callback + settlement (sharing the action libraries). Resolves the hook via `router.get_hook(...)`.

**`donate` is removed** (not relabeled): the rebate is a native dynamic fee, so a bonded donate is gone, and the hook drops
the `beforeDonate` permission (`REQUIRED_PERMISSIONS = 0x2A80`). Pools still accept *permissionless* `PoolManager.donate`
(a harmless v4 primitive crediting in-range LPs), so external incentives can still tip LPs — SafeSwap just doesn't mediate it.

**Hook gating:** `beforeSwap` ⇒ `sender == ROUTER`; `beforeInitialize`/`beforeAddLiquidity`/`beforeRemoveLiquidity` ⇒
`sender == NFT`. The hook reads both `ROUTER` and `NFT` from ChainConfig. `DonateLib` is deleted.

## Mechanism

```
beforeSwap(sender, key, params, hookData):
    require sender == ROUTER
    base_fee_pips = base_fee_bps * 100
    (tick_before, tick_after, ) = SwapSimulator.simulate(manager, key, params.zeroForOne, params.amountSpecified, base_fee_pips)
    movement_bps   = abs(tick_after - tick_before)                 // 1 tick ≈ 1 bps (linear v1)
    repricing_bps  = min( movement_bps * rebate_bps / 10_000, MAX_REPRICING_REBATE_BPS )
    swap_fee_pips  = min( base_fee_pips + repricing_bps * 100, MAX_TOTAL_FEE_PIPS )
    return ( selector, ZERO_DELTA, OVERRIDE_FEE_FLAG | swap_fee_pips )
```

- `base_fee_pips = base_fee_bps * 100`; `rebate_bps = rebate_percent * 100` (both decoded straight from the hook address).
- v4 then charges `swap_fee_pips` on every swap step, accruing to each crossed range's liquidity → path-fair.
- `MAX_TOTAL_FEE_PIPS` < `SwapMath.MAX_SWAP_FEE` so exact-output swaps remain feasible.
- The sim runs *before* the swap math and reads the same slots → it warms them; the swap then reads warm (cost analysis holds).
- Zero movement or zero liquidity → `repricing_bps = 0` → just the base fee. No donate edge cases anymore.

## Work breakdown (deltas from the current donate implementation)

### `contracts/Router/Definitions.sol`
- **BCD hook-address decode** helper: assert `digit0 (bits 156..159) == 0xF` and `digit4 (bits 140..143) == 0xC`; read the
  base digits `d2 d1 d0` (bits 144..155) and rebate digit `r` (bits 136..139), each `<= 9`; return
  `base_fee_bps = 100*d2 + 10*d1 + d0` (`uint16`, 0..999) and `rebate_percent = 10*r` (0..90). Keep
  `REQUIRED_HOOK_PERMISSIONS` (low 14 bits). New constants: `FEE_MARKER = 0xF`, `CAPTURE_MARKER = 0xC`, `MAX_DECIMAL_DIGIT = 9`,
  and the nibble shifts.
- Replace the `rebate_profile` / `REBATE_PROFILE_BPS_STEP` / `MAX_REBATE_PROFILE` constants with the BCD-derived
  `rebate_percent` (`rebate_bps = rebate_percent * 100`).
- Add `MAX_TOTAL_FEE_PIPS` (fee cap in v4 pips). Keep `MAX_REPRICING_REBATE_BPS`, `BPS_DENOMINATOR`.

### `contracts/Router/libraries/SwapSimulator.sol` (already present)
- Extend `simulate(...)` to also return the **gross output (or required input)** amount (accumulate the per-step amounts it
  already computes) so the quoter can return net output in one place. Keep the assembly `extsload` / scratch-only design.

### `contracts/Router/libraries/SafeSwapCommon.sol`
- Replace the rebate-amount + `donate_rebate` helpers with `compute_repricing_fee_pips(tick_before, tick_after, rebate_percent, base_fee_pips) → uint24 swap_fee_pips` (movement → capped total fee in pips).
- `base_fee_units` stays. Drop the `RepricingRebateCharged`-as-amount event (or repurpose to log movement/fee at execution).

### `contracts/Hook/` — single implementation + cheap clones
**`SafeSwapHookImpl.sol`** (deployed once, audited, immutable):
- Holds `PoolManager` / `ROUTER` as immutables (read fine under delegatecall — immutables live in the impl's code).
- Decodes `base_fee_bps` + `rebate_percent` from **`address(this)`** (the proxy's mined address) on each call — config is
  address-derived, **no storage, no constructor decode, no `initialize_once`-for-storage**. Exposes public getters.
- `beforeSwap`: `sender == ROUTER` gate, run the mechanism (`SwapSimulator` inlined), return the override fee. Other v4
  callbacks: unchanged gating. `initialize_once()` calls `ROUTER.register_hook()` (msg.sender = the proxy).
- *SECURITY* guards: revert if `address(this) == IMPL_SELF` (direct calls to the impl have no valid F/C config); impl is
  non-upgradeable / non-`selfdestruct` so the proxies' hardcoded target is permanent.

**`SafeSwapHookProxy`** (the tiny stub, deployed permissionlessly per config):
- An EIP-1167-style minimal proxy that `delegatecall`s the fixed `SafeSwapHookImpl`. ~45 bytes → cheap to deploy. Its
  CREATE2 address is mined to carry the `F d d d C r` config + v4 perm bits; that address *is* the pool's hook.
- All proxies share one runtime codehash (the impl address is baked into the stub), which is what the registry approves.

### `contracts/Router/HookRegistry.sol`
- Registry keyed by the decoded config packed as `(base_fee_bps << 4) | rebate_digit` (`uint16`); `get_hook(base_fee_bps,
  rebate_percent)` resolves it. BCD decode + validation (F/C markers + every digit `<= 9`) runs at registration.
- **Codehash allowlist targets the proxy-stub codehash** (uniform across all clones, with the audited impl address baked
  in) — so an approved codehash provably means "delegatecalls the audited `SafeSwapHookImpl`." `register_hook` checks
  `extcodehash(msg.sender) == approved_stub_codehash` + address bits + perms.

### `contracts/Router/libraries/{ExactInputSwapLib,ExactOutputSwapLib}.sol`
- **Drop the measure-and-donate path.** Build `PoolKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG`. Execute the swap (the pool now
  takes `base + repricing` as the LP fee via the override), then take the **protocol fee** from output as today and settle
  the user's net. Protocol-fee math uses `base_fee_units(base_fee_bps)` from config (not `PoolKey.fee`, which is the flag).
- `get_constraints` unchanged (stake/funding/timing + `rebate_percent` range check).

### `contracts/Router/libraries/{ModifyLiquidityLib,DonateLib}.sol`
- `PoolKey.fee = DYNAMIC_FEE_FLAG` everywhere a SafeSwap pool key is built (positions/donate are on the same dynamic-fee pool).
- No rebate logic (unchanged otherwise).

### `contracts/Router/Orchestrator.sol` / `User.sol`
- Pool init uses `DYNAMIC_FEE_FLAG`. User-facing params carry `base_fee_bps + rebate_percent + tick_spacing`; router
  resolves the hook from `(base_fee_bps, rebate_percent)`.
- NFT `SafeSwapPositionInfo` stores `base_fee_bps + rebate_percent + hook`; populate from the decoded address bytes.
- Add **`__OFF_CHAIN__quote_swap(token_in, token_out, base_fee_bps, rebate_percent, tick_spacing, zero_for_one, amount)`**
  → `{ expected_movement_bps, base_fee_bps, repricing_bps, total_fee_pips, expected_net_output }` using `SwapSimulator`
  (two-pass for output precision; one pass already gives the exact fee). Keep `__OFF_CHAIN__get_pool_id` (dynamic-fee key).

### `script/DeploySafeSwapHook.s.sol`
- One-time: deploy `SafeSwapHookImpl`; publish its proxy-stub codehash (stub = EIP-1167 with the impl address baked in) to
  ChainConfig as the approved hook codehash.
- Per config: build the stub initcode (fixed `keccak`), mine a CREATE2 salt whose proxy address carries the `F`/`C` markers
  + base/rebate digits + v4 perm bits, CREATE2-deploy the ~45-byte clone, then call `initialize_once()` to register it.

## Security model (unchanged + additions)
- Hook callbacks still gate `msg.sender == PoolManager && sender == ROUTER`.
- The fee is **deterministic from pool state + the proxy address's BCD config** — no external input, no router trust.
- **Proxy/impl integrity:** the approved codehash is the EIP-1167 stub's (impl address baked in), so a registered hook
  provably delegatecalls the audited `SafeSwapHookImpl`; the impl rejects direct (non-proxy) calls and is non-upgradeable.
- `SwapSimulator` is read-only (`extsload` staticcalls) and runs on pre-swap state inside `beforeSwap`.
- `*SECURITY*` note: the fee override is capped at `MAX_TOTAL_FEE_PIPS < MAX_SWAP_FEE` so exact-output never becomes infeasible.

## Testing
- **Unit:** `compute_repricing_fee_pips` (movement → pips, cap, rebate_percent 0, rebate_percent 100); base-fee + rebate byte decode.
- **Hook:** `beforeSwap` returns `base + repricing` override for a seeded real pool; `sender != ROUTER` reverts.
- **Real-pool path-fairness (the headline test):** swap that crosses ranges A (exited) and B (final), then assert
  `feeGrowthInside` rose for **both** A and B — proving the dynamic fee compensates the crossed-and-exited LP that `donate`
  left out. Contrast snapshot vs the donate branch.
- **Quoter:** `__OFF_CHAIN__quote_swap` fee == executed fee exactly; net output matches (2-pass).
- **Registry:** `(base_fee_bps, rebate_percent)` keying, duplicate/codehash/perms rejections.
- **Accounting:** `pool_output == user_output + protocol_fee` (rebate is inside the pool's LP fee, not a separate take).
- **Migrate the legacy suite** to the dynamic-fee topology (still outstanding from the prior branch).

## Verification
1. `forge build` clean; router under EIP-170 (hook carries `SwapSimulator` inlined — confirm hook size; it was 1,225 bytes).
2. `forge test` — unit + hook + real-pool + quoter green.
3. Real-pool gas check: confirm per-swap overhead ≈ ~9k + ~4k/initialized-tick as benchmarked.
4. Path-fairness test green (the reason for the pivot).

## Open items to confirm
- **Base fee** is capped at **9.99%** by the 3 BCD digits, and **rebate at 90%** by the 1 digit (both decided: readable
  addresses + the 90% economic ceiling). A higher base fee would need a 4th digit; not expected to be necessary.
- **`MAX_TOTAL_FEE_PIPS`** value (e.g. 50% = 500000 pips, must stay < `MAX_SWAP_FEE` = 1e6).
- **Quoter precision:** 2-pass (exact output) vs 1-pass (exact fee, ~2nd-order output error).
- Keep `feat/repricing-rebate` (donate) as the fallback branch until the path-fairness test confirms the pivot end-to-end.

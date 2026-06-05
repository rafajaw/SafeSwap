# SafeSwap Implementation TODO

## Design docs & mechanism
- [x] Rewrite the design docs to the surplus framing (capture% = share of repricing surplus, not a rate on displacement):
      `LVR_DETERRENCE.md`, `REPRICING_REBATE_ADDRESS_CONFIG.md`, `DYNAMIC_FEE_REBATE_PLAN.md` (binding), `CLAUDE.md`.
- [x] Fix the displacement-rate fee in code -> surplus-based: rewrote `SafeSwapCommon.compute_repricing_fee_pips`
      (`+ swap_legs`, FullMath surplus valuation), updated `SafeSwapHookImpl.beforeSwap` + both `User.sol` quoters, and
      rewrote the unit tests (capture% of surplus + symmetry + V4-limit guard).
- [x] Split exact-output max-input failures into `MaximumInputExceeded(required_input, maximum_required)`, keeping
      `SlippageExceeded(amount_received, minimum_required)` for minimum-output/minimum-received paths.
- [x] C0 fast path: `SafeSwapHookImpl.beforeSwap` skips the `SwapSimulator` walk entirely when `capture == 0` (guard
      returns the flat base-fee override). Doubles as the "BondRoute + base fee, no repricing" product tier.
- [x] Bench the simulation cost end-to-end (`test/Router/SwapHookOverheadBench.t.sol`): overhead ~ 9.4k fixed + ~4.1k per
      initialized tick crossed (~11% of a within-tick swap); full row contrast vanilla V4 / BondRoute+base / sim.
- [x] Prototype + bench the **optimistic** design (swapper supplies the repricing fee in `hookData`; `beforeSwap` trusts it,
      `afterSwap` reverts `UnderCaptured` on under-report) on research branch `optimistic-repricing-no-sim`.
      DECISION: **not canonical.** On-chain simulation wins for the immutable core - under BondRoute's commit->execute delay the
      claimed fee is bound at commit, so honest swappers must pad it to dodge drift reverts, and that pad is unrefundable
      over-capture (the LP fee already accrued; `afterSwap` can only revert, not claw back). Branch kept for reference only.

## Test suite
- [x] Move stale legacy tests out of Foundry's active `test/` tree without deleting them.
- [x] Add shared test helpers under `test/helpers`.
- [x] Implement `test/Common/HookAddress.t.sol`.
- [x] Implement `test/Common/SafeSwapCommon.t.sol`.
- [x] Implement `test/Common/PoolManagerIntegration.t.sol`.
- [x] Implement `test/Common/SwapSimulator.t.sol` (validates the library against real V4 swaps: exact-in/out, both directions, single/multi tick crossings, zero liquidity, extsload-failure bubbling; force-compiles V4's test routers via `ForceCompileV4.sol`).
- [x] Verify Common suite with `forge test --match-path 'test/Common/*.t.sol'` (HookAddress + SafeSwapCommon + PoolManagerIntegration + SwapSimulator).
- [x] Implement `test/Hook/SafeSwapHookImpl.t.sol`.
- [x] Build the shared real-environment harness (`test/helpers/SafeSwapRealEnv.t.sol`, `TestERC20.t.sol`,
      `ForceCompileV4.sol`): real V4 PoolManager + router + NFT + etched hook clone + real BondRoute. Reused by all suites.
- [x] Implement `test/Nft/SafeSwapNft.t.sol` (Tier 2 - focused/edge, mock PoolManager for injected deltas).
  - [x] Constructor, receive policy, create-position, create quote/signing slice.
  - [x] Add-liquidity authorization and execution.
  - [x] Remove-liquidity and collect-fees execution.
  - [x] Fix funding-source fidelity: real `TestERC20`, mint to bond owners, BondRoute mock pulls via `transferFrom`.
  - [x] Existing-position quotes and off-chain views.
- [x] Implement `test/Nft/SafeSwapNftWorkflow.t.sol` (Tier 1 - full workflow on real BondRoute + real V4; real
      balance/`StateLibrary` assertions, salt = tokenId, graceful PROTOCOL_REVERTED on unauthorized action).
- [x] Implement `test/Router/HookRegistry.t.sol` (codehash authorization, unset codehash, EIP-7702 designator rejection,
      BCD/config/permission validation, duplicate config handling, event emission, registered-hook lookup).
- [x] Implement `test/Router/SafeSwapRouter.t.sol` (constructor config reads/reverts, native receive policy, protocol-fee
      recipient, ERC20/native treasury withdrawals, one-wei retention, transfer failures, two-step treasury transfer).
- [x] Implement `test/Router/UserSwap.t.sol` (Tier 1 - full-workflow swaps: surplus fee applied live, quote == execution, protocol-fee accounting, graceful slippage revert, exact-output exactness).
- [x] Implement `test/Router/User.t.sol` (Tier 2 - exact-input/output edge behavior, quoter, pool id, and BondRoute integration per `IUserSwapTests`).
- [x] Implement `test/Router/PathFairness.t.sol` (real adjacent ranges: dynamic fee increases feeGrowthInside for crossed
      and final liquidity, fee growth follows served path length, both swap directions, raw V4 donate snapshot contrast).
- [x] Implement focused mocks under `test/mocks` only where real dependencies are impractical for the edge case.
- [x] Run each suite subset independently. Common (incl. SwapSimulator), Hook, Nft (both tiers), and Router
      HookRegistry / SafeSwapRouter / User Tier 2 / workflow suites (UserSwap + PathFairness) are green.
      NOTE: `forge test --match-path` cold-compiles sparsely and skips the string-referenced `ForceCompileV4.sol` (deployCode); run a full `forge test` or `forge build` first for suites that deploy real V4.
- [x] Run the full active test suite. (12 suites, 266 tests passed, 0 failed.)
- [x] Use archived legacy tests as a final coverage checklist. Cross-checked all 25 legacy files vs the four manifests:
      pre-rewrite suite is mostly obsolete (donate, transient protected-context, old memory-layout structs); remaining
      behaviors already covered. Found and filled one real gap - router `unlockCallback` caller guard
      (`test_unlock_callback_reverts_when_caller_is_not_pool_manager`). Deferred by choice: no fuzz/invariant layer (behaviors
      covered by concrete unit tests); protocol-fee floor exact-threshold boundary not separately pinned.
- [x] Cover `deploy_hook` + `get_hook_config` in the Hook manifest/suite: impl-call revert, canonical EIP-1167 runtime
      parity (the codehash gate), already-deployed collision, invalid-config decode revert, and clone->impl forwarding. The
      success / `CONFIG_MISMATCH` / `PERMISSIONS` paths need a mined valid address and are deferred to the deploy script.
- [x] Fix `SafeSwapRealEnv._create_and_execute_bond` multi-bond timing: the test frame reads `block.number` / `block.timestamp`
      stale after a deep BondRoute call, so drive vm.roll/vm.warp from absolute monotonic counters seeded once before any
      bond. Unblocks tests running >=2 bonds in a single test body (e.g. `test_protocol_fee_recipient_is_router`). Full suite
      now 279 passing.

## Pre-deploy (outstanding)

- [x] **Config-hook deployment** - solved by the self-replicating `SafeSwapHookImpl.deploy_hook(base_fee_bps,
      rebate_percent, salt)`: deploys the canonical EIP-1167 clone (OZ `Clones`, this impl baked in) at a mined salt,
      pre-flights BCD config + V4 permission bits (`HookSpawnRejected`), then `initialize_once` registers it. Callable on
      the impl or any clone (a clone-call forwards to the impl so the canonical code is always baked in). `get_hook_config()`
      replaces the verb-less getters and reverts on the impl. No separate `SafeSwapHookProxy` artifact needed; the parity
      test (`test_clone_deploys_exact_canonical_eip1167_runtime_bytecode`) proves the deployed runtime is byte-exact EIP-1167
      so clones pass the registry `extcodehash` gate. The impl's clone runtime codehash is published once to ChainConfig
      (`SAFESWAP_HOOK_CODEHASH_KEY`) after the impl is deployed - authorizing the bytecode, not addresses. The real-env test
      harness intentionally keeps synthesizing clones via `vm.etch` - it gives the most flexibility for testing.
- [ ] Deploy tooling: `script/` is empty. Needs the off-chain salt miner (BCD config + exact V4 permission bits, ~2^38 per
      profile), the per-profile `deploy_hook` call, publishing the impl's clone runtime codehash to ChainConfig, and
      router / NFT / treasury wiring from ChainConfig. Also the home for `deploy_hook`'s success / `CONFIG_MISMATCH` /
      `PERMISSIONS` paths that the unit suite can't mine (see `test/Hook/TestManifest.sol` note).
- [ ] Replace the `CONFIG_SIGNER` placeholder (`0xDeaDbeef...`, flagged in `AUDIT_REPORT.md` / `Definitions.sol`) and publish
      per-chain ChainConfig: V4 PoolManager address + signer for each target chain. (Standing deploy blocker.)
- [x] Remove `legacy_tests/` - deleted after the coverage cross-check.
- [x] Decide quoter precision + fee ceilings: keep two-pass quote simulation for exact-input and exact-output so quotes match
      execution, remove the low SafeSwap-specific repricing/total fee caps, and explicitly revert when configured surplus
      capture would require a V4 fee at or above 100%.
- [x] Split deployment optimizer profiles by deployable contract family. `foundry.toml` now has separate artifact dirs and
      optimizer runs for `deploy_hook`, `deploy_router`, `deploy_nft`, and `deploy_descriptor`, so the NFT descriptor can keep
      the full investor-card render at lower runs without forcing router/hook/NFT core bytecode down to the same setting.

## NFT presentation

- [x] Implement `tokenURI` via an external `SafeSwapPositionDescriptor` (keeps `SafeSwapNft` off the EIP-170 cliff - it only
      forwards). `tokenURI` returns `data:application/json;base64,<json>` whose `image` is a fully on-chain
      `data:image/svg+xml;base64,<svg>` card built from `get_lp_position` + live V4 state (current tick / position liquidity /
      in-range), plus an `attributes` array (token0/1 symbols, base fee %, rebate %, tick range, liquidity, status). NFT side
      is a 3-line `tokenURI`/`contractURI` delegating to the descriptor. DECIDED: descriptor address is **immutable** from
      ChainConfig (`SAFESWAP_POSITION_DESCRIPTOR_KEY`); treasury-settable art v2 deferred. Symbols are read defensively
      (native -> "ETH", non-conforming `symbol()` -> short address) and sanitized to an alphanumeric subset (no XML/JSON
      injection). Verified end-to-end by base64-decoding the URIs in `test/Nft/SafeSwapPositionDescriptor.t.sol`.
- [x] Add `contractURI()` - collection name + description, on-chain base64 JSON. Banner / external link / royalty fields
      deferred (hosting TBD); v1 ships name + description.
- [x] Derive LP NFT token ids from a chain-aware hash instead of a sequential counter. Each mint hashes scratch-space
      preimage `[chainid()][address(this) | uint96 counter]`, keeps the low 10 bytes for the ERC721 id / V4 salt, and
      re-rolls only on zero or an actual minted-id collision. Focused, workflow, and descriptor tests now capture the mint
      `Transfer` event instead of assuming token ids `1`, `2`, ...
- [x] Investor-card redesign (mock locked in `nft-renders/reference9.svg`): ported the new layout into
      `SafeSwapPositionDescriptor._render_svg` + `StringHelperLib`. Section order (the "arc"): header (8-byte hex token id +
      SafeSwap brand) / hero (pair name highlighted, muted amount beneath) / market row (inline price-range bar with live
      emerald price marker + In Range) / full-bleed FEE|REBATE|AGE stats band / earned|claimable line-grid (coin + download
      icons) / yield closing line (life | ann, grouped right). On-chain math/formatters DONE:
      `contracts/Nft/libraries/PriceLib.sol` (`price1_per_0_scaled` sqrtPriceX96->1e18 price decimal-adjusted,
      `price_at_tick_scaled` for bounds, `fill_width` marker clamp) + `StringHelperLib.format_price` / `group_thousands` /
      comma-grouped `format_token_amount`, proven by `test/Nft/PriceLib.t.sol` (16 tests, incl. ETH/USDC~3000 within 1%).
      Snapshot-stamp DONE: `StringHelperLib.format_utc_datetime(block.timestamp)` -> "YYYY-MM-DD HH:MM UTC" (Hinnant
      civil-from-days, `test/Nft/StringHelperLib.t.sol`, 5 tests). DECIDED: render it as faint bottom fine-print
      ("as of <datetime> UTC") so a marketplace-cached card visibly carries the as-of time of its live data.
      DONE: `_load_position` wires price fields into `PositionView`, `_render_svg` uses the reference9 350x480 layout,
      out-of-range positions use the red accent, and descriptor tests assert the layout, status variants, and snapshot
      footer. Descriptor still builds under the normal Foundry profile; EIP-170 deploy-profile tuning remains tracked in
      Pre-deploy.
- [x] **Self-locating attributes** - a snapshot of the `attributes` JSON now says *where* the position lives, not just what
      it is. Added `Chain Id` (`block.chainid`), `NFT Contract` (the `SafeSwapNft` address), `Token Id`, `Tick Spacing`,
      `Hook`, and `Pool Id` for V4 `PoolKey` verifiability. Kept these **out of the SVG card**; descriptor tests assert
      exact JSON traits and absence from the rendered SVG.

## Signing UX (WIP - see `SIGNING_UX_REFERENCE_1.md` / `SIGNING_UX_REFERENCE_2.md`)

Goal: render the gasless BondRoute envelope (`ExecuteBondAs`) so the wallet shows readable, *canonical-commitment* display
strings generated on-chain by `BondRoute_get_signing_info`, hashed as `keccak256(bytes(value))` inside the SafeSwap action
struct. Two frozen reference layouts exist (same structure, both cover all six actions: exact-in/out swap, create/add/remove
liquidity, collect fees):
- `SIGNING_UX_REFERENCE_1.md` - readable English prose values (`up to 1.25 WETH and 4,200 USDC`, `0.3% base fee, 50% rebate,
  tick spacing 60`).
- `SIGNING_UX_REFERENCE_2.md` - terse symbolic values (`= 1.25 WETH`, `<= 1.25 WETH + 4,200 USDC`, `2,850 ~ 3,150 USDC/WETH`,
  `|` separators). **LOCKED - this is the chosen layout.** Symbols are language-independent (i18n), shorter, and cheaper to
  hash; every token amount carries an operator (`=` exact / `<=` cap / `>=` floor). Caveat captured in its header: this buys
  universal *values* only - EIP-712 field-name rules force the *labels* (`Pay`, `Receive`, ...) to stay English identifiers
  baked into the type hash, so label localization must be a wallet-side overlay; the `Warning` is the only prose field and is
  English-only. REFERENCE_1 is kept only as the prose alternative for contrast.

Decisions already baked into both references (see the docs for the why):
- Long `Action`/`Pool` blobs split into short role-named single-word fields; each token symbol appears once per role.
- Amounts render at `StringHelperLib.FULL_PRECISION` (canonical commitment; trailing zeros trimmed).
- Token *address* fields are labeled with the (sanitized) symbol; sanitize like the NFT descriptor (the symbol lands in the
  on-chain-generated EIP-712 type string).
- `Warning` leads with `protocol` then token addresses. `protocol` is the root of trust - it both executes and generates the
  receipt, so a rogue `protocol` can spoof a byte-identical receipt; it must be checked against published ChainConfig
  addresses, never against the receipt itself.
- Create shows human `Range` / `Price` only; raw ticks / sqrtPriceX96 are dropped. **Open contract requirement:** this makes
  the signed price the source of truth, so `SafeSwapNft.create` must derive tick / sqrtPrice from the signed price on-chain
  (snapping to tick spacing); the committed `Deposit`/`Minimum` amounts are the economic anchor.

Open decisions: confirm the price-as-source-of-truth create change; then implement `BondRoute_get_signing_info` to emit the
REFERENCE_2 layout (pure ASCII, `|` pool separator) + the companion SDK message-values path.

- [x] Trim insignificant zeroes in the bps percent formatters. `StringHelperLib.format_bps_as_percent` and
      `format_bps_as_percent_string` now drop a zero fraction entirely and trim trailing zeroes via `trimmed_fraction`:
      `5 -> 0.05 / 0.05%`, `30 -> 0.3 / 0.3%`, `100 -> 1 / 1%`, `125 -> 1.25 / 1.25%`. Updated NFT descriptor expectations
      to `0.3%`, cleaned `0.30%` comments/samples, added direct formatter tests, and **registered `IStringHelperLibTests` in
      `test/Nft/TestManifest.sol`** (verified present: two new bps tests + the five date tests). Verified:
      `forge test --match-contract "StringHelperLibTest|SafeSwapPositionDescriptorTest"` -> 13 passed, 0 failed.

- [x] **Make `format_token_amount` precision explicit (was the canonical-signing blocker).** The old 4-decimal cap was
      fine for the SVG card but **unsafe for signed `Action` strings**: the signing notes require that if a raw param
      changes, a signed display field must change. A 4-decimal cap silently collapses any sub-0.0001 delta, so two distinct
      raw amounts could hash to the same `Action`. FIXED: `format_token_amount`/`format_symbol_amount` now take an explicit
      `max_decimals_to_render` arg (no overload - single signature), with the named sentinel
      `StringHelperLib.FULL_PRECISION` (`type(uint8).max`) for lossless/canonical rendering, and `0` for integer-only
      (sub-unit nonzero amounts show `<1`). One impossible-in-real-usage guard is an `assert` (Panic, not an ABI error -
      see CODING_STYLE.md): `token_decimals <= 77` (10^78 overflows uint256; replaces the old silent `>36` clamp that
      misrendered). The SVG card routes every amount through NFT-side helpers
      `_display_amount` / `_display_symbol_amount` (single chokepoint) using `DISPLAY_AMOUNTS_MAX_DECIMALS = 4`, so the lossy
      cap can never leak into a signing context. Tests: 8 new in `test/Nft/StringHelperLib.t.sol` (cap vs FULL_PRECISION
      side-by-side, the sub-cap injectivity/keccak distinctness proof, one-wei exact, zero-max-decimals revert via external
      wrapper), registered in `TestManifest.sol`. Full suite green (319 passed). NOTE for the signing path: render `Action`
      amounts with `FULL_PRECISION`, never the card helpers; the raw `uint256` typed envelope field stays the hard anchor.

## Review

- [ ] Review the signing path for bonded calls: `BondRoute_get_signing_info` typed strings + struct hashes across the router
      and NFT entrypoints - correctness, EIP-712 readability, and that the hashed params match what executes.

# SafeSwap Independent Pre-Deployment Review

Date: 2026-05-17

Scope: manual review of the SafeSwap repository excluding `REVIEW.md`. Focus areas were pre-deployment security, protocol economics, business readiness, auditability, and code quality.

## Status as of 2026-05-19

The findings below are preserved as the original snapshot. Current resolution status — see `REVIEW.md` for the canonical state:

- **#1 High — Protected-context lifetime:** ✅ Resolved. Hook callback allowance is now per-operation via a transient `_is_hook_callback_allowed` flag (set right before each library `execute`, consumed inside the hook callback). Adversarial-token reentrancy regression in `test/SafeSwap/ReentrantProtectedContext.t.sol`.
- **#2 Medium — V4 hook address flags:** ✅ Resolved. Constructor `_is_valid_safeswap_hook_address` rejects any deployment whose low 14 bits ≠ `0x0AA0`. Covered by `test_constructor_reverts_if_hook_address_has_wrong_flags`.
- **#3 Medium — ChainConfig signer trust:** ⚠️ Still applies. Operational; addressed via the deployment runbook in `REVIEW.md`.
- **#4 Medium — Stake economics calibration:** ⚠️ Partially addressed. Dust inputs now bump stake to 1 wei (closes the "free MEV protection" / 0-decimal-token gap). Empirical calibration by pool depth / fee tier remains an operational pre-deploy task.
- **#5 Low/Medium — Exact-output gross-up rounds down:** ✅ Decision documented. Kept truncating division (rounding dust ≤ 1 wei per swap ceded to the user); ceil-div costs more gas than the dust is worth.
- **#6 Low — `transfer_collector(address(0))`:** ✅ Resolved. Documented via NatSpec as the intentional cancel path; no separate cancel function by design.
- **Verification — `forge test`:** Now 212/212 passing across 17 suites (was 202 at review time).

Additional changes since this review:
- `SafeSwap.receive()` rejects direct native transfers from anyone other than the PoolManager or BondRoute (replaces the prior "anyone can pre-fund" tolerance).
- `Collector.get_collector()` exposes the active collector for off-chain inspection.
- `UniswapHook._is_valid_pool_manager` now carries explicit NatSpec clarifying that ChainConfig signer is the authoritative source — the shape check defends only against trivial misconfiguration.

## Executive Summary

SafeSwap has a compact architecture, a clear BondRoute-gated execution model, and a healthy Foundry test suite. `forge test` passes 202 tests, and `forge build` succeeds. The main pre-deployment blocker I found is not a failing test but a callback-context design risk: the hook-wide protected flag remains enabled across settlement and token transfer paths. If a malicious or callback-capable token can reenter while the PoolManager is unlocked, direct PoolManager operations may pass SafeSwap's hook checks without coming through BondRoute.

I would not deploy to production before tightening the protected-context lifetime, adding an adversarial-token regression test for that scenario, and documenting deployment invariants for Uniswap V4 hook address flags, ChainConfig signer control, BondRoute deployment assumptions, and stake economics.

## Verification Performed

- `forge test`: passed, 202 tests.
- `forge build`: passed.
- `slither .`: ran but exited non-zero after partial name-resolution failures involving the dependency tree. Useful direct findings included the expected protected-context/reentrancy shape in `User`, missing zero-address validation for `transfer_collector`, and mostly low-signal dependency/style findings.

## Priority Findings

### 1. High: Protected Context Stays Open During External Settlement

Relevant code:

- `src/User.sol`: protected context is set before `PoolManager.unlock(...)` and cleared only after it returns.
- `src/UniswapHook.sol`: callbacks only check `msg.sender == PoolManager` and `_is_protected_context == true`.
- `src/libraries/SafeSwapCommon.sol`: settlement calls `context.send(...)`, `pool_manager.settle()`, and `pool_manager.take(...)`.
- `src/libraries/AddLiquidityLib.sol` and `DonateLib.sol`: settlement includes token transfer paths while the hook-level context remains true.

The PoolManager is unlocked during `unlockCallback`. During that window, SafeSwap's callbacks accept any PoolManager-originated hook call as long as `_is_protected_context` is true. If a funded token or recipient path can trigger arbitrary code during settlement, that code may call PoolManager directly against a SafeSwap pool. The PoolManager would call SafeSwap's hook callback, and the callback would see `msg.sender == PoolManager` plus `_is_protected_context == true`.

The likely result is a BondRoute bypass for direct pool actions during a protected operation, at least for malicious/callback-capable assets. The attacker would still need to settle PoolManager deltas, but that is not the same security property as "all swaps/liquidity/donations must come through BondRoute".

Recommended change:

- Narrow the protected-context lifetime to only the exact PoolManager operation that needs the callback authorization: `swap`, `modifyLiquidity`, or `donate`.
- Clear the flag before any settlement, token transfer, `take`, or other external/value-flow step.
- Consider storing the expected action and pool id in transient storage and validating callback `PoolKey` and callback type, not just a boolean.
- Add a regression test with an adversarial ERC20 that reenters during `transferFrom`/settlement and attempts a direct PoolManager swap/add/remove/donate through the SafeSwap hook.

### 2. Medium: Deployment Depends on Correct V4 Hook Address Flags

The real-pool tests clone the hook to `0x0AA0`, matching `BEFORE_SWAP`, `BEFORE_DONATE`, `BEFORE_REMOVE_LIQUIDITY`, and `BEFORE_ADD_LIQUIDITY`. Production deployment must similarly mine or deploy the contract at an address whose lower bits match the intended hook permissions.

Recommended change:

- Add a deployment script that mines/enforces the hook address flags.
- Add a constructor or deployment-time assertion helper so an invalid address is caught before pool initialization.
- Document the required flag mask: `0x0AA0`.

### 3. Medium: ChainConfig Signer Is a Critical Trust and Availability Dependency

`Collector` passes `initial_collector` as the `config_signer`, and `UniswapHook` reads `v4.pool_manager.address` from ChainConfig during construction. This makes the initial collector/config signer a deployment-critical authority.

Recommended change:

- Use a multisig or hardware-backed signer for ChainConfig writes.
- Freeze and independently verify the PoolManager address before deployment.
- Document the exact ChainConfig key, signer, chain id, and PoolManager address in deployment artifacts.
- Consider separating config signer from fee collector if operationally useful.

### 4. Medium: Stake Economics Need Empirical Calibration Before Mainnet

Current constants are 1% swap stake and 2% liquidity stake, with 3 blocks of minimum delay. The code already notes that liquidity stake normalization uses current slot0 and can be manipulated on thin pools.

Recommended change:

- Build a simple economic model by pool depth, volatility, block time, gas cost, and expected MEV value.
- Decide whether stake should vary by fee tier, pool liquidity, asset class, or notional size.
- Add an explicit minimum stake floor to avoid zero or near-zero stakes on dust-sized fundings.
- Treat thin pools and long-tail assets as a separate launch category, not as equivalent to deep blue-chip pools.

### 5. Low/Medium: Exact-Output Fee Gross-Up Rounds Down

`ExactOutputSwapLib` calculates `grossed_up_pool_output` with truncating division. That can under-collect the intended protocol fee by up to rounding dust on exact-output swaps.

Recommended change:

- Use rounding-up math for the gross-up calculation.
- Add tests for tiny exact-output amounts and boundary values where `amount_out * divisor` is not divisible by `fee_complement`.

### 6. Low: Collector Transfer Allows Zero Pending Collector

`transfer_collector(address new_collector)` accepts `address(0)`. This does not immediately transfer collectorship, because `accept_collector()` cannot be called by the zero address, but it can leave confusing state and emit misleading transfer-start events.

Recommended change:

- Revert on `new_collector == address(0)`.
- Optionally add an explicit `cancel_collector_transfer()` callable by the current collector.

## Code Quality and Auditability

The code is readable and intentionally structured. The action libraries keep swap, liquidity, donation, fee, and signing concerns reasonably separated. The tests are broad for happy paths, slippage, fee math, real-pool behavior, fuzzing, and invariants.

Pre-deployment improvements:

- Add adversarial token tests, especially reentrancy during funding transfer and settlement.
- Add deployment invariant tests for hook permission bits and production-like ChainConfig setup.
- Avoid importing `LiquidityAmounts` from `lib/v4-core/../test/utils` in production libraries if possible. Vendor a reviewed copy or depend on a production library path.
- Add a short threat model document: what SafeSwap protects against, what it does not protect against, and which assumptions are inherited from BondRoute and Uniswap V4.

## Business and Product Readiness

The product claim is strong: deterministic fees replace stochastic MEV loss. That is credible only if the economic assumptions are presented conservatively.

Before launch:

- Publish fee examples with exact net-user-output semantics, including the protocol fee being taken from output.
- Document that SafeSwap does not make bad slippage settings safe; users still need sensible bounds.
- Decide initial supported pools/assets. A curated launch is safer than permissionless broad exposure on day one.
- Prepare incident procedures: disable selectors by changing `BondRoute_get_protected_selectors()` in a migration, pause pool creation at the frontend/indexer layer, and communicate ChainConfig/BondRoute dependency status.

## Deployment Checklist

- Fix protected-context lifetime and add adversarial reentrancy tests.
- Confirm hook address permission bits: `0x0AA0`.
- Confirm canonical BondRoute address and chain support.
- Confirm canonical ChainConfig address and signed PoolManager config.
- Use a multisig collector/config signer.
- Run `forge test`, `forge build`, and a clean static-analysis pass with dependency noise triaged.
- Produce deployment artifacts: bytecode hash, constructor args, ChainConfig entries, hook address, PoolManager address, BondRoute address, and supported pool list.
- Get an external smart-contract audit focused on the BondRoute integration, Uniswap V4 lock semantics, token-callback/reentrancy behavior, and stake economics.

## Bottom Line

SafeSwap is close enough to be worth auditing seriously, but I would treat the protected-context lifetime as a production blocker. The intended invariant is stronger than the current boolean check: callbacks should authorize only the specific PoolManager action currently being executed through BondRoute, and only for the minimum duration needed.

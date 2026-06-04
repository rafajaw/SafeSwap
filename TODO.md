# SafeSwap Test Suite Implementation TODO

## Design docs & mechanism
- [x] Rewrite the design docs to the surplus framing (capture% = share of repricing surplus, not a rate on displacement):
      `LVR_DETERRENCE.md`, `REPRICING_REBATE_ADDRESS_CONFIG.md`, `DYNAMIC_FEE_REBATE_PLAN.md` (binding), `CLAUDE.md`.
- [x] Fix the displacement-rate fee in code → surplus-based: rewrote `SafeSwapCommon.compute_repricing_fee_pips`
      (`+ swap_legs`, FullMath surplus valuation), swapped `MAX_REPRICING_REBATE_BPS` → `MAX_REPRICING_FEE_PIPS`, updated
      `SafeSwapHookImpl.beforeSwap` + both `User.sol` quoters, and rewrote the unit tests (capture% of surplus + symmetry +
      caps). 148 Common/Hook/Nft tests green.
- [x] Split exact-output max-input failures into `MaximumInputExceeded(required_input, maximum_required)`, keeping
      `SlippageExceeded(amount_received, minimum_required)` for minimum-output/minimum-received paths.

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
- [ ] Implement `test/Nft/SafeSwapNft.t.sol` (Tier 2 — focused/edge, mock PoolManager for injected deltas).
  - [x] Constructor, receive policy, create-position, create quote/signing slice.
  - [x] Add-liquidity authorization and execution.
  - [x] Remove-liquidity and collect-fees execution.
  - [x] Fix funding-source fidelity: real `TestERC20`, mint to bond owners, BondRoute mock pulls via `transferFrom`.
  - [x] Existing-position quotes and off-chain views.
- [x] Implement `test/Nft/SafeSwapNftWorkflow.t.sol` (Tier 1 — full workflow on real BondRoute + real V4; real
      balance/`StateLibrary` assertions, salt = tokenId, graceful PROTOCOL_REVERTED on unauthorized action).
- [x] Implement `test/Router/HookRegistry.t.sol` (codehash authorization, unset codehash, EIP-7702 designator rejection,
      BCD/config/permission validation, duplicate config handling, event emission, registered-hook lookup).
- [x] Implement `test/Router/SafeSwapRouter.t.sol` (constructor config reads/reverts, native receive policy, protocol-fee
      recipient, ERC20/native treasury withdrawals, one-wei retention, transfer failures, two-step treasury transfer).
- [x] Implement `test/Router/UserSwap.t.sol` (Tier 1 — full-workflow swaps: surplus fee applied live, quote == execution, protocol-fee accounting, graceful slippage revert, exact-output exactness).
- [x] Implement `test/Router/User.t.sol` (Tier 2 — exact-input/output edge behavior, quoter, pool id, and BondRoute integration per `IUserSwapTests`).
- [x] Implement `test/Router/PathFairness.t.sol` (real adjacent ranges: dynamic fee increases feeGrowthInside for crossed
      and final liquidity, fee growth follows served path length, both swap directions, raw V4 donate snapshot contrast).
- [ ] Implement focused mocks under `test/mocks` only where real dependencies are impractical for the edge case.
- [ ] Run each suite subset independently. Common (incl. SwapSimulator), Hook, Nft (both tiers), and Router
      HookRegistry / SafeSwapRouter / User Tier 2 / workflow suites (UserSwap + PathFairness) are green.
      NOTE: `forge test --match-path` cold-compiles sparsely and skips the string-referenced `ForceCompileV4.sol` (deployCode); run a full `forge test` or `forge build` first for suites that deploy real V4.
- [ ] Run the full active test suite.
- [ ] Use archived legacy tests as a final coverage checklist.

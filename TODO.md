# SafeSwap Test Suite Implementation TODO

## Design docs & mechanism
- [x] Rewrite the design docs to the surplus framing (capture% = share of repricing surplus, not a rate on displacement):
      `LVR_DETERRENCE.md`, `REPRICING_REBATE_ADDRESS_CONFIG.md`, `DYNAMIC_FEE_REBATE_PLAN.md` (binding), `CLAUDE.md`.
- [x] Fix the displacement-rate fee in code → surplus-based: rewrote `SafeSwapCommon.compute_repricing_fee_pips`
      (`+ swap_legs`, FullMath surplus valuation), swapped `MAX_REPRICING_REBATE_BPS` → `MAX_REPRICING_FEE_PIPS`, updated
      `SafeSwapHookImpl.beforeSwap` + both `User.sol` quoters, and rewrote the unit tests (capture% of surplus + symmetry +
      caps). 148 Common/Hook/Nft tests green.

## Test suite
- [x] Move stale legacy tests out of Foundry's active `test/` tree without deleting them.
- [x] Add shared test helpers under `test/helpers`.
- [x] Implement `test/Common/HookAddress.t.sol`.
- [x] Implement `test/Common/SafeSwapCommon.t.sol`.
- [x] Implement `test/Common/PoolManagerIntegration.t.sol`.
- [ ] Implement `test/Common/SwapSimulator.t.sol` (read-only V4 swap simulation — the dynamic-fee pivot depends on it; manifest references it but it does not exist yet).
- [x] Verify implemented Common suite with `forge test --match-path 'test/Common/*.t.sol'` (HookAddress + SafeSwapCommon + PoolManagerIntegration; SwapSimulator still pending).
- [x] Implement `test/Hook/SafeSwapHookImpl.t.sol`.
- [x] Build the shared real-environment harness (`test/helpers/SafeSwapRealEnv.t.sol`, `TestERC20.t.sol`,
      `ForceCompileV4.sol`): real V4 PoolManager + router + NFT + etched hook clone + real BondRoute. Reused by all suites.
- [ ] Implement `test/Nft/SafeSwapNft.t.sol` (Tier 2 — focused/edge, mock PoolManager for injected deltas).
  - [x] Constructor, receive policy, create-position, create quote/signing slice.
  - [x] Add-liquidity authorization and execution.
  - [x] Remove-liquidity and collect-fees execution.
  - [x] Fix funding-source fidelity: real `TestERC20`, mint to bond owners, BondRoute mock pulls via `transferFrom`.
  - [ ] Existing-position quotes and off-chain views.
- [x] Implement `test/Nft/SafeSwapNftWorkflow.t.sol` (Tier 1 — full workflow on real BondRoute + real V4; real
      balance/`StateLibrary` assertions, salt = tokenId, graceful PROTOCOL_REVERTED on unauthorized action).
- [ ] Implement `test/Router/HookRegistry.t.sol`.
- [ ] Implement `test/Router/SafeSwapRouter.t.sol`.
- [ ] Implement `test/Router/UserSwap.t.sol`.
- [ ] Implement `test/Router/PathFairness.t.sol`.
- [ ] Implement focused mocks under `test/mocks` only where real dependencies are impractical for the edge case.
- [ ] Run each suite subset independently. Common (implemented files), Hook, and Nft (both tiers) are green — 148 tests. Router suites + Common/SwapSimulator still to come.
- [ ] Run the full active test suite.
- [ ] Use archived legacy tests as a final coverage checklist.

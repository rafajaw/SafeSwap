# SafeSwap Implementation TODO

## Design docs & mechanism
- [x] Rewrite the design docs to the surplus framing (capture% = share of repricing surplus, not a rate on displacement):
      `LVR_DETERRENCE.md`, `REPRICING_REBATE_ADDRESS_CONFIG.md`, `DYNAMIC_FEE_REBATE_PLAN.md` (binding), `CLAUDE.md`.
- [x] Fix the displacement-rate fee in code → surplus-based: rewrote `SafeSwapCommon.compute_repricing_fee_pips`
      (`+ swap_legs`, FullMath surplus valuation), swapped `MAX_REPRICING_REBATE_BPS` → `MAX_REPRICING_FEE_PIPS`, updated
      `SafeSwapHookImpl.beforeSwap` + both `User.sol` quoters, and rewrote the unit tests (capture% of surplus + symmetry +
      caps). 148 Common/Hook/Nft tests green.
- [x] Split exact-output max-input failures into `MaximumInputExceeded(required_input, maximum_required)`, keeping
      `SlippageExceeded(amount_received, minimum_required)` for minimum-output/minimum-received paths.
- [x] C0 fast path: `SafeSwapHookImpl.beforeSwap` skips the `SwapSimulator` walk entirely when `capture == 0` (guard
      returns the flat base-fee override). Doubles as the "BondRoute + base fee, no repricing" product tier.
- [x] Bench the simulation cost end-to-end (`test/Router/SwapHookOverheadBench.t.sol`): overhead ≈ 9.4k fixed + ~4.1k per
      initialized tick crossed (~11% of a within-tick swap); full row contrast vanilla V4 / BondRoute+base / sim.
- [x] Prototype + bench the **optimistic** design (swapper supplies the repricing fee in `hookData`; `beforeSwap` trusts it,
      `afterSwap` reverts `UnderCaptured` on under-report) on research branch `optimistic-repricing-no-sim`.
      DECISION: **not canonical.** On-chain simulation wins for the immutable core — under BondRoute's commit→execute delay the
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
- [x] Implement `test/Nft/SafeSwapNft.t.sol` (Tier 2 — focused/edge, mock PoolManager for injected deltas).
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
- [x] Implement focused mocks under `test/mocks` only where real dependencies are impractical for the edge case.
- [x] Run each suite subset independently. Common (incl. SwapSimulator), Hook, Nft (both tiers), and Router
      HookRegistry / SafeSwapRouter / User Tier 2 / workflow suites (UserSwap + PathFairness) are green.
      NOTE: `forge test --match-path` cold-compiles sparsely and skips the string-referenced `ForceCompileV4.sol` (deployCode); run a full `forge test` or `forge build` first for suites that deploy real V4.
- [x] Run the full active test suite. (12 suites, 266 tests passed, 0 failed.)
- [x] Use archived legacy tests as a final coverage checklist. Cross-checked all 25 legacy files vs the four manifests:
      pre-rewrite suite is mostly obsolete (donate, transient protected-context, old memory-layout structs); remaining
      behaviors already covered. Found and filled one real gap — router `unlockCallback` caller guard
      (`test_unlock_callback_reverts_when_caller_is_not_pool_manager`). Deferred by choice: no fuzz/invariant layer (behaviors
      covered by concrete unit tests); protocol-fee floor exact-threshold boundary not separately pinned.
- [x] Cover `deploy_hook` + `get_hook_config` in the Hook manifest/suite: impl-call revert, canonical EIP-1167 runtime
      parity (the codehash gate), already-deployed collision, invalid-config decode revert, and clone→impl forwarding. The
      success / `CONFIG_MISMATCH` / `PERMISSIONS` paths need a mined valid address and are deferred to the deploy script.
- [x] Fix `SafeSwapRealEnv._create_and_execute_bond` multi-bond timing: the test frame reads `block.number` / `block.timestamp`
      stale after a deep BondRoute call, so drive vm.roll/vm.warp from absolute monotonic counters seeded once before any
      bond. Unblocks tests running ≥2 bonds in a single test body (e.g. `test_protocol_fee_recipient_is_router`). Full suite
      now 279 passing.

## Pre-deploy (outstanding)

- [x] **Config-hook deployment** — solved by the self-replicating `SafeSwapHookImpl.deploy_hook(base_fee_bps,
      rebate_percent, salt)`: deploys the canonical EIP-1167 clone (OZ `Clones`, this impl baked in) at a mined salt,
      pre-flights BCD config + V4 permission bits (`HookSpawnRejected`), then `initialize_once` registers it. Callable on
      the impl or any clone (a clone-call forwards to the impl so the canonical code is always baked in). `get_hook_config()`
      replaces the verb-less getters and reverts on the impl. No separate `SafeSwapHookProxy` artifact needed; the parity
      test (`test_clone_deploys_exact_canonical_eip1167_runtime_bytecode`) proves the deployed runtime is byte-exact EIP-1167
      so clones pass the registry `extcodehash` gate. The impl's clone runtime codehash is published once to ChainConfig
      (`SAFESWAP_HOOK_CODEHASH_KEY`) after the impl is deployed — authorizing the bytecode, not addresses.
  - [ ] Swap the real-env harness off `vm.etch` onto real `deploy_hook` (needs a mined salt — gated on the deploy tooling).
- [ ] Deploy tooling: `script/` is empty. Needs the off-chain salt miner (BCD config + exact V4 permission bits, ~2^38 per
      profile), the per-profile `deploy_hook` call, publishing the impl's clone runtime codehash to ChainConfig, and
      router / NFT / treasury wiring from ChainConfig. Also the home for `deploy_hook`'s success / `CONFIG_MISMATCH` /
      `PERMISSIONS` paths that the unit suite can't mine (see `test/Hook/TestManifest.sol` note).
- [ ] Replace the `CONFIG_SIGNER` placeholder (`0xDeaDbeef…`, flagged in `AUDIT_REPORT.md` / `Definitions.sol`) and publish
      per-chain ChainConfig: V4 PoolManager address + signer for each target chain. (Standing deploy blocker.)
- [ ] Remove `legacy_tests/` (`safeswap`, `stale_dynamic_fee_rewrite_SafeSwap`) once fully mined for coverage — already
      cross-checked as a checklist; delete the obsolete pre-rewrite suite.
- [ ] Decide quoter precision (1-pass exact-fee vs 2-pass exact-output) and confirm the final `MAX_REPRICING_FEE_PIPS` /
      `MAX_TOTAL_FEE_PIPS` values.

## NFT presentation

- [ ] Implement `tokenURI`: build on-chain metadata via an external `SafeSwapPositionDescriptor` (keeps `SafeSwapNft` under
      EIP-170 — it is the size-bound contract). `tokenURI` returns `data:application/json;base64,<json>` whose `image` is a
      live `data:image/svg+xml;base64,<svg>` card built from `get_lp_position` + V4 position state (liquidity / current tick /
      in-range), plus an `attributes` array (token0/1 symbols, base_fee_bps, rebate_percent, tick range, in_range). On
      `SafeSwapNft`: 3-line `tokenURI` override delegating to the descriptor + descriptor address wiring. DECIDE: descriptor
      address immutable (from ChainConfig) vs treasury-settable (art v2). Defer SSTORE2/3 for static art blobs unless the
      descriptor's own bytecode nears the limit.
- [ ] Add `contractURI()` (OpenSea collection-level metadata: name / description / banner / external link / royalty
      recipient). Format/hosting TBD — decide later.

## Review

- [ ] Review the signing path for bonded calls: `BondRoute_get_signing_info` typed strings + struct hashes across the router
      and NFT entrypoints — correctness, EIP-712 readability, and that the hashed params match what executes.

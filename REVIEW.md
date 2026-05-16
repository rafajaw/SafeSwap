SafeSwap — Pre-Deployment Code & Security Review

  Scope: all of src/ (SafeSwap.sol, UniswapHook.sol, User.sol, Collector.sol, BondRouteProtected.sol, IChainConfig.sol, libraries) and the 15 test suites (202/202 passing).
  Build: forge build --sizes clean; SafeSwap runtime = 24,453 bytes (123 B under EIP-170 cap).   // *FIXED* — was 24,417 / 159 B, grew after canonical BondRouteProtected.sol swap.
  Tests: forge test — all 202 pass (re-verified after canonical swap).

  ---
  1. Pre-deployment blockers (must fix before mainnet)
  
  BLOCKER-1: BONDROUTE_ADDRESS is a placeholder   // *FIXED*

  src/integrations/BondRouteProtected.sol:421
  address constant BONDROUTE_ADDRESS = address(0x0000000000000000000000426F6E64526F7574650000);  // ***TODO*** Set after deployment.
  This baked-in constant points at a non-existent contract. If deployed as-is, every BondRoute_initialize() call reverts on Unauthorized, and the constructor's
  BondRoute.announce_protocol(...) fails silently or reverts (depending on EOA vs missing code). Action: patch with the canonical BondRoute address before deploying SafeSwap.
   Tests use vm.etch at the placeholder, so they don't catch this.

  // *FIXED* — File replaced wholesale with the canonical version from rafajaw/BondRoute. BONDROUTE_ADDRESS now reads
  //          0xb01d00000000440215e86e0A436f9b59FeB2F14a. Bytecode grew 24,417 → 24,453 B (123 B under EIP-170 cap).
  //          Remaining off-chain step: verify that address has deployed code on each target chain before deploy.

  BLOCKER-2: ChainConfig must be pre-populated by initial_collector

  UniswapHook constructor reads ChainConfig.read_address(initial_collector, "v4.pool_manager.address"). If the deployer hasn't first signed and written the V4 PoolManager
  address into ChainConfig under that signer's keyspace, deployment reverts with InvalidPoolManager(0x0).
  Note: the initial_collector arg passed to SafeSwap is silently aliased as the ChainConfig signer (Collector → User → UniswapHook(config_signer)). That dual purpose is
  undocumented and easy to miss. Worth a one-line comment in the SafeSwap constructor.
  
  BLOCKER-3: Hook address mining (CREATE2 salt)
  
  V4 requires the hook's address to carry permission flags in its low bits. The required flags here are BEFORE_SWAP (0x80) | BEFORE_DONATE (0x20) | BEFORE_REMOVE_LIQUIDITY 
  (0x200) | BEFORE_ADD_LIQUIDITY (0x800) = 0x0AA0. Tests use vm.cloneAccount to fake this. There is no deployment script in this repo — script/ does not exist. You'll need a
  CREATE2 mining flow (e.g., a DeployScript.s.sol that brute-forces a salt) before mainnet deploy. If the hook deploys to an address without the right flags,
  PoolManager.initialize on any pool using this hook will revert with HookAddressNotValid.
  
  ---
  2. High-severity findings

  H-1: One-sided liquidity ops can have ~0 stake → MEV protection bypass   // *FIXED*
  
  AddLiquidityLib.get_constraints computes min_stake = 2% of amount0_desired. If the user funds (0, X) (one-sided position above current tick), stake = 0. _validate_stake
  skips when min_stake.amount == 0, so BondRoute accepts the bond at zero cost. RemoveLiquidityLib is worse: min_stake = 2% of amount0_min, and amount0_min is fully
  user-controlled — set it to 0 and there's no abandonment cost.

  This breaks BondRoute's "abandonment cost" guarantee for liquidity ops in those configurations. Bond farming becomes free for one-sided LP adds and arbitrary removes.
  Fix options: (a) measure stake against both sides (e.g., max of token0/token1 notional via slot0 price), (b) require an absolute minimum stake floor in the user's preferred
   funding token, (c) for remove, base stake on the position's live liquidity rather than amount0_min.

  // *FIXED* — Stake is now slot0-normalized in token0 across both sides of every liquidity / donate bond. Closes the
  //          dust attack (1 wei on one side, real value on the other). RemoveLiquidityLib derives released amounts from
  //          params.liquidity at current slot0 instead of user-supplied amount0_min/amount1_min. Donate fixed in the same
  //          pass (it had the identical bug). Tests verify normalized stake, one-sided positions, and dust regression.

  H-2: MIN_PROTOCOL_FEE_RATE confiscates 100% of LP fee on 0.01% pools
  
  SafeSwapCommon.sol:42: MIN_PROTOCOL_FEE_RATE = 1000 (= 0.01%). On a POOL_FEE_001 (0.01%) pool the protocol fee rate equals the entire LP fee rate — LPs effectively earn
  nothing on that pool while the protocol takes the floor. On a 0.05% pool (POOL_FEE_005 = 500) the floor is 20% of the LP fee, not the README's stated 10%.
  
  This is an economic correctness issue. README says "Floor of 0.01% for low-fee pools (prevents near-zero fees on stablecoin pools)" which describes the intent, but the
  implementation eats LP economics at the low end. Fix options: (a) cap the protocol take at 50% of LP fee, (b) skip the floor when pool_fee < FLOOR, (c) explicitly disallow
  pools with fee < FLOOR / 10 from being used.
  
  H-3: minimum_amount_out / amount_out semantics are gross, not net
  
  - ExactInputSwapLib.execute checks if (amount_out < params.minimum_amount_out) revert. But the user ultimately receives amount_out - protocol_fee. A user setting
  minimum_amount_out = 100 may actually receive 99.97. This is a slippage-protection gotcha.
  - ExactOutputSwap is worse — the function is named "exact output" but the user receives amount_out - protocol_fee, not amount_out.
  
  The real-pool test at RealPoolIntegration.t.sol:390 documents and asserts this behavior explicitly: assertEq(token1_received, desired_out - expected_fee, ...). So this is
  intentional, but it's confusing API. Fix options: (a) net the fee out before the slippage check, (b) document prominently, (c) rename to swap_with_input /
  swap_for_target_output.

  ---
  3. Medium-severity findings

  M-1: On-chain constraint re-validation is a no-op

  BondRouteProtected.BondRoute_validate calls BondRoute_quote_call with context.stake.token and context.fundings as the preferred values, then validates the returned
  constraints against the same context. Since SafeSwap's quote_call derives min_stake and min_fundings directly from preferred_fundings, the returned constraints always match
   the inputs. The validation reduces to a tautology.

  Real security comes entirely from BondRoute's commit-reveal matching. The "validation" only catches timing constraints (MIN_EXECUTION_DELAY_IN_BLOCKS,
  MAX_SWAP_EXECUTION_DELAY) which are enforced against block.timestamp/block.number. This is fine for correctness but worth understanding: anyone reading the code may think
  the validate step adds protection it doesn't.

  M-2: _is_valid_pool_manager doesn't actually identify Uniswap V4
  
  The probe checks protocolFeeController(), extsload(bytes32[]), and supportsInterface(0x0f632fb3) (ERC6909). Any contract implementing those three responses passes. The only
   real guarantee that the pool_manager is the canonical V4 PoolManager is the trust placed in the config_signer (collector at deploy time). Document this — and verify
  off-chain before deploy that the ChainConfig entry actually points at the real V4 PoolManager for that chain.
  
  M-3: Add-liquidity slippage error name is misleading

  AddLiquidityLib.sol:155,170: when amount0_min > 0 but amount0 == 0 (one-sided position case), the contract reverts with SlippageExceeded({amount_received: 0, 
  minimum_required: amount0_min}). For add_liquidity, the user is depositing, not receiving. amount_received is the wrong field name in this context. Consider a dedicated
  error like OneSidedDepositMismatch(int side, uint256 expected).
  
  M-4: No migration / pause path if BondRoute fails

  SafeSwap can deprecate selectors by removing them from BondRoute_get_protected_selectors(), but doing so locks user positions inside the hook: liquidity is owned by the
  hook contract under salts derived from (user, salt), and only remove_liquidity (through a bond) can extract it. If BondRoute ever malfunctions, becomes uneconomic, or
  simply isn't deployed at BONDROUTE_ADDRESS, LPs are stuck.
  
  This is a fundamental architectural property of BondRoute integration, not a bug — but it should be a known risk. Consider a __OFF_CHAIN__ getter that reveals user position
   metadata so users have an auditable path to verify they still own positions, and explicitly document the trust assumption in the deployment notes.

  M-5: pure vs view mismatch on BondRoute_quote_call   // *FIXED*
  
  The interface IBondRouteProtected.BondRoute_quote_call is declared view; SafeSwap overrides as pure. Solidity allows pure→view downgrade, but the implementation cannot
  evolve to read state without breaking the override. If you later want dynamic per-pool stake sizing (e.g. based on live pool TVL or volatility), you'll need to lift pure to
   view across all five libs. Worth noting now.

  // *FIXED* — SafeSwap.BondRoute_quote_call is now view (driven by H-1's slot0 reads). AddLiquidityLib, RemoveLiquidityLib,
  //          and DonateLib lifted to view consistently. Swap libs stay pure (no state dependency).
  
  M-6: Position custody depends on stable user address

  SafeSwapCommon._position_salt(user, salt) = keccak(user, salt). If a user creates a bond from a smart-account wallet, removes it, and that wallet later changes its proxy
  implementation, the position salt remains tied to the address — fine. But account-abstraction wallets that delegate to a different signer per bond (or batched relayers
  signing for many users) need to ensure ctx.user reflects the right beneficiary. BondRoute's spec says "the user who created the bond"; verify the canonical BondRoute deploy
   delivers that semantics.
  
  ---
  4. Low-severity / notes

  - L-1: Collector.withdraw_fees is collector-only; ordering is balance-read → check → transfer. Reentrancy via a malicious recipient is limited to draining current balance —
   the second invocation finds balance <= 1 and returns 0. Safe by check-effects-interactions even without a guard.
  - L-2: receive() accepts ETH from anyone. Anyone can pre-load the hook with ETH. Collector withdraws it. No harm; worth a one-line note.
  - L-3: Collector.withdraw_fees keeps 1 wei dust — intentional gas optimization for next collection. Tests verify
  (FeeWithdrawalTest.test_withdraw_fees_keeps_1_wei_for_gas_optimization).
  - L-4: Swap stake rounds down (99 * 1 / 100 = 0). Trivial-amount swaps get free MEV protection. Acceptable.
  - L-5: No swap/liquidity/donate events emitted by SafeSwap itself. Indexers must rely on V4 PoolManager events. Consider one summary event per protected op for visibility.
  - L-6: transfer_collector allows setting pending_collector = address(0), which is a no-op (no one can accept). Effectively a "cancel" — but if you want explicit
  cancellation, document it.
  - L-7: BondRoute_validate runs BondRoute_quote_call again on every execution. For donate, this includes the Fundings must match donation tokens revert that consumes the
  bond if a malformed donate slips through. Verify off-chain front-ends enforce token0 < token1 ordering exactly.
  - L-8: ExactInputSwapLib/ExactOutputSwapLib use MIN_SQRT_PRICE_LIMIT/MAX_SQRT_PRICE_LIMIT (= bound ± 1) for sqrtPriceLimitX96, which is "no limit" — slippage is enforced
  solely via minimum_amount_out/maximum_amount_in. Standard pattern, but worth knowing.

  ---
  5. Documentation / housekeeping (info)
  
  - CLAUDE.md references src/BondRouteProtected.sol and src/SafeSwapHook.sol — actual paths are src/integrations/BondRouteProtected.sol and src/UniswapHook.sol. Update.
  - README.md says "180 tests across 14 suites" — current count is 202 tests across 15 suites (DonateExecution added). Update.
  - README architecture diagram has BondRouteProtected, UniswapHook -> User -> Collector -> SafeSwap which is correct, but should make explicit the deploy-time alias
  initial_collector == config_signer.
  - The foundry.toml change (1B → 50k optimizer_runs) is currently uncommitted and the only working-tree delta. Commit it before deployment so the binary you audit is the
  binary you ship.

  ---
  6. What the test suite covers well

  - All 4 hook callbacks (beforeSwap / beforeAddLiquidity / beforeRemoveLiquidity / beforeDonate) gate on both msg.sender == PoolManager and _is_within_protected_context.
  Tested for both rejection and acceptance.
  - unlockCallback rejects non-PoolManager callers and dispatches all 5 actions correctly.
  - Collector 2-step transfer (start/accept) plus rejection of non-collector callers.
  - Direct-pool attack vectors: DirectSwapAttacker and DirectDonateAttacker confirmed rejected (RealPoolIntegrationTest.test_real_pool_hook_rejects_direct_pool_swap /
  _donate).
  - _position_salt isolation — User A's position is provably untouchable by User B with the same salt (test_real_pool_add_liquidity_position_salt_isolation).
  - Protocol fee math is asserted against on-chain pool state in RealPoolIntegrationTest (live V4 PoolManager via ForceCompileV4).
  - 7 invariants over 32 runs × 2048 calls each (InvariantsTest).
  
  7. Coverage gaps worth filling

  - Donate fuzz / invariants — only 3 happy-path donate tests. Add fuzz over (amount0, amount1) and edge cases (token0 ≠ pool's currency0 ordering).
  - Fee-on-transfer / rebasing tokens — every funding flow assumes 1:1 transferFrom accounting. No tests with non-standard ERC20 behavior. If FoT tokens are in scope, the
  pool_manager.sync → transfer → settle cadence will under-credit and revert. If out of scope, document that.
  - Native ETH end-to-end — Integration.t.sol:83-112 only constructs structures with NATIVE_TOKEN, no execute(...) call. Add a real-pool test that runs a swap and an
  add/remove with address(0) (native).
  - Floor pool (POOL_FEE_001 = 100) — ProtocolFeeTest validates the math, but there is no integration test running a swap on a 0.01% pool to confirm LP-economics behavior
  described in H-2.
  - Constraint timing edge cases — test_quote_call_* covers normal values, but I didn't see a test for creation_block == block.number (zero blocks elapsed) producing
  EXECUTION_TOO_SOON.
  - BondRoute_quote_call reverts for invalid selector — revert UnknownSelector(selector) is asserted, but no test confirms BondRoute treats this as "graceful settle, refund
  stake" rather than PossiblyBondFarming.
  - CREATE2 hook-address mining — no test that simulates deploying to a wrong address and confirms PoolManager.initialize rejects it. Useful as a deployment smoke test.
  
  ---
  8. Pre-deployment checklist

  1. Patch BONDROUTE_ADDRESS in src/integrations/BondRouteProtected.sol:421 to canonical BondRoute on target chain. Verify with on-chain code probe.   // *FIXED* (in-source); on-chain code probe still pending per chain.
  2. Write ChainConfig entry for v4.pool_manager.address under the initial_collector signer for each target chain, before SafeSwap deploys. Verify with
  ChainConfig.read_address from a script.
  3. Verify ChainConfig contract is deployed at 0x5Afec0de00EB1c5323C7faA110f67499F744467b on the target chain. If not, deploy or block the deployment.
  4. Write a CREATE2 deploy script that mines a salt producing a hook address with low 14 bits = 0x0AA0. Confirm via a dry-run PoolManager.initialize against a throwaway
  pool.
  5. Decide the initial_collector — this is both the collector role and the chain-config signer at deploy. Likely a multisig. Document the rotation plan if the collector
  multisig is to change (note: only collector rotates; chain-config signer is fixed at deploy).
  6. Resolve H-1 (zero-stake one-sided liquidity ops) — at minimum, document if accepted; ideally fix.
  7. Resolve H-2 (LP-fee confiscation at floor) — at minimum, decide policy and document. If keeping current behavior, block pools below ~0.10% fee at the front-end /
  declared-pools layer.
  8. Decide on H-3 — either rename functions, net the fee out of the slippage check, or add a prominent note in User.sol doc-comments.
  9. Update README.md test counts (180→202, 14→15 suites). Update CLAUDE.md file paths.
  10. Commit foundry.toml optimizer_runs change.
  11. Run forge test -vvv on the exact commit that will be deployed, with the patched BONDROUTE_ADDRESS, and archive the output.
  12. External audit pass — recommend at minimum a third-party review focused on the BondRoute integration semantics, the per-action stake design (H-1), and the fee floor
  (H-2).
  13. Mainnet simulation / fork test — run an end-to-end add/swap/remove against a forked mainnet V4 PoolManager with the real BondRoute address.
  14. Verify hook source on Etherscan/Sourcify immediately after deploy.
  15. Have a documented LP-recovery procedure in case remove_liquidity selector is ever removed from BondRoute_get_protected_selectors.

  ---
  Overall assessment: The codebase is small, disciplined, and reads cleanly. The BondRoute integration follows the documented base contract semantics, and the access-control
  story (PoolManager-only callbacks + transient protected-context flag) is airtight. The four high-severity items are design-level concerns, not coding bugs: stake sizing for
   liquidity (H-1), fee floor on low-fee pools (H-2), and swap-amount semantics (H-3). None block ship if you make conscious decisions; H-1 and H-2 deserve real attention.
  The three blockers in §1 are the only items that will definitely break a naive deployment.

● Review complete. Summary in two lines: 3 deploy-blockers (placeholder BONDROUTE_ADDRESS, required ChainConfig pre-pop, hook-address CREATE2 mining + missing deploy script)
  and 3 high-severity design items (zero-stake one-sided liquidity, fee floor confiscates LP earnings on ≤0.05% pools, "exact output" actually nets-of-fee). All 202 tests
  pass and the access-control story is solid; the rest is mostly documentation drift and coverage gaps. Full findings + 15-item pre-deploy checklist above.

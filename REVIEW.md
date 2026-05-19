# SafeSwap Pre-Deployment Review

## Status

- **Build:** SafeSwap runtime = 21,862 bytes (2,714 B under the EIP-170 cap, with `optimizer_runs = 10_000`). Re-measure after each iteration.
- **Tests:** 212/212 passing across 17 suites.
- **Scope:** `src/SafeSwap.sol`, `src/User.sol`, `src/Collector.sol`, `src/UniswapHook.sol`, `src/Definitions.sol`, `src/libraries/*`, `src/integrations/BondRouteProtected.sol`, `src/integrations/IChainConfig.sol`, plus the `test/SafeSwap/` suites.

---

## Deployment runbook

Operational requirements that must be true at or before deployment. Not security findings, but the deployment fails or behaves incorrectly without them.

1. **ChainConfig is deployed at `0x5Afec0de00EB1c5323C7faA110f67499F744467b`** on the target chain. The constructor reads from this canonical address; if no code is present, every read reverts.

2. **ChainConfig contains `uniswap_v4/pool_manager`** under the deployer's signer keyspace, set to the canonical Uniswap V4 PoolManager for the target chain. Otherwise the constructor reverts with `"SafeSwap: Invalid pool_manager"`.

3. **BondRoute is deployed at `0xb01d00000000440215e86e0A436f9b59FeB2F14a`** on the target chain. The canonical address is baked into `BondRouteProtected.sol`. If no code is present, the constructor's `BondRoute.announce_protocol(...)` reverts.

4. **CREATE2 hook-address mining.** Uniswap V4 requires the hook address to encode permission flags in its low 14 bits (mask = `0x3FFF`). SafeSwap needs `BEFORE_SWAP (0x0080) | BEFORE_ADD_LIQUIDITY (0x0800) | BEFORE_REMOVE_LIQUIDITY (0x0200) | BEFORE_DONATE (0x0020) = 0x0AA0`. There is no deploy script in this repository; one must be added before mainnet. The constructor now enforces this at deploy time via V4's `Hooks.validateHookPermissions(IHooks, Permissions)` (declarative struct of named booleans, no magic mask), which reverts with `HookAddressNotValid(address)` before any pool can be initialized — so a wrong-flags deployment fails fast rather than at first `PoolManager.initialize`. Mining target: low 3 hex digits = `AA0` **and** the 4th-from-low nibble ∈ {0,1,2,3} so bits 12/13 stay clear. Any standard V4 hook miner (`mask + flags`) handles this.

5. **`CONFIG_SIGNER` is the protocol-wide ChainConfig signer.** Hardcoded in `src/Definitions.sol` as a `// ***TODO***` placeholder; replace with the canonical SafeSwap signer key for the target chain before mainnet. The constructor is zero-arg and reads both PoolManager and initial collector from ChainConfig under this keyspace.

6. **ChainConfig contains `safeswap/initial_collector`** under `CONFIG_SIGNER`, set to the initial fee collector. Otherwise construction reverts with `"SafeSwap: Invalid initial_collector"`.

---

## Findings

### Resolved since initial review

- **High (Independent #1) — Protected-context lifetime.** Hook callback allowance is now scoped to the exact PoolManager operation via a transient `_is_hook_callback_allowed` flag set right before each library `execute` and cleared inside `_consume_hook_callback_allowance`. Adversarial reentrancy regression covered in `test/SafeSwap/ReentrantProtectedContext.t.sol`.
- **Medium (Independent #2) — Hook address flag enforcement.** Constructor calls V4's `Hooks.validateHookPermissions(IHooks(address(this)), Permissions{...})` with a declarative struct of named booleans (no opaque `0x0AA0` mask). Reverts with `HookAddressNotValid(address)` if the deployed address doesn't match the declared flags. Covered by `test_constructor_reverts_if_hook_address_has_wrong_flags`.
- **L-2 — Direct native transfers rejected.** `SafeSwap.receive()` now reverts with `"Direct transfers not allowed"` on any sender other than the PoolManager (protocol fees on native swaps) or BondRoute (native funding pulls). Replaces the previous "anyone can pre-fund, collector withdraws" tolerance with explicit allow-listing. Covered by `test_receive_rejects_direct_native_transfer_from_arbitrary_sender`, `test_receive_accepts_native_from_pool_manager`, `test_receive_accepts_native_from_bondroute`.
- **L-4 — Dust-input stake.** `calculate_swap_stake` and `calculate_normalized_liquidity_stake` now bump a floored-to-zero result up to 1 wei. Closes the "free MEV protection on dust" gap for 0-decimal / low-decimal tokens (gaming ERC20s, fractional RWAs) where 1 wei = 1 unit = real value. Covered by `test_swap_stake_bumps_dust_to_one_wei` and `test_swap_stake_zero_input_still_bumps_to_one_wei`.
- **L-8 — `OneSidedDepositMismatch`.** One-sided position mismatches now revert with `OneSidedDepositMismatch(address expected_token, uint256 minimum_required)` instead of misusing `SlippageExceeded`. Covered for both token0 and token1.
- **L-6 — `transfer_collector(address(0))` cancel semantics.** Documented via NatSpec; this is the intentional cancel path, no separate cancel function exists by design.
- **Independent #5 — exact-output gross-up rounding.** Kept truncating division (rounding dust ≤ 1 wei per swap ceded to the user); ceil-div costs more gas than the dust is worth. Decision documented inline in `ExactOutputSwapLib`.
- **Independent #6 — same as L-6 above.**
- **Coverage gap — CREATE2 hook-flags smoke test.** `test_constructor_reverts_if_hook_address_has_wrong_flags` confirms a wrong-bit address is rejected.
- **Coverage gap (partial) — donate fuzz.** Two fuzz tests (`testFuzz_donate_executes_for_arbitrary_split`, `testFuzz_donate_executes_for_one_sided_split`) exercise arbitrary and one-sided splits. Donate invariants still not added.
- **Coverage gap (partial) — constraint timing.** `BondRoute_quote_call` execution-delay assertions added for all five action types (add/remove liquidity and donate were previously untested). The `block.number == creation_block` boundary itself is enforced inside BondRoute, not here, so it stays untested at the SafeSwap layer.
- **M-5 — Native-ETH settlement.** Fixed via `SafeSwapCommon.settle_input`: native inputs are pulled to the hook (which has `receive()`) and then forwarded as `pool_manager.settle{value: amount}()`, satisfying V4's "ETH must ride msg.value" contract. ERC20 path unchanged. End-to-end coverage in `test_real_pool_native_exact_input_swap_eth_to_erc20`, `..._erc20_to_eth`, and `test_real_pool_native_add_and_remove_liquidity`.
- **M-4 (partial) — Position salt mechanism simplified.** `SafeSwapCommon._position_salt` removed; V4 owner-keyed positions now use `bytes32(uint160(user))` directly as the V4 salt. Eliminates the duplicate-named `salt` field in the EIP-712 wallet display and the salt-fragmentation footgun (random/forgotten salts splintering a user's liquidity). The AA-wallet beneficiary-identity concern remains as the rephrased M-4 below.
- **Internal consistency — RemoveLiquidity API mirrors AddLiquidity.** `RemoveLiquidityParams` now carries `TokenAmount min_a` / `min_b` (address-tagged minimums) instead of positional `token0` / `token1` + `amount0_min` / `amount1_min` uint256s. The pool's two tokens are derived from the mins' addresses (sorted internally), eliminating the same wrong-order / positional-min footguns that AddLiquidity shed earlier. All four liquidity-touching libs (Add, Remove, Donate, swaps) now share one convention: callers pass data in any address order, the lib resolves by address.

### Medium

**M-1: PoolManager identity is only validated by interface shape**

`UniswapHook._is_valid_pool_manager` checks `protocolFeeController()`, `extsload(bytes32[])`, and `supportsInterface(ERC6909)`. Any contract implementing those three responses passes. The real guarantee that the configured address is *the* canonical V4 PoolManager comes from trust in the ChainConfig signer at deploy time. Verify off-chain that the configured PoolManager matches Uniswap's canonical deployment for each chain.

**M-2: LP custody depends on BondRoute remaining functional**

Liquidity positions are owned by the hook contract under the V4 salt `bytes32(uint160(user))`. The only path to extract them is `remove_liquidity`, which requires a BondRoute bond. If BondRoute ever ceases to function — or if SafeSwap removes `remove_liquidity` from `BondRoute_get_protected_selectors` — LPs are stranded. This is the documented BondRoute integration property, not a bug. Surface it in user-facing docs and consider an off-chain getter so users can inspect their positions independently of BondRoute.

**M-3: On-chain constraint re-validation is structurally a tautology**

`BondRouteProtected.BondRoute_validate` calls `BondRoute_quote_call` with the user's actual stake and fundings as the *preferred* values, then validates the returned constraints against the same context. Because SafeSwap's `quote_call` derives `min_stake` and `min_fundings` from those preferred values, the stake and funding checks always succeed for honest input. The only constraints independently enforced are the timing ones (`MIN_EXECUTION_DELAY_IN_BLOCKS`, `MAX_*_EXECUTION_DELAY`) against `block.number` / `block.timestamp`. Real security comes from BondRoute's commit–reveal matching the user-revealed call. Anyone auditing the validation should understand this.

**M-4: Position salt couples LP custody to a stable user address**

V4 positions are owned by the hook under the salt `bytes32(uint160(ctx.user))` — the bond submitter's address IS the position discriminator. Account-abstraction wallets and relayers that delegate differently per bond must ensure `ctx.user` always reflects the intended beneficiary; otherwise positions accrue under one address but the human controlling the funds queries from another and sees nothing. The canonical BondRoute is expected to deliver "the user who created the bond" semantics — confirm this matches the deployed contract.

**M-5:** *Resolved — see Resolved section above. `SafeSwapCommon.settle_input` now routes native via the hook + `settle{value:}`.*

### Low

**L-1:** `Collector.withdraw_fees` is collector-only and reads balance before transfer. A re-entrant recipient on the second call sees `balance <= 1` and returns zero. Safe by ordering without an explicit guard.

**L-2:** *Resolved — see Resolved section above.*

**L-3:** `withdraw_fees` keeps 1 wei dust to avoid the 0→nonzero SSTORE penalty on the next fee collection. Intentional.

**L-4:** *Resolved — see Resolved section above.*

**L-5:** SafeSwap emits no operation-level events for swap / liquidity / donate. Indexers must derive these from Uniswap V4 `PoolManager` events. Consider one summary event per protected op.

**L-6:** *Resolved — documented via NatSpec on `Collector.transfer_collector`. See Resolved section above.*

**L-7:** Swap libs set `sqrtPriceLimitX96` to `TickMath.MIN_SQRT_PRICE + 1` / `TickMath.MAX_SQRT_PRICE - 1` (= absolute V4 bound ± 1). In-pool slippage is "no limit"; slippage is enforced solely via `minimum_amount_out` / `maximum_amount_in`. Standard pattern.

**L-8:** *Resolved — see Resolved section above.*

---

## Design decisions

These are intentional behaviours documented for reviewers and integrators.

**D-1: Protocol fee — `max(0.01%, 10% of LP fee)` of swap output, paid by the swapper**

LPs are unaffected; the fee is layered on top of the LP fee through V4's internal accounting. Effective swapper cost per tier:

| Pool LP fee | Protocol fee | Total swapper cost |
|---|---|---|
| 0.01% | 0.01% (floor) | 0.02% |
| 0.05% | 0.01% (floor) | 0.06% |
| 0.10% | 0.01% (= 10%) | 0.11% |
| 0.30% | 0.03% | 0.33% |
| 1.00% | 0.10% | 1.10% |

The fee replaces stochastic MEV exposure with a deterministic surcharge. Realistic MEV exposure today, on the same swap, sits at **0.5–2%** for retail volatile-pair trades, **2–5%+** for large or illiquid trades, and **0.05–0.25%** for stablecoin pairs (driven by CEX–DEX latency arbitrage and JIT-LP sandwiches). Even users routing through private relays or solver auctions still lose **0.10–0.50%** in residual MEV and solver spread. The protocol fee at every tier is between **5× and 200× cheaper** than the MEV the user would otherwise bear, and predictable rather than variable. The floor is also what makes operating SafeSwap on stablecoin pools economically viable; without it the 10%-of-LP-fee rate yields ~$0.01 per $1k swap, which doesn't cover BondRoute stake bookkeeping.

**D-2: BondRoute as a single point of failure**

LP custody, swap execution, and donate flows all hinge on BondRoute. If the canonical BondRoute is paused or migrated, SafeSwap users have no fallback path. Surface this risk in user-facing docs. SafeSwap exposes `get_position_info(pool_id, user, tick_lower, tick_upper)` so users (or any aggregator) can inspect LP positions on-chain without going through BondRoute.

**D-3: Fee-on-transfer and rebasing tokens are out of scope**

SafeSwap inherits Uniswap V4's stance: the PoolManager's `take`/`settle` accounting assumes 1:1 token transfers. Tokens that deviate from this — fee-on-transfer, rebasing, blocklists that intermittently fail transfers — will cause settlement deltas to mismatch, breaking the pool's invariants. We do no extra handling; if Uniswap doesn't support it, neither do we. Curate pool whitelists accordingly.

**D-4: `CONFIG_SIGNER` is decoupled from the fee collector**

Hardcoded in `src/Definitions.sol` so the SafeSwap binary points at a single canonical signer per deployment. The constructor is zero-arg: PoolManager and initial collector are read from ChainConfig under `CONFIG_SIGNER`. Rotating the collector (via `transfer_collector` + `accept_collector`) does not affect ChainConfig lookups. Conversely, rotating the canonical signer requires a redeploy of SafeSwap — acceptable because ChainConfig governance can re-sign under a fresh key reference when needed.

---

## Coverage gaps still open

- **Donate invariants** — fuzz tests are in place; a handler-driven invariant for donate (e.g., total donated equals sum of fundings) is still missing.
- **`creation_block == block.number` boundary** — enforced by BondRoute, not SafeSwap. Best covered via a mainnet-fork or canonical-BondRoute integration test, not a unit test in this repo.
- **Unknown selector graceful settle** — `revert UnknownSelector(selector)` is asserted on-chain, but no test confirms BondRoute treats this as "graceful settle, refund stake" rather than `PossiblyBondFarming`. Cross-system test.
- **Native-ETH e2e under a realistic BondRoute** — present tests confirm SafeSwap's settle path works end-to-end against real V4, but `MockBondRoute` forwards native from its own balance instead of escrowing the user's ETH. A mainnet-fork test against the canonical BondRoute would confirm the user-escrow side.

## Coverage gaps resolved

- **Donate fuzz** — `testFuzz_donate_executes_for_arbitrary_split` and `testFuzz_donate_executes_for_one_sided_split`.
- **Constraint-delay values** — `test_quote_call_*_returns_correct_execution_delays` now covers all five action types.
- **CREATE2 hook-flags smoke test** — `test_constructor_reverts_if_hook_address_has_wrong_flags`.
- **Native-ETH end-to-end execution** — three real-pool tests confirm ETH→ERC20 swap, ERC20→ETH swap, and ETH-side add/remove liquidity all settle correctly.

---

## Test surface — strengths

- All four V4 hook callbacks gate on both `msg.sender == PoolManager` and the transient `_is_hook_callback_allowed` flag, which is now scoped to a single PoolManager operation rather than the entire unlock window. Both rejection and acceptance paths are tested, including an adversarial-token reentrancy regression (`ReentrantProtectedContext.t.sol`).
- `unlockCallback` rejects non-PoolManager callers and dispatches all five actions; invalid action byte panics.
- `Collector` two-step transfer (`transfer_collector` → `accept_collector`) and non-collector rejection both tested. Zero-address transfer is the documented cancel path.
- Direct-pool attack vectors (`DirectSwapAttacker`, `DirectDonateAttacker`) confirmed rejected against a real V4 PoolManager.
- User-isolation proven: user A's position at any `(pool, tick_lower, tick_upper)` is untouchable by user B operating at the exact same range, because the V4 salt is the user address itself.
- Live Uniswap V4 PoolManager is exercised via `ForceCompileV4.PoolManagerDeployer` for execution, fee math, and stake-quotation tests.
- Liquidity-bond stake is slot0-normalized across both sides of the pair, denominated in token0. Dust-input `(1 wei, 1 ether)` and one-sided range-order configurations both yield non-zero stake.
- Constructor rejects deployment at any address whose low 14 bits don't equal `0x0AA0`, catching mis-mined hooks before the first pool init.
- Seven invariants over 32 runs × 2,048 calls each; eight donate-flow fuzz/property tests.

---

## Pre-deployment checklist

1. [ ] **Replace the `CONFIG_SIGNER` placeholder in `src/Definitions.sol`** with the canonical SafeSwap signer for the target chain. The `// ***TODO***  -  Fix before deployment!` marker must be gone before a deploy commit is tagged.
2. [ ] Verify ChainConfig contract is deployed at `0x5Afec0de00EB1c5323C7faA110f67499F744467b` on the target chain.
3. [ ] Write the `uniswap_v4/pool_manager` ChainConfig entry under the `CONFIG_SIGNER` keyspace, pointing at the canonical Uniswap V4 PoolManager for the target chain.
4. [ ] Write the `safeswap/initial_collector` ChainConfig entry under the `CONFIG_SIGNER` keyspace, pointing at the initial fee collector.
5. [ ] Verify BondRoute is deployed at `0xb01d00000000440215e86e0A436f9b59FeB2F14a` on the target chain.
6. [ ] Add a CREATE2 deploy script that mines a hook address satisfying `address & 0x3FFF == 0x0AA0`. The constructor will revert otherwise — smoke-test it.
7. [ ] Pin `foundry.toml` `optimizer_runs` to the largest value that keeps SafeSwap runtime under 24,576 bytes, then commit.
8. [ ] Document M-2 / D-2 (LP custody depends on BondRoute) and D-3 (no FoT/rebasing support) in user-facing docs.
9. [ ] Run `forge test -vvv` on the exact deployment commit; archive the output.
10. [ ] External security audit, with attention to: BondRoute integration semantics, normalized-stake math, native-ETH end-to-end against the real BondRoute escrow, and the dust-stake bump for low-decimal tokens.
11. [ ] Mainnet-fork simulation: end-to-end swap / add / remove against forked V4 + the real BondRoute deployment — especially the native-ETH path.
12. [ ] Verify hook source on Etherscan / Sourcify immediately after deploy.

---

## Overall

The codebase is small, well-structured, and reads cleanly. Access control is airtight: every V4 hook callback gates on both PoolManager identity and the per-operation `_is_hook_callback_allowed` flag, BondRoute is the only path into protected functions, and direct-pool attack vectors are tested and rejected. Liquidity-bond stake is slot0-normalized across both legs; swap-exact-input slippage protects the user's net receipt; swap-exact-output delivers the requested amount exactly. The constructor enforces the V4 hook permission flags before any pool can be initialized. Policy constants live in a single `Definitions.sol`, and Uniswap V4 primitives are referenced canonically (no local hardcoded mirrors of `MIN/MAX_SQRT_PRICE`, `SQRT_PRICE_1_1`, or `DYNAMIC_FEE_FLAG`).

All medium/low items are now documented design choices or operational requirements the deployer can resolve. No outstanding code-level blockers.

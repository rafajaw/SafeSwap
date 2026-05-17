# SafeSwap Pre-Deployment Review

## Status

- **Build:** SafeSwap runtime = 23,286 bytes (1,290 B under the EIP-170 cap, with `optimizer_runs = 10_000`).
- **Tests:** 202/202 passing across 15 suites.
- **Scope:** `src/SafeSwap.sol`, `src/User.sol`, `src/Collector.sol`, `src/UniswapHook.sol`, `src/libraries/*`, `src/integrations/BondRouteProtected.sol`, `src/integrations/IChainConfig.sol`, plus the `test/SafeSwap/` suites.

---

## Deployment runbook

Operational requirements that must be true at or before deployment. Not security findings, but the deployment fails or behaves incorrectly without them.

1. **ChainConfig is deployed at `0x5Afec0de00EB1c5323C7faA110f67499F744467b`** on the target chain. The constructor reads from this canonical address; if no code is present, every read reverts.

2. **ChainConfig contains `v4.pool_manager.address`** under the deployer's signer keyspace, set to the canonical Uniswap V4 PoolManager for the target chain. Otherwise the constructor reverts with `InvalidPoolManager(0x0)`.

3. **BondRoute is deployed at `0xb01d00000000440215e86e0A436f9b59FeB2F14a`** on the target chain. The canonical address is baked into `BondRouteProtected.sol`. If no code is present, the constructor's `BondRoute.announce_protocol(...)` reverts.

4. **CREATE2 hook-address mining.** Uniswap V4 requires the hook address to encode permission flags in its low 14 bits. SafeSwap needs `BEFORE_SWAP | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_DONATE = 0x0AA0`. There is no deploy script in this repository; one must be added before mainnet. Without it, `PoolManager.initialize` rejects any pool using the deployed hook with `HookAddressNotValid`.

5. **`initial_collector` parameter has two roles.** The constructor passes the same address to `Collector(initial_collector)` and to `UniswapHook(config_signer)`. The deployer must control both the fee withdrawal role and the ChainConfig signing key for that signer. Choose a multisig or EOA accordingly.

---

## Findings

### Medium

**M-1: PoolManager identity is only validated by interface shape**

`UniswapHook._is_valid_pool_manager` checks `protocolFeeController()`, `extsload(bytes32[])`, and `supportsInterface(ERC6909)`. Any contract implementing those three responses passes. The real guarantee that the configured address is *the* canonical V4 PoolManager comes from trust in the ChainConfig signer at deploy time. Verify off-chain that the configured PoolManager matches Uniswap's canonical deployment for each chain.

**M-2: LP custody depends on BondRoute remaining functional**

Liquidity positions are owned by the hook contract under salts derived from `(user, user_supplied_salt)`. The only path to extract them is `remove_liquidity`, which requires a BondRoute bond. If BondRoute ever ceases to function — or if SafeSwap removes `remove_liquidity` from `BondRoute_get_protected_selectors` — LPs are stranded. This is the documented BondRoute integration property, not a bug. Surface it in user-facing docs and consider an off-chain getter so users can inspect their positions independently of BondRoute.

**M-3: On-chain constraint re-validation is structurally a tautology**

`BondRouteProtected.BondRoute_validate` calls `BondRoute_quote_call` with the user's actual stake and fundings as the *preferred* values, then validates the returned constraints against the same context. Because SafeSwap's `quote_call` derives `min_stake` and `min_fundings` from those preferred values, the stake and funding checks always succeed for honest input. The only constraints independently enforced are the timing ones (`MIN_EXECUTION_DELAY_IN_BLOCKS`, `MAX_*_EXECUTION_DELAY`) against `block.number` / `block.timestamp`. Real security comes from BondRoute's commit–reveal matching the user-revealed call. Anyone auditing the validation should understand this.

**M-4: Position salt couples LP custody to a stable user address**

`SafeSwapCommon._position_salt(user, salt) = keccak256(user, salt)`. Account-abstraction wallets and relayers that delegate differently per bond must ensure `ctx.user` always reflects the intended beneficiary, otherwise positions are inaccessible from the user's wallet view. The canonical BondRoute is expected to deliver "the user who created the bond" semantics — confirm this matches the deployed contract.

### Low

**L-1:** `Collector.withdraw_fees` is collector-only and reads balance before transfer. A re-entrant recipient on the second call sees `balance <= 1` and returns zero. Safe by ordering without an explicit guard.

**L-2:** `receive()` accepts ETH from anyone. Anyone can pre-fund the hook with ETH; the collector withdraws it. No harm.

**L-3:** `withdraw_fees` keeps 1 wei dust to avoid the 0→nonzero SSTORE penalty on the next fee collection. Intentional.

**L-4:** Swap stake rounds down (`amount * 1 / 100`). Tiny-amount swaps get effectively free MEV protection. Acceptable.

**L-5:** SafeSwap emits no operation-level events for swap / liquidity / donate. Indexers must derive these from Uniswap V4 `PoolManager` events. Consider one summary event per protected op.

**L-6:** `transfer_collector(address(0))` is silently a "cancel" — pending collector is cleared and no one can accept. Document or treat as a distinct path.

**L-7:** Swap libs set `sqrtPriceLimitX96` to `MIN_SQRT_PRICE_LIMIT` / `MAX_SQRT_PRICE_LIMIT` (= absolute bound ± 1). In-pool slippage is "no limit"; slippage is enforced solely via `minimum_amount_out` / `maximum_amount_in`. Standard pattern.

**L-8:** `AddLiquidityLib` reverts a one-sided position mismatch with `SlippageExceeded({amount_received: 0, ...})`, but the user is *depositing*, not receiving. Cosmetic — rename the error field or introduce a dedicated `OneSidedDepositMismatch`.

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

LP custody, swap execution, and donate flows all hinge on BondRoute. If the canonical BondRoute is paused or migrated, SafeSwap users have no fallback path. Surface this risk in user-facing docs and consider an off-chain getter so users can inspect their positions independently.

---

## Coverage gaps worth filling

- **Donate fuzz / invariants** — only three happy-path donate tests today.
- **Fee-on-transfer / rebasing tokens** — every funding flow assumes 1:1 `transferFrom`. Decide whether such tokens are in scope; if not, document.
- **Native ETH end-to-end execution** — structures with `NATIVE_TOKEN` are tested for shape, but no real-pool path exercises a swap / add / remove with `address(0)`.
- **Constraint timing boundaries** — no explicit test for `creation_block == block.number` triggering `EXECUTION_TOO_SOON`, or the exact `MAX_*_EXECUTION_DELAY` boundary.
- **Unknown selector graceful settle** — `revert UnknownSelector(selector)` is asserted on-chain, but no test confirms that BondRoute treats this as "graceful settle, refund stake" rather than `PossiblyBondFarming`.
- **CREATE2 hook-address mining smoke test** — no test simulates a wrong-flags deployment to confirm `PoolManager.initialize` rejects it.

---

## Test surface — strengths

- All four V4 hook callbacks gate on both `msg.sender == PoolManager` and the transient `_is_protected_context` flag. Both rejection and acceptance paths are tested.
- `unlockCallback` rejects non-PoolManager callers and dispatches all five actions; invalid action byte panics.
- `Collector` two-step transfer (`transfer_collector` → `accept_collector`) and non-collector rejection both tested.
- Direct-pool attack vectors (`DirectSwapAttacker`, `DirectDonateAttacker`) confirmed rejected against a real V4 PoolManager.
- `_position_salt` user-isolation proven: user A's position is untouchable by user B sharing the same `salt` parameter.
- Live Uniswap V4 PoolManager is exercised via `ForceCompileV4.PoolManagerDeployer` for execution, fee math, and stake-quotation tests.
- Liquidity-bond stake is slot0-normalized across both sides of the pair, denominated in token0. Dust-input `(1 wei, 1 ether)` and one-sided range-order configurations both yield non-zero stake.
- Seven invariants over 32 runs × 2,048 calls each.

---

## Documentation drift

- `CLAUDE.md` references `src/BondRouteProtected.sol` and `src/SafeSwapHook.sol` — actual paths are `src/integrations/BondRouteProtected.sol` and `src/UniswapHook.sol`.
- `README.md` claims "180 tests across 14 suites" — current is 201 tests across 15 suites.
- `foundry.toml` `optimizer_runs = 10_000` is provisional headroom for in-flight changes. Pin to the maximum value that keeps SafeSwap runtime under 24,576 bytes once the code is final.

---

## Pre-deployment checklist

1. [ ] Verify ChainConfig contract is deployed at `0x5Afec0de00EB1c5323C7faA110f67499F744467b` on the target chain.
2. [ ] Write the `v4.pool_manager.address` ChainConfig entry under the deployer's signer keyspace, pointing at the canonical Uniswap V4 PoolManager for the target chain.
3. [ ] Verify BondRoute is deployed at `0xb01d00000000440215e86e0A436f9b59FeB2F14a` on the target chain.
4. [ ] Add a CREATE2 deploy script that mines a hook address whose low 14 bits equal `0x0AA0`. Smoke-test by initializing a throwaway pool.
5. [ ] Decide the `initial_collector` address. It also functions as the ChainConfig signer at deploy time.
6. [ ] Pin `foundry.toml` `optimizer_runs` to the largest value that keeps SafeSwap runtime under 24,576 bytes, then commit.
7. [ ] Document M-2 / D-2 (LP custody depends on BondRoute) in user-facing docs.
8. [ ] Update `CLAUDE.md` paths and `README.md` test counts.
9. [ ] Run `forge test -vvv` on the exact deployment commit; archive the output.
10. [ ] External security audit, with attention to: BondRoute integration semantics and the normalized-stake math.
11. [ ] Mainnet-fork simulation: end-to-end swap / add / remove against forked V4 + the real BondRoute deployment.
12. [ ] Verify hook source on Etherscan / Sourcify immediately after deploy.

---

## Overall

The codebase is small, well-structured, and reads cleanly. Access control is airtight: every V4 hook callback gates on both PoolManager identity and the transient protected-context flag, BondRoute is the only path into protected functions, and direct-pool attack vectors are tested and rejected. Liquidity-bond stake is slot0-normalized across both legs; swap-exact-input slippage protects the user's net receipt; swap-exact-output delivers the requested amount exactly.

What remains is a mix of operational requirements (the deployment runbook) and a handful of medium/low items worth deciding consciously. None of them block deployment if the team makes informed choices.

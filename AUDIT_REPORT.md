# SafeSwap Audit Report

Date: 2026-05-22

This report is the deployment-pinned audit artifact for the current SafeSwap repository state. It replaces the prior draft review files and records the current manual/static-analysis status, test evidence, unresolved deployment blockers, and operational assumptions.

## Scope

Reviewed in scope:

- `src/SafeSwap.sol`
- `src/BondRouteIntegration.sol`
- `src/User.sol`
- `src/Collector.sol`
- `src/UniswapHook.sol`
- `src/Definitions.sol`
- `src/libraries/*`
- SafeSwap test suites under `test/SafeSwap/`
- Integration touchpoints with Uniswap V4, ChainConfig, and BondRoute

Out of scope:

- Mainnet-fork validation against live target-chain ChainConfig, BondRoute, and Uniswap V4 deployments
- Full formal verification of the complete stateful protocol across BondRoute, Uniswap V4 PoolManager, arbitrary ERC20s, and target-chain deployment state

## Verification

Commands run from repository root:

```bash
forge build
forge test
forge build --sizes
slither . --filter-paths 'lib/|test/'
forge test --root lib/BondRoute
slither . --filter-paths 'lib/|test/' # from lib/BondRoute
forge build test/formal/SafeSwapArithmeticSpec.sol test/formal/SafeSwapFormalHarness.sol
solc --base-path . --evm-version cancun --model-checker-engine chc --model-checker-targets assert,overflow,underflow --model-checker-show-proved-safe --model-checker-show-unproved --model-checker-timeout 20000 test/formal/SafeSwapArithmeticSpec.sol
```

Results:

- `forge build`: passed.
- `forge test`: passed, 228 tests across 18 suites, 0 failed, 0 skipped.
- `forge build --sizes`: `SafeSwap` runtime size is 21,988 bytes, leaving 2,588 bytes under the EIP-170 24,576-byte runtime limit. Initcode size is 24,050 bytes.
- `slither . --filter-paths 'lib/|test/'`: completed analysis and exited non-zero because findings were emitted. Slither analyzed 50 contracts with 100 detectors and reported 124 results before triage.
- `forge test --root lib/BondRoute`: passed, 384 tests across 17 suites, 0 failed, 0 skipped.
- `slither . --filter-paths 'lib/|test/'` from `lib/BondRoute`: passed, 58 contracts analyzed, 0 results.
- `forge build test/formal/SafeSwapArithmeticSpec.sol test/formal/SafeSwapFormalHarness.sol`: passed.
- Solidity SMTChecker with Z3 proved all assertions and selected overflow/underflow checks in `test/formal/SafeSwapArithmeticSpec.sol` under explicit Uniswap V4 static-fee and delta bounds.

## Deployment Status

Not ready for production deployment until the explicit blockers below are closed.

### Blockers

1. `CONFIG_SIGNER` is still a placeholder.

   `src/Definitions.sol` currently sets:

   ```solidity
   address constant CONFIG_SIGNER = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF; // ***TODO*** - Fix before deployment!
   ```

   Replace this with the canonical SafeSwap protocol ChainConfig signer for the target chain before tagging a deploy commit.

2. No deployment artifact in this repository proves CREATE2 hook-address mining.

   SafeSwap requires the Uniswap V4 hook permission bits for `beforeSwap`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, and `beforeDonate`. The constructor calls `Hooks.validateHookPermissions`, so a wrong address fails fast, but the deployment process still needs a pinned script/output proving the mined address satisfies the required low-bit pattern.

3. Target-chain dependency addresses are not pinned in this repository.

   Before deployment, pin and independently verify:

   - ChainConfig at `0x5Afec0de00EB1c5323C7faA110f67499F744467b`
   - ChainConfig entry `uniswap_v4/pool_manager` under `CONFIG_SIGNER`
   - ChainConfig entry `safeswap/initial_collector` under `CONFIG_SIGNER`
   - BondRoute at `0xb01d00000000440215e86e0A436f9b59FeB2F14a`
   - The canonical Uniswap V4 PoolManager for the target chain

4. Mainnet-fork deployment simulation is still missing.

   Current tests include real local PoolManager integration and canonical local BondRoute coverage, but not a target-chain fork using the live ChainConfig/BondRoute/PoolManager deployment set.

## Slither Triage

### Medium: PoolManager Identity Is Shape-Checked, Not Proven

`UniswapHook._is_valid_pool_manager` checks for code, `protocolFeeController()`, `extsload(bytes32[])`, and ERC-6909 interface support. This catches trivial misconfiguration but does not prove the configured address is the canonical Uniswap V4 PoolManager.

Impact: a compromised or incorrect ChainConfig signer can point SafeSwap at a look-alike contract.

Status: accepted operational dependency. Deployment must verify the configured PoolManager address off-chain against canonical Uniswap V4 deployments for each target chain.

### Medium: BondRoute Is a Critical Availability Dependency

User-facing swap, liquidity, and donate flows are BondRoute-protected. Liquidity positions are owned by the hook contract under the V4 salt `bytes32(uint160(user))`; extraction requires SafeSwap `remove_liquidity`, which requires BondRoute.

Impact: if the canonical BondRoute deployment is unavailable, incompatible, or no longer recognizes SafeSwap selectors, LP withdrawal paths can be unavailable.

Status: accepted protocol architecture. Surface this dependency in user-facing docs and deployment runbooks.

### Medium: LP Custody Depends on Stable `ctx.user` Semantics

V4 position ownership is keyed by the hook plus salt `bytes32(uint160(ctx.user))`. Account-abstraction wallets, relayers, and delegated execution setups must ensure BondRoute passes the intended beneficiary as `ctx.user` consistently.

Impact: positions can accrue under an address the human user does not expect if upstream identity semantics differ.

Status: accepted integration risk. Confirm this against the exact BondRoute deployment before launch.

### Informational: Static Fee Validity Belongs to V4

SafeSwap rejects Uniswap V4 dynamic-fee pools in every quote path, but it does not explicitly validate the full static-fee bound `fee <= LPFeeLibrary.MAX_LP_FEE` before execution. Uniswap V4's PoolManager rejects invalid static fees for real pools, so deployable pools cannot exist above the 100% static-fee maximum. However, SafeSwap's exact-output gross-up math and exact-input fee split are only formally overflow/underflow-safe under the valid V4 fee-domain assumption.

Impact: with a malformed `PoolInfo.fee`, calls revert rather than settle successfully. This is not a fund-loss path against canonical V4 pools.

Status: accepted protocol boundary. SafeSwap is a V4 hook/gate and should not duplicate V4's static-fee validity rules; it only rejects dynamic-fee pools because those are outside SafeSwap's supported policy surface.

### Low: Hook Callback Allowance Reentrancy Shape

Slither reports `UniswapHook.unlockCallback` writes `_is_hook_callback_allowed = false` after external library calls.

Triage: the allowance is transient, is enabled immediately before dispatch, and is consumed in each actual V4 hook callback through `_consume_hook_callback_allowance`, which clears it before returning. Regression coverage exists for adversarial-token reentrancy. The final write after dispatch is defensive cleanup.

Status: no code change required based on current evidence. Keep adversarial-token regression tests in the deployment test gate.

### Low: Collector Native Withdrawal Event After External Call

Slither reports an external native transfer in `Collector.withdraw_fees` before emitting `FeesWithdrawn`.

Triage: only the current collector can call `withdraw_fees`; `withdraw_amount` is derived before the call; a reentrant recipient only re-enters as `msg.sender == recipient`, not as the collector, unless the collector deliberately sets itself to the recipient contract. If the collector is a contract and intentionally re-enters, the function still reads current balance and leaves 1 wei dust.

Status: accepted. Operationally, use a hardened multisig or controlled collector contract.

### Informational: `transfer_collector(address(0))`

Slither reports missing zero-address validation on `Collector.transfer_collector`.

Triage: `address(0)` is the documented cancellation path for an outstanding collector nomination. `accept_collector` cannot be called by the zero address.

Status: intentional.

### Informational: Uninitialized `Hooks.Permissions` Fields

Slither reports the local `permissions` struct in `UniswapHook.constructor` as partially uninitialized.

Triage: only the required permission booleans are set to `true`; all other booleans intentionally remain Solidity-zero-initialized as `false`.

Status: intentional.

### Informational: Unused Returns

Slither reports ignored return values from `PoolManager.unlock`, V4 `settle`, `modifyLiquidity`, `StateLibrary.getSlot0`, signing-info helpers, and tuple destructuring.

Triage: the ignored values are either intentionally unnecessary, partially destructured, or protected by downstream state changes/reverts. No unsafe unchecked external ERC20 return was identified in project code; fee withdrawal uses OpenZeppelin `trySafeTransfer`.

Status: accepted.

## Vendored Dependency Audit

The dependency review focused on vendored code that is either directly imported by SafeSwap production contracts or security-critical to SafeSwap deployment:

- `lib/BondRoute/src/*`
- `lib/BondRoute/src/integrations/BondRouteProtected.sol`
- `lib/BondRoute/src/utils/*`
- `lib/ChainConfig/src/*`
- `lib/ChainConfig/src/integrations/IChainConfig.sol`
- Directly imported Uniswap V4 interfaces, types, and libraries under `lib/v4-core/src`
- Directly imported OpenZeppelin primitives: `IERC20`, `SafeERC20`, `IERC165`, `ECDSA`, `EIP712`, `IERC1271`

BondRoute was reviewed line-by-line for the SafeSwap-relevant trust boundary:

- `create_bond` validates sentineled commitment hashes, stake semantics, and native/ERC20 stake handling before storing bond state.
- `_execute_bond_internal` rejects same-block execution, enforces max lifetime, validates execution shape, sets transient funding context only around the protocol call, clears context before refunds, and marks terminal bond status before user-controlled refund transfers.
- `transfer_funding` authenticates the executing protocol through the transient context hash, consumes stake/native held funds first, updates remaining funding context, and blocks unrelated reentrant entry through the lock.
- `BondRouteProtected` validates caller identity, validates timing/stake/funding constraints, appends `BondContext`, and delegatecalls protected selectors with `msg.sender` preserved as BondRoute.
- `ValidationLib` rejects unsupported protocol/selectors, duplicate/zero fundings, malformed selector-array returns, gas-starved selector queries, transfer-failure bond-farming patterns, and malformed custom EIP-712 type strings.
- `Storage` packs bond state into one slot keyed by commitment hash plus stake token/amount, preventing griefing by creating the same commitment under a different stake.

No SafeSwap-blocking issue was found in BondRoute. Its own test suite and Slither pass are clean.

ChainConfig was reviewed as a signer-authenticated registry:

- Writes are isolated by signer namespace.
- `write_config_as` verifies EIP-712/EIP-1271 authorization before writing under the signer namespace.
- Writes reject empty configs, wrong chain id, future timestamps, stale timestamps, empty keys, and keys over 32 bytes.
- Reads are type-gated by stored metadata, so stale values from prior value types are unreachable after a type change.
- The canonical consumer interface pins `CHAINCONFIG_ADDRESS` to `0x5Afec0de00EB1c5323C7faA110f67499F744467b`.

Standalone `lib/ChainConfig` tests and Slither could not be run from inside the submodule because its nested dependencies are not installed in `lib/ChainConfig/lib/`. Root SafeSwap compilation succeeds through root remappings and uses the ChainConfig consumer interface. Before deployment, either install ChainConfig's nested submodules and run its suite directly, or pin an upstream ChainConfig release/test artifact.

Uniswap V4 and OpenZeppelin were not re-audited line-by-line as complete upstream projects. SafeSwap relies on pinned, standard library behavior for:

- V4 `BalanceDelta` int128 amount bounds.
- V4 PoolManager static-fee validation and hook-callback semantics.
- V4 `FullMath`, `TickMath`, `SqrtPriceMath`, `StateLibrary`, and pool-key/currency types.
- OpenZeppelin safe ERC20 and signature utilities.

Deployment should pin the exact upstream commits already present in `git submodule status` and treat any dependency bump as audit-significant.

## Formal Verification

Added formal artifacts:

- `test/formal/SafeSwapFormalHarness.sol`: imports the real `SafeSwapCommon` library and exposes assertion-bearing wrappers for fee and stake properties. This compiles under Foundry and verifies the formal harness remains linked to current production code.
- `test/formal/SafeSwapArithmeticSpec.sol`: solver-friendly arithmetic model of SafeSwap protocol-fee, exact-output gross-up, and swap-stake math.

The SMTChecker run with Z3 proved:

- Swap stake multiplication cannot overflow.
- For nonzero swap funding, stake is nonzero and bounded by funding amount.
- Zero swap funding bumps stake to exactly 1 wei.
- Under `amount_out <= uint128(int128.max)` and `pool_fee <= 1_000_000`, protocol-fee multiplication does not overflow, user-output subtraction does not underflow, and `protocol_fee + user_amount == amount_out`.
- For zero output and valid V4 static fees, protocol fee and user output are both zero.
- Under the same valid-fee and V4 delta bounds, exact-output gross-up multiplication does not overflow, fee-complement subtraction does not underflow, and grossed-up pool output is at least the target user output.

An unconstrained first pass found expected counterexamples for arbitrary `uint256 amount_out` and arbitrary `uint24 pool_fee`; those are outside the V4 static-fee and BalanceDelta domains. This is why the final spec encodes the V4-domain assumptions explicitly.

### Informational: Assembly, Low-Level Calls, Boolean Equality, Naming

Slither reports:

- Assembly in EIP-712 hashing helpers.
- Low-level calls in PoolManager shape checks and native fee withdrawal.
- Explicit `== false` boolean comparisons.
- Snake-case function/variable names.

Triage: these match local style and integration needs. No deployment-blocking issue identified.

Status: accepted.

## Resolved Historical Findings

The prior review snapshots contained issues that are now resolved or documented:

- Protected callback context is per-operation and consumed by the actual hook callback.
- Constructor enforces Uniswap V4 hook permission flags.
- Direct native transfers are rejected unless sent by PoolManager or BondRoute.
- Dust swap/liquidity/donate stake is bumped to 1 wei where applicable.
- One-sided liquidity mismatch uses a dedicated error.
- `transfer_collector(address(0))` cancel semantics are documented.
- Exact-output fee gross-up intentionally rounds down by at most dust; this is documented in code.
- Native ETH settlement routes value through the hook and `pool_manager.settle{value: amount}()`.
- V4 test utility dependencies were removed from production code.
- Canonical local BondRoute integration tests cover timing and funding paths.

## Coverage Strengths

- Hook callbacks require both `msg.sender == PoolManager` and a transient per-operation allowance.
- BondRoute is the only entry point for protected user operations.
- Direct PoolManager swap/donate attacks are tested and rejected against a real local V4 PoolManager.
- Collector transfer and fee withdrawal access control are covered.
- Swap exact-input/exact-output slippage and protocol fee accounting are covered.
- Liquidity add/remove user isolation is covered through V4 position salts.
- Native ETH swap and liquidity paths are covered against a real local PoolManager.
- Canonical local BondRoute tests cover same-block rejection, elapsed-time floor, retry behavior, native funding, ERC20 funding, and invalid-bond settlement.
- Fuzz and invariant suites cover fee accounting, protected-context cleanup, hook rejection, collector restrictions, and donate split behavior.

## Remaining Coverage Gaps

- Target-chain mainnet-fork simulation against live ChainConfig, BondRoute, and Uniswap V4 addresses.
- Handler-driven donate invariants tying total donated amounts to fundings across broader stateful sequences.
- External audit of BondRoute integration semantics and target-chain operational deployment.
- Empirical stake-economics calibration by pool depth, volatility, block time, gas cost, and asset class.

## Deployment Checklist

Before deployment:

1. Replace `CONFIG_SIGNER` with the canonical SafeSwap ChainConfig signer.
2. Pin target-chain ChainConfig, PoolManager, BondRoute, and initial collector addresses.
3. Add or pin CREATE2 hook-mining output proving the deployed hook address has the required V4 permission bits.
4. Run `forge build`, `forge test`, `forge build --sizes`, and `slither . --filter-paths 'lib/|test/'` on the exact deploy commit.
5. Run a mainnet-fork simulation for exact-input swap, exact-output swap, add liquidity, remove liquidity, donate, collector withdrawal, and native ETH settlement.
6. Archive bytecode hash, deployed address, constructor behavior, ChainConfig entries, Slither output, test output, and source verification metadata.
7. Document BondRoute availability risk, unsupported fee-on-transfer/rebasing tokens, and PoolManager/ChainConfig trust assumptions for users.
8. Verify source on Etherscan/Sourcify immediately after deployment.

## Conclusion

SafeSwap's current implementation is well covered by local Foundry tests and Slither did not identify an untriaged code-level production blocker. Deployment should remain blocked until the placeholder `CONFIG_SIGNER`, target-chain dependency pinning, CREATE2 hook-mining artifact, and mainnet-fork simulation are completed and archived.

# SafeSwap Deployment Readiness Pass

Date: 2026-05-19

Scope: clean pass over all project-root markdown files, `foundry.toml`, the SafeSwap inheritance chain, action libraries, integrations, and current tests. This file is a go/no-go checklist for moving from code review into setup/deploy work.

## Current Status

SafeSwap is close on code-level mechanics, but it is not ready to enter a real setup/deploy phase until the deterministic deployment artifacts, config signer, deployed-address/fork BondRoute tests, and launch assumptions below are closed.

Verification performed in this pass:

- `forge build --force`: passed.
- `forge test`: passed, 228 tests across 18 suites.
- Runtime size from `forge inspect src/SafeSwap.sol:SafeSwap deployedBytecode`: ~21,897 bytes, about 2,679 bytes below the 24,576 byte EIP-170 limit.
- `slither .`: completed analysis but exited non-zero with dependency/style noise. Direct SafeSwap items were already-known or intentional: collector zero-address cancel semantics, hook allowance reentrancy shape, ignored return values, timestamp windows, and `Hooks.Permissions` memory zero-initialization style.

Repository documentation note:

- `README.md`, `REVIEW.md`, and `INDEPENDENT_REVIEW.md` have been updated to the 228-test / 18-suite status.

## Deployment Model

BondRoute and ChainConfig are deterministic, immutable, unpausable infrastructure. They are intended to live at the same address on every supported EVM chain through CREATE2 deployment via the standard `CREATE2 Deployer Proxy` / Foundry deterministic deployer at `0x4e59b44847b379578588920cA78FbF26c0B4956C`.

If either contract is absent on a future EVM chain where the deterministic deployer is available, anyone can permissionlessly deploy the documented canonical payload to the same address. This is not an operator-governed dependency model.

For deterministic deployments, the resulting address is bound to the deployer address, salt, and init-code hash. Arbitrary bytecode cannot be substituted at the same address under the same deployment recipe. Deployment artifacts should still archive bytecode hashes for audit, explorer, and reproducibility workflows, but the core trust model is the public deterministic recipe.

SafeSwap should follow the same reproducible discipline, with the added Uniswap V4 hook-address requirement:

- deployed hook address must satisfy `address & 0x3FFF == 0x0AA0`;
- deployment artifacts must record the deployer, salt, init code hash, runtime hash, compiler settings, dependency commits, and mined hook-address proof.

## Readiness Verdict

Do not move to setup/deploy until the blockers in this section are complete.

### 1. Replace `CONFIG_SIGNER`

`src/Definitions.sol` still uses the placeholder:

```solidity
0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF
```

Before any deployment candidate:

- Choose the canonical SafeSwap ChainConfig signer.
- Prefer a multisig or hardware-backed signer for production.
- Replace the placeholder and remove the `TODO`.
- Produce a signer-control runbook: who controls it, how rotations work, and how signed ChainConfig writes are archived.

ChainConfig itself is immutable infrastructure; the signer remains the authority for SafeSwap's namespace inside that infrastructure.

### 2. Prove Target-Chain Preconditions

SafeSwap has three external address assumptions:

- ChainConfig at `0x5Afec0de00EB1c5323C7faA110f67499F744467b`.
- BondRoute at `0xb01d00000000440215e86e0A436f9b59FeB2F14a`.
- Canonical Uniswap V4 PoolManager for the target chain.

Before deployment:

- Confirm ChainConfig and BondRoute are deployed at their deterministic addresses, or deploy their documented canonical payloads permissionlessly through the deterministic deployer.
- Confirm the target chain supports required EVM features, including Cancun-era transient storage.
- Verify the Uniswap V4 PoolManager address for the target chain.
- Write ChainConfig keys under `CONFIG_SIGNER`:
  - `uniswap_v4/pool_manager`
  - `safeswap/initial_collector`
- Archive the ChainConfig write transaction hashes, signed payloads, signer address, chain id, and timestamps.

### 3. Add SafeSwap Deployment Tooling

There is no deploy script yet. The deploy phase needs:

- CREATE2 hook miner for `address & 0x3FFF == 0x0AA0`.
- Deployment script that checks ChainConfig, BondRoute, PoolManager, and hook-address flags before attempting SafeSwap construction.
- Constructor-args artifact. Current constructor is zero-arg, but the artifact should explicitly record that.
- Deployment artifact with bytecode hash, runtime hash, deployed address, salt, deployer, compiler version, optimizer settings, `via_ir`, remappings, dependency commits, and target-chain ChainConfig values.
- Immediate Etherscan/Sourcify verification procedure.

### 4. Extend Canonical BondRoute Integration Tests

The suite now includes `test/SafeSwap/CanonicalBondRouteIntegration.t.sol`, which deploys the canonical BondRoute implementation at SafeSwap's baked-in BondRoute address. This closes the first real integration layer for ERC20 execution:

- exact-input execution through canonical BondRoute;
- sentineled `0xCAFFE0` commitment hash layout and rejection for wrong chain/stake token/stake amount;
- ERC20 and native funding pull/accounting with stake returned after successful execution;
- two-ERC20 add-liquidity funding;
- mixed ETH+ERC20 add-liquidity funding;
- BondRoute same-block execution rejection;
- the configured 2-second elapsed-time floor (set via `min_execution_delay_in_seconds` in each action's `BondConstraints`, enforced by BondRoute core);
- retry after an early `PossiblyBondFarming` revert;
- unknown selector settlement as `INVALID_BOND`.

That is not the same as fork-testing the already-deployed singleton on a target chain.

Before setup/deploy:

- Mainnet-fork or target-chain-fork test against the deployed canonical BondRoute address.
- Liquidity and donate execution through canonical BondRoute.
- Real V4 PoolManager fork flow for native ETH exact-input and liquidity execution against the deployed BondRoute singleton.
- Deployed-bytecode parity check between the forked BondRoute singleton and the vendored test dependency.

### 5. Decide LP Custody Story

SafeSwap LP positions are owned by the hook contract and keyed by `bytes32(uint160(ctx.user))`. Removing liquidity requires BondRoute execution.

BondRoute is immutable and unpausable, so the risk is not an operator pause. The real product question is whether users are comfortable with LP withdrawal depending on the BondRoute execution path and on frontends/wallet tooling supporting that path correctly.

Before launch:

- Publish the LP custody model plainly.
- Explain that positions are inspectable through `get_position_info`, but removal still executes through BondRoute.
- Confirm account-abstraction and relayer UX preserves the intended `ctx.user` beneficiary.
- Define a migration story for future SafeSwap versions. A deployed instance cannot remove selectors or add a direct emergency exit without deploying a replacement.
- Decide whether a future version should add an explicit emergency exit or selector gating. That is a product/security tradeoff because direct exits weaken the "all pool operations go through BondRoute" invariant.

### 6. Calibrate Stake Economics

Current constants:

- Swap stake: 1% of input.
- Liquidity/donate stake: 1% of token0-normalized value.
- Minimum bond execution delay: 3 blocks.
- Minimum bond execution delay: 2 seconds, configured via `min_execution_delay_in_seconds` in each action's `BondConstraints` and enforced by BondRoute core's `_validate_timing` (which adds a +1 timestamp-boundary correction so the 2-second floor binds as real elapsed time, not just as a `block.timestamp` delta).
- Maximum bond execution delay: 1 hour.

The block/time split is the right model:

- `MIN_BOND_EXECUTION_DELAY_IN_BLOCKS` models anti-reorg / anti-immediate-copy depth.
- `MIN_BOND_EXECUTION_DELAY_IN_SECONDS` models propagation / copy-after-reveal latency on fast chains.
- `MAX_BOND_EXECUTION_DELAY_IN_SECONDS` models stale-intent expiry.

Do not describe the block delay as a uniform time delay across chains. On Ethereum, 3 blocks is roughly 36 seconds because Ethereum slots are 12 seconds. On faster EVM chains, the same 3-block depth can be only a few seconds or less:

| Chain | Approximate block interval | 3-block delay | SafeSwap launch relevance |
| --- | ---: | ---: | --- |
| Ethereum | 12s | 36s | Primary V4 target; 3 blocks is a reasonable initial anti-reorg depth. |
| Base / OP Stack chains | 2s | 6s | High practical DeFi activity; 3 blocks is shallow as a wall-clock copy-after-reveal barrier. |
| Arbitrum One | 250ms | 0.75s | High practical DeFi activity; 3 blocks should be treated as depth-only, not meaningful wall-clock separation. |
| BNB Smart Chain | ~0.45s after Fermi | ~1.35s | High DEX activity, but 3 blocks is sub-network-latency in many real paths. |
| Polygon PoS | ~2s | ~6s | Relevant EVM liquidity, but not a first SafeSwap target unless V4 and infra assumptions are settled. |
| Solana / Sui / Hyperliquid L1 | chain-specific, non-EVM or non-V4 context | n/a | High activity in some metrics, but not directly deployable as a SafeSwap V4 hook target. |

Use DeFi activity, not TVL alone, to choose launch chains. The relevant ranking inputs are spot DEX volume, active routing/aggregator flow, fee generation, realistic V4 availability, and pool depth. TVL is useful context, but it can over-rank passive lending/staking chains and under-rank high-turnover trading chains.

For copy-after-reveal risk, the attacker learns the victim's intent at the same time the public mempool/searcher set and validators learn it. The attacker must create a fresh bond, wait the block-depth rule, and then execute before the victim, while competing against validators/searchers who can also include the victim's execution. This is probabilistic and should usually be loss-making when the stake is sized correctly, but it is not impossible on very fast chains.

Initial recommendation:

- Keep 3 blocks as an Ethereum-first anti-reorg depth.
- Do not claim that 3 blocks gives the same protection on BNB, Arbitrum, Base, or OP Mainnet.
- Use the 2-second elapsed-time floor instead of inflating `min_delay_in_blocks` just to simulate time.
- The 2-second floor materially improves BNB and Arbitrum copy-after-reveal resistance while preserving the block-depth model for reorg risk.
- Keep the local canonical BondRoute timing tests, and add fork coverage against the deployed singleton on each launch chain.
- Shorten the maximum execution window for swaps if UX allows. A 1-hour window is reasonable for liquidity operations, but swaps are more sensitive to stale market state.

Before launch:

- Build an empirical model by chain, pool depth, volatility, fee tier, gas cost, and expected MEV.
- Decide if 1% is enough for high-value stable, volatile, and long-tail pools.
- Decide if thin pools should be excluded from initial launch because slot0-normalized liquidity stake can be manipulated cheaply.
- Decide whether pool allowlisting belongs in the frontend/indexer only or in a later contract version.
- Produce a public explanation of stake sizing that does not overclaim.

### 7. Define Launch Pools and V4 Compatibility

SafeSwap is a Uniswap V4 hook. It inherits Uniswap V4's token and pool compatibility model rather than defining a separate asset standard. SafeSwap adds BondRoute gating and friendlier user-facing call shapes; it does not add custom accounting for tokens that V4 itself cannot settle safely.

Contract-level policy already rejects dynamic-fee pools. For token behavior, the launch policy should be:

- Support static-fee V4 pools whose tokens behave correctly under V4 PoolManager settlement.
- Do not market SafeSwap as adding support for fee-on-transfer, rebasing, blocklisting, or transfer-hook tokens beyond what V4 supports.
- Treat extremely thin pools as a launch/economics risk because slot0-normalized liquidity stake can be manipulated cheaply.

Before launch:

- Publish an initial supported pool list.
- Document that SafeSwap inherits V4 token-compatibility constraints.
- Make frontend/indexer reject unsupported pools early, before bond creation.

### 8. External Audit and Static Analysis Triage

The code is audit-worthy, but deployment should wait for an external review focused on:

- BondRoute integration semantics.
- V4 unlock/callback behavior.
- Token callback/reentrancy behavior.
- Native ETH settlement against real BondRoute escrow.
- Stake economics and slot0-normalized liquidity stake.
- Hook address mining/deployment invariants.

Static-analysis notes to triage before audit:

- Slither dependency noise from V4 core math and hooks.
- Slither direct warning on `UniswapHook.constructor()` `Hooks.Permissions memory permissions`; this is intentional but conflicts with the house rule against relying on implicit memory zeroing. Consider switching to an explicit struct literal for audit readability.
- Slither direct warning on `Collector.transfer_collector(address(0))`; documented as cancel semantics.
- Slither direct warning on `UniswapHook.unlockCallback` reentrancy; covered by per-operation transient allowance and adversarial token regression, but should be called out in audit notes.
- Slither direct warning on event emission after native fee withdrawal; current balance-read/keep-dust ordering makes repeated extraction unprofitable, but this should remain in the audit packet.

## Security Assumptions to Freeze

These are not bugs if accepted, but they must be explicit before setup/deploy.

### Deterministic Infrastructure

BondRoute and ChainConfig are same-address deterministic deployments. The setup task is to ensure they exist on the target chain, or deploy the documented payloads if absent. This is a reproducibility requirement, not a governance trust requirement.

### ChainConfig Authority

SafeSwap treats ChainConfig entries under `CONFIG_SIGNER` as authoritative. ChainConfig is trustless infrastructure, but SafeSwap's signer controls SafeSwap's config namespace. The constructor shape-checks PoolManager, but a malicious or compromised signer can still point SafeSwap to the wrong PoolManager-like contract.

### BondRoute Correctness

BondRoute is a hard dependency for swaps, add/remove liquidity, and donations. Since it is immutable and unpausable, the assumption is correctness of the BondRoute mechanism and exact integration semantics, not operator availability.

### BondRoute User Semantics

SafeSwap uses `ctx.user` as the LP position discriminator. Account-abstraction wallets, relayers, and batchers must preserve intended-beneficiary semantics. If `ctx.user` differs from the human/user account expected by the UI, positions will appear under a different key.

### PoolManager Canonicality

The on-chain PoolManager validation is intentionally only a shape check. Canonical PoolManager identity must be verified for each target chain and recorded in deployment artifacts.

### Static-Fee Pools Only

Dynamic-fee pools are rejected. Launch, docs, frontend, and indexer must all match that contract-level policy.

### Amount-Based Slippage

Swap `sqrtPriceLimitX96` uses V4 absolute bounds. User protection is via `minimum_amount_out` and `maximum_amount_in`, not a custom in-pool price limit. This is standard router behavior, but frontends must make slippage settings prominent and safe by default.

### Token Behavior

SafeSwap does not introduce a new token-compatibility layer. It inherits V4 PoolManager settlement behavior. The right place to document this is public docs, frontend copy, and launch pool policy; NatSpec can mention that operations target Uniswap V4-compatible pools, but it should not imply SafeSwap has its own independent token-support matrix.

### Emergency Response

There is no in-contract pause or admin rescue. Practical emergency controls are frontend/indexer delisting, public guidance, and redeployment/migration to a new deterministic SafeSwap version.

## Business Assumptions to Validate

### MEV Savings Claims

The README claims SafeSwap eliminates MEV and is 5x-200x cheaper than typical MEV losses. That may be directionally defensible, but before public launch:

- Ground the claim in cited data or soften it.
- Segment by pool type and size.
- Explain that SafeSwap does not protect users from bad slippage settings, oracle mistakes, or tokens/pools outside V4's compatibility assumptions.

### Fee Unit Economics

The protocol fee floor supports stablecoin economics, but the full business model still needs:

- Expected daily volume by launch pool.
- BondRoute overhead and user gas tolerance by chain.
- Collector revenue estimates net of support/ops costs.
- Sensitivity analysis for low-volume launch.

### Launch Scope

A curated launch is materially safer than broad permissionless exposure because stake sizing and token behavior are not uniform.

Recommended initial launch shape:

- One or a few static-fee, deep pools.
- Assets with V4-compatible ERC20 behavior.
- No long-tail or thin pools until stake calibration is validated.
- Clear "unsupported pool" UX before bond creation.

### User Communications

Before launch, publish:

- LP custody explanation: positions are owned by the hook and keyed by user address.
- BondRoute execution-path explanation.
- Deterministic deployment explanation for BondRoute, ChainConfig, and SafeSwap.
- Fee examples for exact-input and exact-output swaps.
- Slippage warning.
- V4 token/pool compatibility notes.
- Incident response and migration policy.

## Setup/Deploy Entry Criteria

Enter setup/deploy only when all are true:

- [ ] `CONFIG_SIGNER` is replaced and documented.
- [ ] Target chain supports required EVM features, including transient storage.
- [ ] ChainConfig and BondRoute exist at deterministic addresses, or their canonical payloads are deployed.
- [ ] Canonical Uniswap V4 PoolManager is verified for the target chain.
- [ ] ChainConfig entries are written and archived.
- [ ] CREATE2 deploy script mines and checks `0x0AA0` flags.
- [ ] Deployment artifact template exists and includes bytecode hash, runtime hash, salt, compiler settings, dependency commits, ChainConfig values, PoolManager, BondRoute, collector, and hook address.
- [ ] Canonical BondRoute fork/deployed-address tests pass, including native ETH escrow.
- [ ] Stake economics document exists for the initial pool list.
- [ ] Initial supported pool/token list exists.
- [ ] Public docs are updated for test count, runtime size, fees, V4 token/pool compatibility, LP custody, deterministic deployment, and BondRoute execution path.
- [ ] Slither output is triaged into dependency noise, accepted design decisions, and any fixes.
- [ ] External audit scope is prepared and includes this file, `REVIEW.md`, and `INDEPENDENT_REVIEW.md`.

## Suggested Order of Work

1. Write deterministic deployment artifact template and ChainConfig signer runbook.
2. Implement CREATE2 deploy/mining script for SafeSwap hook flags.
3. Extend canonical BondRoute coverage to fork/deployed-address tests, native ETH escrow, liquidity, and donate.
4. Produce stake economics and supported-pool policy.
5. Run Slither with a project-specific triage note.
6. Package audit materials.
7. Begin target-chain setup and deployment dry runs.

## Bottom Line

The core SafeSwap implementation is in good shape for an audit candidate. The main remaining risk is launch discipline: deterministic deployment artifacts, correct config signing, canonical PoolManager selection, deployed BondRoute/native-escrow behavior, realistic stake economics, and a clear LP-custody story. Treat those as deployment blockers, not paperwork.


# Project guidelines

First read all *.md files at project root for the LP repricing rebate design — `LVR_DETERRENCE.md` (why / economics),
`REPRICING_REBATE_ADDRESS_CONFIG.md` (architecture: router / NFT / hook / address encoding), and `DYNAMIC_FEE_REBATE_PLAN.md`
(the **binding** mechanism spec; it wins on any conflict) — then foundry.toml, then the solidity files. Read shared
primitives first, then the hook, then each BondRoute-protected entrypoint with its inheritance graph and action libraries:
contracts/Common/Definitions.sol
contracts/Common/Types.sol
contracts/Common/HookAddress.sol
contracts/Common/PoolManagerIntegration.sol
contracts/Common/SafeSwapCommon.sol
contracts/Common/SwapSimulator.sol
contracts/Hook/ISafeSwapHook.sol
contracts/Hook/SafeSwapHookImpl.sol
contracts/Router/SafeSwapRouter.sol
contracts/Router/BondRouteIntegration.sol
contracts/Router/User.sol
contracts/Router/Orchestrator.sol
contracts/Router/HookRegistry.sol
contracts/Router/Treasury.sol
contracts/Router/libraries/ExactInputSwapLib.sol
contracts/Router/libraries/ExactOutputSwapLib.sol
contracts/Nft/SafeSwapNft.sol
contracts/Nft/libraries/ModifyLiquidityLib.sol

## Architecture (LP repricing rebate)

SafeSwap is a canonical BondRoute-protected **router** (swaps + hook registry + treasury) plus a BondRoute-protected
**NFT** (owns the V4 positions, salt = tokenId) plus many permissionlessly-deployed **config hooks** — one EIP-1167 clone of
the `SafeSwapHookImpl` per `(base fee, capture)` profile. Each profile is encoded in the clone's CREATE2 address as
readable BCD (`0xF` fee marker + 3 base-fee digits + `0xC` capture marker + 1 rebate digit, + V4 permission bits), so each
profile yields a distinct V4 PoolId. Pools are **dynamic-fee**: in `beforeSwap` the hook simulates the swap (`SwapSimulator`),
estimates the **repricing surplus** (output valued at the post-swap price minus input paid), and returns
`base fee + capture% × surplus` as a V4 override fee, which accrues path-fairly to the LPs the swap crosses. `capture%` is the
share of surplus paid to LPs (0–90%), **not** a rate on price displacement. No `donate`. The `execute` action libraries are
internal (inlined into the router and NFT); all deploy artifacts sit comfortably under the EIP-170 size limit.

## Operators for reasoning effectively:

**Analytical Operators**
- `deconstruct`: Break into essential components
- `zoom`: Change level of abstraction or scope

**Synthetic Operators**
- `blend`: Combine complementary elements
- `chain`: Link outputs as inputs sequentially

**Optimization Operators**
- `evolve`: Apply incremental refinement
- `constrain`: Apply focused limitation

**Innovation Operators**
- `reverse`: Invert key assumptions or flows
- `revolt`: Reject current framing, start fresh
- `transpose`: Apply proven model from elsewhere
- `seasonalize`: Adapt to temporal cycles

## Context

This is a new system, no backwards compatibility required!

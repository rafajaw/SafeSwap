
# Project guidelines

First read all *.md files at project root (including LVR_DETERRENCE.md and REPRICING_REBATE_ADDRESS_CONFIG.md for the LP repricing rebate design) and then foundry.toml and then read all solidity files in the following order. Read top-down: start at the canonical user entrypoint (SafeSwapRouter), walk up its inheritance graph (BondRouteIntegration → User → Orchestrator + HookRegistry + BondRouteProtected, and orthogonal Treasury), then read the standalone config hook and the action libraries that the unlock callback dispatches into:
contracts/Router/SafeSwapRouter.sol
contracts/Router/BondRouteIntegration.sol
contracts/Router/Treasury.sol
contracts/Router/User.sol
contracts/Router/Orchestrator.sol
contracts/Router/HookRegistry.sol
contracts/Router/Definitions.sol
contracts/Hook/SafeSwapHook.sol
contracts/Nft/SafeSwapNft.sol
contracts/Router/libraries/SafeSwapCommon.sol
contracts/Router/libraries/ExactInputSwapLib.sol
contracts/Router/libraries/ExactOutputSwapLib.sol
contracts/Router/libraries/ModifyLiquidityLib.sol
contracts/Router/libraries/DonateLib.sol

## Architecture (LP repricing rebate)

SafeSwap is a canonical BondRoute-protected router plus a shared LP-position NFT plus many permissionlessly-deployed
SafeSwapHook config instances — one per LP repricing rebate profile. Each rebate profile is encoded in its hook's CREATE2
address (magic byte 0x55, 4-bit profile, V4 permission bits), so each profile yields a distinct V4 PoolId. Pools are
static-fee; when a swap moves the pool price, the router measures the real tick movement and donates a rebate
(`movement_bps × rebate_profile × 1000 / 10_000`, capped) to in-range LPs. The four `execute` action libraries are
external (delegatecall-linked) to keep the router under the EIP-170 size limit.

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

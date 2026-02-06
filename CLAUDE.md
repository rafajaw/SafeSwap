
# Project guidelines

First read all *.md files at project root and then foundry.toml and then read all solidity files in the following order:
src/BondRouteProtected.sol
src/SafeSwapHook.sol
src/libraries/SafeSwapCommon.sol
src/libraries/ExactInputSwapLib.sol
src/libraries/ExactOutputSwapLib.sol
src/libraries/AddLiquidityLib.sol
src/libraries/RemoveLiquidityLib.sol

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
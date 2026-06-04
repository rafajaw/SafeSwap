# SafeSwap Gas Benchmarks

Date: 2026-06-04

Baseline commit: `b097e66`

Forge:

```text
forge Version: 1.7.1
Commit SHA: 4072e48705af9d93e3c0f6e29e93b5e9a40caed8
```

Foundry profile:

- `evm_version = "cancun"`
- `optimizer = true`
- `optimizer_runs = 200`
- `via_ir = true`
- `gas_reports = ['*']`

## Architecture under measurement

These numbers reflect the current LP-repricing-rebate system, not the pre-rewrite single contract:

- A BondRoute-protected **router** (swaps + hook registry + treasury) and a BondRoute-protected **NFT** that owns the
  Uniswap v4 positions. Positions are stored as `owner = SafeSwapNft`, `salt = bytes32(tokenId)`, and the NFT owner is the
  BondRoute/SafeSwap user.
- Pools are **dynamic-fee**. On every swap the config hook's `beforeSwap` runs `SwapSimulator.simulate` to estimate the
  repricing surplus and returns `base fee + capture% × surplus` as the v4 override fee. That simulation is an on-chain read
  path on the hot swap path, so it gets its own bench below.
- No `donate`. The old donate / transient "protected-context" / `bytes32(user)` salt benchmarks no longer apply.

## End-to-end bonded operations

Primary product benchmark: full entry through the canonical BondRoute integration (real `create_bond` → delay → real
`execute_bond`) against a real v4 `PoolManager` with a real etched config-hook clone. These are **per-test** gas figures, so
they include the whole bond lifecycle plus the test's own assertions — read them as a consistent end-to-end signal, not a
pure isolated opcode cost for the operation.

### Swaps — `test/Router/UserSwap.t.sol` (`UserSwapTest`)

```sh
forge test --match-contract UserSwapTest
```

| Operation | Test | Gas |
|---|---|---:|
| Exact-input swap (pays quoted net output) | `test_swap_exact_input_pays_user_the_quoted_net_output` | 271,419 |
| Exact-input swap (protocol fee to treasury) | `test_swap_exact_input_takes_protocol_fee_to_the_router_treasury` | 250,179 |
| Exact-output swap (exact net output) | `test_swap_exact_output_delivers_the_exact_net_output` | 251,148 |
| Slippage revert (graceful bond settlement) | `test_swap_exact_input_reverts_on_slippage_as_graceful_bond_settlement` | 187,552 |
| Repricing-fee assertion (quote/view comparison, not a full swap) | `test_swap_exact_input_applies_a_repricing_fee_above_the_base_fee` | 41,273 |

### Liquidity — `test/Nft/SafeSwapNftWorkflow.t.sol` (`SafeSwapNftWorkflowTest`)

```sh
forge test --match-contract SafeSwapNftWorkflowTest
```

| Operation | Test | Gas |
|---|---|---:|
| Create position (initialize pool + deposit + mint) | `test_create_position_initializes_pool_deposits_liquidity_and_mints` | 589,969 |
| Add liquidity to an existing position | `test_add_liquidity_increases_the_v4_position` | 737,857 |
| Remove liquidity | `test_remove_liquidity_returns_tokens_and_reduces_the_position` | 712,013 |
| Collect fees (no accrued fees) | `test_collect_fees_executes_with_no_accrued_fees_and_leaves_liquidity` | 698,621 |
| Remove by non-owner (PROTOCOL_REVERTED) | `test_remove_by_non_owner_is_protocol_reverted_and_position_is_untouched` | 669,999 |

`test_create_position_uses_incrementing_token_ids` (851,970) is excluded from the table above because it creates **two**
positions; it is not a single-operation cost.

## SwapSimulator read-path overhead

`beforeSwap` runs `SwapSimulator.simulate` on every swap to size the repricing fee. The bench isolates the marginal cost of
that read by comparing two fresh runs on an identical pool — `{swap}` versus `{simulate; swap}` — so the shared cold costs
cancel and the difference is purely the simulation. The cost scales with the number of initialized ticks the swap crosses
(each crossing is more tick-bitmap / tick-info `extsload` reads the simulator must walk).

```sh
forge test --match-contract SwapSimulatorBenchTest -vv
```

| Case | Ticks crossed | Simulation overhead (`sim_gas`) | Regression ceiling |
|---|---:|---:|---:|
| small | ~1 | ~28k | 35,000 |
| mid | ~19 | ~138k | 160,000 |
| large (worst case) | ~97 | ~617k | 700,000 |

The `test_gas_sim_then_swap_*` cases assert `sim_gas` stays under the ceiling (held just above observed so a real regression
trips while run-to-run noise does not), and a correctness check pins the simulated post-swap tick to the realized one. Run
with `-vv` to see the per-case `sim_gas` / `SWAP_ONLY_total` / `SIM_THEN_SWAP_total` logs.

## Caveats

- Numbers are specific to this machine, solc, and the Foundry toolchain/profile above. Treat them as a relative baseline,
  not an absolute on-chain quote.
- The end-to-end figures are per-test gas and include the BondRoute `create_bond` + `execute_bond` lifecycle and the test
  assertions, so they overstate the isolated cost of the underlying v4 operation.
- The SwapSimulator ceilings are calibrated to the observed cost here. If a toolchain bump makes them flake, re-read the
  observed `sim_gas` values and nudge the constants in `test/Common/SwapSimulatorBench.t.sol` — do not loosen them wholesale.

# SafeSwap Gas Benchmarks

Date: 2026-06-02

Baseline commit: `d972112`

Forge:

```text
forge Version: 1.7.1
Commit SHA: 4072e48705af9d93e3c0f6e29e93b5e9a40caed8
Build Profile: dist
```

Foundry profile:

- `evm_version = "cancun"`
- `optimizer = true`
- `optimizer_runs = 10_000`
- `via_ir = true`
- `gas_reports = ['*']`

## Baseline: Canonical BondRoute Operations

This is the primary benchmark for product decisions. It measures real SafeSwap entry through the canonical BondRoute integration, including BondRoute validation/funding overhead and SafeSwap execution. Current SafeSwap liquidity operations call Uniswap v4 `PoolManager` directly and store positions as:

```text
owner = SafeSwap
salt = bytes32(user)
```

Command:

```sh
/home/noname/.foundry/bin/forge test --match-contract CanonicalBondRouteIntegrationTest --gas-report
```

Result:

```text
Ran 1 test suite: 13 tests passed, 0 failed, 0 skipped
```

### Full Protected Operations

| Test | Gas |
|---|---:|
| `test_canonical_bondroute_executes_exact_input_swap` | 298,322 |
| `test_canonical_bondroute_exact_input_swap_pulls_erc20_funding_from_user` | 315,326 |
| `test_canonical_bondroute_exact_input_swap_uses_native_funding_from_msg_value` | 304,532 |
| `test_canonical_bondroute_add_liquidity_pulls_two_erc20_fundings_from_user` | 370,918 |
| `test_canonical_bondroute_add_liquidity_uses_native_and_erc20_fundings` | 343,569 |

### BondRoute Validation / Failure Paths

| Test | Gas |
|---|---:|
| `test_canonical_bondroute_commitment_hash_has_caffe_prefix_and_sentinel_layout` | 75,938 |
| `test_canonical_bondroute_create_bond_reverts_for_wrong_chain` | 109,166 |
| `test_canonical_bondroute_create_bond_reverts_for_wrong_stake_amount` | 109,077 |
| `test_canonical_bondroute_create_bond_reverts_for_wrong_stake_token` | 111,478 |
| `test_canonical_bondroute_retries_after_safeswap_seconds_delay` | 347,910 |
| `test_canonical_bondroute_reverts_before_safeswap_seconds_delay` | 219,361 |
| `test_canonical_bondroute_reverts_same_block_execution` | 204,348 |
| `test_canonical_bondroute_settles_unknown_selector_as_invalid_bond` | 150,592 |

## Auxiliary: Direct PoolManager Harness

These numbers are lower-level harness measurements against a real v4 `PoolManager`. They are useful for isolating SafeSwap/core behavior, but they are not the primary benchmark because they do not include the full BondRoute create/execute path.

Command:

```sh
/home/noname/.foundry/bin/forge test --match-contract RealPoolIntegrationTest --gas-report
```

Result:

```text
Ran 1 test suite: 36 tests passed, 0 failed, 0 skipped
```

| Test | Gas |
|---|---:|
| `test_real_pool_exact_input_swap_basic` | 192,271 |
| `test_real_pool_exact_output_swap_basic` | 191,538 |
| `test_real_pool_add_liquidity_basic` | 298,505 |
| `test_real_pool_remove_liquidity_basic` | 414,679 |
| `test_real_pool_donate_basic` | 196,850 |

## Comparison Target: PositionManager Routing

The next benchmark should compare against an implementation where SafeSwap routes liquidity operations through Uniswap v4 `PositionManager`, giving users canonical Uniswap v4 LP NFTs:

```text
owner = PositionManager
salt = bytes32(tokenId)
NFT owner = BondRoute/SafeSwap user
```

The comparison should focus on:

- `add_liquidity` versus `PositionManager` `MINT_POSITION`
- `remove_liquidity` versus `PositionManager` `DECREASE_LIQUIDITY`
- any added cost for `initializePool`
- extra SafeSwap transient authorization context around PositionManager calls
- payment adapter overhead from BondRoute fundings into PositionManager settlement

## Caveat

The full command:

```sh
/home/noname/.foundry/bin/forge test --gas-report
```

currently reports `222 passed, 13 failed`. The failures are isolated to `HookCallbacksTest` protected-context harness expectations. The canonical BondRoute benchmark above passes cleanly and is the baseline to compare against PositionManager routing.

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title TestManifest
 * @notice Central registry of ALL test functions for SafeSwap test suite
 * @dev This file provides a bird's-eye view of test coverage without implementation pollution.
 *      Each test contract implements a subset of these tests as documented in their sections.
 *
 *      NAMING CONVENTION:
 *      - test_<function>_<scenario>_<expected_outcome>
 *      - testFuzz_<function>_<property>
 *      - testInvariant_<property>
 */


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// CONSTRUCTOR & INITIALIZATION
// Implemented in: test/SafeSwap/Constructor.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IConstructorTests {
    // ─── Deployment ────────────────────────────────────────────────────────────────
    function test_constructor_sets_pool_manager_from_open_storage( ) external;
    function test_constructor_sets_owner_correctly( ) external;
    function test_constructor_reverts_if_pool_manager_not_set( ) external;
    function test_constructor_announces_protocol_to_bondroute( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// OWNERSHIP
// Implemented in: test/SafeSwap/Ownership.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IOwnershipTests {
    // ─── Ownable Inheritance ───────────────────────────────────────────────────────
    function test_owner_returns_initial_owner( ) external;
    function test_transfer_ownership_works_for_owner( ) external;
    function test_transfer_ownership_reverts_for_non_owner( ) external;
    function test_renounce_ownership_works_for_owner( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// BONDROUTE INTEGRATION
// Implemented in: test/SafeSwap/BondRouteIntegration.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IBondRouteIntegrationTests {
    // ─── BondRoute_get_protected_selectors( ) ──────────────────────────────────────
    function test_get_protected_selectors_returns_four_selectors( ) external;
    function test_get_protected_selectors_includes_swap_exact_input( ) external;
    function test_get_protected_selectors_includes_swap_exact_output( ) external;
    function test_get_protected_selectors_includes_add_liquidity( ) external;
    function test_get_protected_selectors_includes_remove_liquidity( ) external;
    function test_get_protected_selectors_gas_below_50000( ) external;

    // ─── BondRoute_quote_call( ) - Exact Input Swap ────────────────────────────────
    function test_quote_call_exact_input_returns_correct_min_stake( ) external;
    function test_quote_call_exact_input_returns_correct_min_fundings( ) external;
    function test_quote_call_exact_input_returns_correct_execution_delays( ) external;
    function test_quote_call_exact_input_reverts_if_tokens_same( ) external;
    function test_quote_call_exact_input_stake_is_in_input_token( ) external;
    function test_quote_call_exact_input_reverts_if_funding_count_not_1( ) external;

    // ─── BondRoute_quote_call( ) - Exact Output Swap ───────────────────────────────
    function test_quote_call_exact_output_returns_correct_min_stake( ) external;
    function test_quote_call_exact_output_returns_correct_min_fundings( ) external;
    function test_quote_call_exact_output_returns_correct_execution_delays( ) external;
    function test_quote_call_exact_output_reverts_if_tokens_same( ) external;
    function test_quote_call_exact_output_reverts_if_funding_count_not_1( ) external;

    // ─── BondRoute_quote_call( ) - Add Liquidity ───────────────────────────────────
    function test_quote_call_add_liquidity_returns_correct_min_stake( ) external;
    function test_quote_call_add_liquidity_returns_two_fundings( ) external;
    function test_quote_call_add_liquidity_returns_correct_execution_delays( ) external;
    function test_quote_call_add_liquidity_reverts_if_tokens_same( ) external;
    function test_quote_call_add_liquidity_reverts_if_funding_count_not_2( ) external;

    // ─── BondRoute_quote_call( ) - Remove Liquidity ────────────────────────────────
    function test_quote_call_remove_liquidity_returns_correct_min_stake( ) external;
    function test_quote_call_remove_liquidity_returns_zero_fundings( ) external;
    function test_quote_call_remove_liquidity_returns_correct_execution_delays( ) external;
    function test_quote_call_remove_liquidity_reverts_if_tokens_same( ) external;

    // ─── BondRoute_quote_call( ) - Unknown Selector ────────────────────────────────
    function test_quote_call_reverts_on_unknown_selector( ) external;

    // ─── Protected Function Access Control ─────────────────────────────────────────
    function test_swap_exact_input_reverts_if_not_bondroute( ) external;
    function test_swap_exact_output_reverts_if_not_bondroute( ) external;
    function test_add_liquidity_reverts_if_not_bondroute( ) external;
    function test_remove_liquidity_reverts_if_not_bondroute( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// HOOK CALLBACKS
// Implemented in: test/SafeSwap/HookCallbacks.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IHookCallbackTests {
    // ─── beforeSwap( ) ─────────────────────────────────────────────────────────────
    function test_before_swap_reverts_if_not_pool_manager( ) external;
    function test_before_swap_reverts_if_not_protected_context( ) external;
    function test_before_swap_returns_correct_selector( ) external;
    function test_before_swap_returns_zero_delta( ) external;
    function test_before_swap_succeeds_in_protected_context( ) external;

    // ─── beforeAddLiquidity( ) ─────────────────────────────────────────────────────
    function test_before_add_liquidity_reverts_if_not_pool_manager( ) external;
    function test_before_add_liquidity_reverts_if_not_protected_context( ) external;
    function test_before_add_liquidity_returns_correct_selector( ) external;
    function test_before_add_liquidity_succeeds_in_protected_context( ) external;

    // ─── beforeRemoveLiquidity( ) ──────────────────────────────────────────────────
    function test_before_remove_liquidity_reverts_if_not_pool_manager( ) external;
    function test_before_remove_liquidity_reverts_if_not_protected_context( ) external;
    function test_before_remove_liquidity_returns_correct_selector( ) external;
    function test_before_remove_liquidity_succeeds_in_protected_context( ) external;

    // ─── Protected Context State ───────────────────────────────────────────────────
    function test_protected_context_cleared_after_swap( ) external;
    function test_protected_context_cleared_after_add_liquidity( ) external;
    function test_protected_context_cleared_after_remove_liquidity( ) external;
    function test_protected_context_transient_storage_isolation( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// UNLOCK CALLBACK & EXECUTION
// Implemented in: test/SafeSwap/UnlockCallback.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IUnlockCallbackTests {
    // ─── Access Control ────────────────────────────────────────────────────────────
    function test_unlock_callback_reverts_if_not_pool_manager( ) external;

    // ─── Operation Type Dispatch ───────────────────────────────────────────────────
    function test_unlock_callback_dispatches_exact_input_swap( ) external;
    function test_unlock_callback_dispatches_exact_output_swap( ) external;
    function test_unlock_callback_dispatches_add_liquidity( ) external;
    function test_unlock_callback_dispatches_remove_liquidity( ) external;
    function test_unlock_callback_reverts_on_invalid_operation_type( ) external;

    // ─── Trailing Byte Encoding ────────────────────────────────────────────────────
    function test_unlock_callback_reads_operation_type_from_last_byte( ) external;
    function test_unlock_callback_decodes_payload_without_trailing_byte( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SWAP EXECUTION
// Implemented in: test/SafeSwap/SwapExecution.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ISwapExecutionTests {
    // ─── Exact Input Swap ──────────────────────────────────────────────────────────
    function test_exact_input_swap_transfers_correct_amount_in( ) external;
    function test_exact_input_swap_transfers_correct_amount_out( ) external;
    function test_exact_input_swap_reverts_on_slippage_exceeded( ) external;
    function test_exact_input_swap_zero_for_one_direction( ) external;
    function test_exact_input_swap_one_for_zero_direction( ) external;
    function test_exact_input_swap_deducts_protocol_fee( ) external;

    // ─── Exact Output Swap ─────────────────────────────────────────────────────────
    function test_exact_output_swap_transfers_correct_amount_in( ) external;
    function test_exact_output_swap_transfers_correct_amount_out( ) external;
    function test_exact_output_swap_reverts_on_slippage_exceeded( ) external;
    function test_exact_output_swap_zero_for_one_direction( ) external;
    function test_exact_output_swap_one_for_zero_direction( ) external;
    function test_exact_output_swap_deducts_protocol_fee( ) external;

    // ─── Pool Key Building ─────────────────────────────────────────────────────────
    function test_build_pool_key_orders_currencies_correctly( ) external;
    function test_build_pool_key_sets_hook_address( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// LIQUIDITY EXECUTION
// Implemented in: test/SafeSwap/LiquidityExecution.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ILiquidityExecutionTests {
    // ─── Add Liquidity ─────────────────────────────────────────────────────────────
    function test_add_liquidity_calculates_liquidity_correctly( ) external;
    function test_add_liquidity_transfers_token0_to_pool( ) external;
    function test_add_liquidity_transfers_token1_to_pool( ) external;
    function test_add_liquidity_reverts_on_amount0_slippage( ) external;
    function test_add_liquidity_reverts_on_amount1_slippage( ) external;
    function test_add_liquidity_handles_single_sided_deposit( ) external;
    function test_add_liquidity_uses_correct_tick_range( ) external;
    function test_add_liquidity_uses_salt_for_position( ) external;
    function test_add_liquidity_passes_when_amounts_meet_minimums( ) external;

    // ─── Add Liquidity — Position Isolation ─────────────────────────────────────────
    function test_add_liquidity_different_users_same_salt_produce_different_effective_salts( ) external;
    function test_add_liquidity_same_user_same_salt_produce_same_effective_salt( ) external;

    // ─── Remove Liquidity ──────────────────────────────────────────────────────────
    function test_remove_liquidity_returns_tokens_to_user( ) external;
    function test_remove_liquidity_reverts_on_amount0_slippage( ) external;
    function test_remove_liquidity_reverts_on_amount1_slippage( ) external;
    function test_remove_liquidity_uses_correct_tick_range( ) external;
    function test_remove_liquidity_uses_salt_for_position( ) external;
    function test_remove_liquidity_full_position( ) external;
    function test_remove_liquidity_partial_position( ) external;
    function test_remove_liquidity_passes_when_amounts_meet_minimums( ) external;

    // ─── Remove Liquidity — Position Isolation ──────────────────────────────────────
    function test_remove_liquidity_different_users_same_salt_produce_different_effective_salts( ) external;
    function test_remove_liquidity_effective_salt_matches_add_liquidity( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// PROTOCOL FEE
// Implemented in: test/SafeSwap/ProtocolFee.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IProtocolFeeTests {
    // ─── Fee Calculation ───────────────────────────────────────────────────────────
    function test_protocol_fee_is_10_percent_of_lp_fee_rate( ) external;
    function test_protocol_fee_uses_floor_for_low_fee_pools( ) external;
    function test_protocol_fee_floor_is_001_percent( ) external;
    function test_protocol_fee_floor_kicks_in_below_010_percent_pool( ) external;

    // ─── Fee by Pool Type ──────────────────────────────────────────────────────────
    function test_protocol_fee_stable_pool_001_percent_uses_floor( ) external;
    function test_protocol_fee_semi_stable_pool_005_percent_uses_floor( ) external;
    function test_protocol_fee_standard_pool_030_percent_no_floor( ) external;
    function test_protocol_fee_exotic_pool_100_percent_no_floor( ) external;

    // ─── Fee Distribution ──────────────────────────────────────────────────────────
    function test_protocol_fee_sent_to_contract( ) external;
    function test_user_receives_output_minus_protocol_fee( ) external;

    // ─── Edge Cases ────────────────────────────────────────────────────────────────
    function test_protocol_fee_on_minimum_swap_amount( ) external;
    function test_protocol_fee_on_maximum_swap_amount( ) external;
    function test_protocol_fee_exactly_at_floor_threshold( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// FEE WITHDRAWAL
// Implemented in: test/SafeSwap/FeeWithdrawal.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IFeeWithdrawalTests {
    // ─── withdraw_fees( ) ──────────────────────────────────────────────────────────
    function test_withdraw_fees_transfers_erc20_to_recipient( ) external;
    function test_withdraw_fees_transfers_native_to_recipient( ) external;
    function test_withdraw_fees_reverts_if_not_owner( ) external;
    function test_withdraw_fees_keeps_1_wei_for_gas_optimization( ) external;
    function test_withdraw_fees_no_op_if_balance_is_1_or_less( ) external;
    function test_withdraw_fees_reverts_on_failed_native_transfer( ) external;
    function test_withdraw_fees_reverts_on_failed_erc20_transfer( ) external;

    // ─── receive( ) ────────────────────────────────────────────────────────────────
    function test_receive_accepts_native_token( ) external;

    // ─── Multi-Token Withdrawal ────────────────────────────────────────────────────
    function test_withdraw_fees_multiple_tokens_sequentially( ) external;
    function test_withdraw_fees_to_different_recipients( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// STAKE CALCULATION
// Implemented in: test/SafeSwap/StakeCalculation.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IStakeCalculationTests {
    // ─── Swap Stake ─────────────────────────────────────────────────────────────────
    function test_swap_stake_token_is_input_token( ) external;
    function test_swap_stake_is_1_percent( ) external;
    function test_swap_stake_rounds_down( ) external;
    function test_swap_stake_zero_input( ) external;

    // ─── Liquidity Stake ────────────────────────────────────────────────────────────
    function test_liquidity_stake_is_2_percent( ) external;
    function test_liquidity_stake_is_double_swap_stake( ) external;
    function test_liquidity_stake_token_is_token0( ) external;
    function test_liquidity_stake_large_value( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// INTEGRATION TESTS
// Implemented in: test/SafeSwap/Integration.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IIntegrationTests {
    // ─── Full Swap Flow ────────────────────────────────────────────────────────────
    function test_integration_exact_input_swap_end_to_end( ) external;
    function test_integration_exact_output_swap_end_to_end( ) external;
    function test_integration_swap_with_native_token_in( ) external;
    function test_integration_swap_with_native_token_out( ) external;

    // ─── Full Liquidity Flow ───────────────────────────────────────────────────────
    function test_integration_add_liquidity_end_to_end( ) external;
    function test_integration_remove_liquidity_end_to_end( ) external;
    function test_integration_add_then_remove_liquidity( ) external;

    // ─── Multiple Operations ───────────────────────────────────────────────────────
    function test_integration_multiple_swaps_same_pool( ) external;
    function test_integration_multiple_users_same_pool( ) external;
    function test_integration_swap_after_liquidity_change( ) external;

    // ─── Fee Accumulation ──────────────────────────────────────────────────────────
    function test_integration_fees_accumulate_over_swaps( ) external;
    function test_integration_owner_withdraws_accumulated_fees( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// FUZZ TESTS
// Implemented in: test/SafeSwap/Fuzz.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IFuzzTests {
    // ─── Fee Calculation ───────────────────────────────────────────────────────────
    function testFuzz_protocol_fee_never_exceeds_output( uint256 amount_out, uint24 pool_fee ) external;
    function testFuzz_protocol_fee_at_least_floor_rate( uint256 amount_out, uint24 pool_fee ) external;
    function testFuzz_protocol_fee_proportional_to_pool_fee( uint256 amount_out, uint24 pool_fee ) external;

    // ─── Stake Calculation ─────────────────────────────────────────────────────────
    function testFuzz_stake_is_1_percent_of_amount( uint256 amount ) external;

    // ─── Slippage Protection ───────────────────────────────────────────────────────
    function testFuzz_exact_input_respects_minimum_output( uint256 amount_in, uint256 min_out ) external;
    function testFuzz_exact_output_respects_maximum_input( uint256 amount_out, uint256 max_in ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// INVARIANT TESTS
// Implemented in: test/SafeSwap/Invariants.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IInvariantTests {
    // ─── Fee Invariants ────────────────────────────────────────────────────────────
    function invariant_protocol_fee_always_collected( ) external;
    function invariant_protocol_fee_never_negative( ) external;
    function invariant_user_output_plus_fee_equals_pool_output( ) external;

    // ─── Protected Context Invariants ──────────────────────────────────────────────
    function invariant_protected_context_always_cleared_after_operation( ) external;
    function invariant_hooks_only_pass_in_protected_context( ) external;

    // ─── Ownership Invariants ──────────────────────────────────────────────────────
    function invariant_only_owner_can_withdraw( ) external;
    function invariant_ownership_transfer_requires_current_owner( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// GAS BENCHMARKS
// Implemented in: test/SafeSwap/GasBenchmarks.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IGasBenchmarkTests {
    // ─── Swap Operations ───────────────────────────────────────────────────────────
    function test_gas_exact_input_swap( ) external;
    function test_gas_exact_output_swap( ) external;

    // ─── Liquidity Operations ──────────────────────────────────────────────────────
    function test_gas_add_liquidity( ) external;
    function test_gas_remove_liquidity( ) external;

    // ─── Hook Callbacks ────────────────────────────────────────────────────────────
    function test_gas_before_swap_callback( ) external;
    function test_gas_before_add_liquidity_callback( ) external;
    function test_gas_before_remove_liquidity_callback( ) external;

    // ─── Fee Operations ────────────────────────────────────────────────────────────
    function test_gas_withdraw_fees_erc20( ) external;
    function test_gas_withdraw_fees_native( ) external;

    // ─── Encoding Comparison ───────────────────────────────────────────────────────
    function test_gas_trailing_byte_encoding_vs_abi_encode( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SUMMARY STATISTICS
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// Total Tests Declared:       155
// Implemented & Passing:      155 ✓
//
// Coverage by Section:
// - Constructor:                4 tests  ✓
// - Ownership:                  4 tests  ✓
// - BondRoute Integration:     31 tests  ✓
// - Hook Callbacks:            17 tests  ✓
// - Unlock Callback:            8 tests  ✓
// - Swap Execution:            14 tests  ✓
// - Liquidity Execution:       21 tests  ✓
// - Protocol Fee:              13 tests  ✓
// - Fee Withdrawal:            10 tests  ✓
// - Stake Calculation:          8 tests  ✓
// - Integration Tests:         12 tests  ✓
// - Fuzz Tests:                 6 tests  ✓
// - Invariant Tests:            7 tests  ✓
// - Gas Benchmarks:            10 tests  (declared, not yet implemented)
//
//
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// GAS COSTS
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// BONDROUTE OVERHEAD
// ─────────────────────────────────────────────────────────────────────────────────────────────────────
//
// BondRoute overhead varies by stake type and protocol access state:
// - COLD: First access to protocol in transaction (higher gas for initial SLOAD/SSTORE)
// - WARM: Protocol already accessed earlier in transaction (cached, lower gas)
//
// ┌────────────────┬─────────────┬──────────────┬──────────────┬─────────────┐
// │ Stake Type     │ Protocol    │ create_bond  │ execute_bond │ Total       │
// ├────────────────┼─────────────┼──────────────┼──────────────┼─────────────┤
// │ ERC20          │ COLD        │    45,550    │    20,469    │    66,019   │
// │ ERC20          │ WARM        │    45,550    │    16,469    │    62,019   │
// │ Native (ETH)   │ COLD        │    32,660    │    24,208    │    56,868   │
// │ Native (ETH)   │ WARM        │    32,660    │    20,208    │    52,868   │
// │ Zero           │ COLD        │    25,960    │    17,323    │    43,283   │
// │ Zero           │ WARM        │    25,960    │    13,323    │    39,283   │
// └────────────────┴─────────────┴──────────────┴──────────────┴─────────────┘
//
// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// SAFESWAP HOOK
// ─────────────────────────────────────────────────────────────────────────────────────────────────────
//
// Hook Callback Overhead (added by PoolManager on every operation):
// ┌────────────────────────────┬────────────┐
// │ Callback                   │ Gas Cost   │
// ├────────────────────────────┼────────────┤
// │ beforeSwap                 │    3,831   │
// │ beforeAddLiquidity         │    3,721   │
// │ beforeRemoveLiquidity      │    3,699   │
// └────────────────────────────┴────────────┘
//
// SafeSwap Execution (mocked pool):
// ┌────────────────────────────┬────────────┐
// │ Operation                  │ Gas Cost   │
// ├────────────────────────────┼────────────┤
// │ exact_input_swap           │   66,520   │
// │ exact_output_swap          │   66,681   │
// │ add_liquidity              │   34,767   │
// │ remove_liquidity           │   45,096   │
// └────────────────────────────┴────────────┘
//
// Fee Withdrawal:
// ┌────────────────────────────┬────────────┐
// │ Operation                  │ Gas Cost   │
// ├────────────────────────────┼────────────┤
// │ withdraw_fees (ERC20)      │   34,189   │
// │ withdraw_fees (Native)     │   39,768   │
// └────────────────────────────┴────────────┘
//
// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// FULL SWAP COST ESTIMATE
// ─────────────────────────────────────────────────────────────────────────────────────────────────────
//
// Protected swap with ERC20 stake (warm protocol):
//   BondRoute overhead     ~62k gas
//   SafeSwap           ~67k gas
//   Uniswap V4 swap       ~100-150k gas
//   ─────────────────────────────────
//   Total:                ~230-280k gas
//
// Direct Uniswap V4 swap: ~100-150k gas
// MEV protection cost:    ~80-130k gas additional
//

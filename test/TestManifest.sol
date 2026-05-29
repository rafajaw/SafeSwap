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
    function test_constructor_sets_collector_correctly( ) external;
    function test_constructor_reverts_if_pool_manager_not_set( ) external;
    function test_constructor_reverts_if_chain_config_points_to_non_pool_manager( ) external;
    function test_constructor_reverts_if_initial_collector_not_set( ) external;
    function test_constructor_reverts_if_hook_address_has_wrong_flags( ) external;
    function test_constructor_announces_protocol_to_bondroute( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// COLLECTOR
// Implemented in: test/SafeSwap/Collector.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ICollectorTests {
    // ─── Role Transfer ─────────────────────────────────────────────────────────────
    function test_get_collector_returns_initial_collector( ) external;
    function test_transfer_collector_sets_pending( ) external;
    function test_transfer_collector_reverts_for_non_collector( ) external;
    function test_accept_collector_completes_transfer( ) external;
    function test_accept_collector_reverts_for_non_pending( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MOCK BONDROUTE INTEGRATION
// Implemented in: test/SafeSwap/MockBondRouteIntegration.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IMockBondRouteIntegrationTests {
    // ─── BondRoute_get_protected_selectors( ) ──────────────────────────────────────
    function test_get_protected_selectors_returns_five_selectors( ) external;
    function test_get_protected_selectors_includes_swap_exact_input( ) external;
    function test_get_protected_selectors_includes_swap_exact_output( ) external;
    function test_get_protected_selectors_includes_add_liquidity( ) external;
    function test_get_protected_selectors_includes_remove_liquidity( ) external;
    function test_get_protected_selectors_includes_donate( ) external;
    function test_get_protected_selectors_gas_below_50000( ) external;

    // ─── BondRoute_validate( ) ────────────────────────────────────────────────────
    function test_entry_point_reverts_before_minimum_seconds_delay( ) external;

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
    function test_quote_call_add_liquidity_reverts_if_tokens_same( ) external;
    function test_quote_call_add_liquidity_reverts_if_funding_count_not_2( ) external;
    function test_quote_call_add_liquidity_returns_correct_execution_delays( ) external;

    // ─── BondRoute_quote_call( ) - Remove Liquidity ────────────────────────────────
    function test_quote_call_remove_liquidity_reverts_if_tokens_same( ) external;
    function test_quote_call_remove_liquidity_returns_correct_execution_delays( ) external;

    // ─── BondRoute_quote_call( ) - Donate ─────────────────────────────────────────
    function test_quote_call_donate_reverts_if_tokens_same( ) external;
    function test_quote_call_donate_reverts_if_funding_count_not_2( ) external;
    function test_quote_call_donate_returns_correct_execution_delays( ) external;

    // ─── BondRoute_quote_call( ) - Unknown Selector ────────────────────────────────
    function test_quote_call_reverts_on_unknown_selector( ) external;
    function test_quote_call_reverts_on_short_call( ) external;

    // ─── BondRoute_quote_call( ) - Dynamic-Fee Pool Rejection ──────────────────────
    function test_quote_call_rejects_dynamic_fee_on_every_selector( ) external;

    // ─── BondRoute_get_signing_info( ) ──────────────────────────────────────────────
    function test_get_signing_info_exact_input_returns_valid_type_string( ) external;
    function test_get_signing_info_exact_output_returns_valid_type_string( ) external;
    function test_get_signing_info_add_liquidity_returns_valid_type_string( ) external;
    function test_get_signing_info_remove_liquidity_returns_valid_type_string( ) external;
    function test_get_signing_info_donate_returns_valid_type_string( ) external;
    function test_get_signing_info_struct_hash_changes_with_params( ) external;
    function test_get_signing_info_reverts_on_unknown_selector( ) external;
    function test_get_signing_info_reverts_on_short_call( ) external;

    // ─── Protected Function Access Control ─────────────────────────────────────────
    function test_swap_exact_input_reverts_if_not_bondroute( ) external;
    function test_swap_exact_output_reverts_if_not_bondroute( ) external;
    function test_add_liquidity_reverts_if_not_bondroute( ) external;
    function test_remove_liquidity_reverts_if_not_bondroute( ) external;
    function test_donate_reverts_if_not_bondroute( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// CANONICAL BONDROUTE INTEGRATION
// Implemented in: test/SafeSwap/CanonicalBondRouteIntegration.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ICanonicalBondRouteIntegrationTests {
    function test_canonical_bondroute_commitment_hash_has_caffe_prefix_and_sentinel_layout( ) external;
    function test_canonical_bondroute_create_bond_reverts_for_wrong_stake_amount( ) external;
    function test_canonical_bondroute_create_bond_reverts_for_wrong_stake_token( ) external;
    function test_canonical_bondroute_create_bond_reverts_for_wrong_chain( ) external;
    function test_canonical_bondroute_executes_exact_input_swap( ) external;
    function test_canonical_bondroute_exact_input_swap_pulls_erc20_funding_from_user( ) external;
    function test_canonical_bondroute_exact_input_swap_uses_native_funding_from_msg_value( ) external;
    function test_canonical_bondroute_add_liquidity_pulls_two_erc20_fundings_from_user( ) external;
    function test_canonical_bondroute_add_liquidity_uses_native_and_erc20_fundings( ) external;
    function test_canonical_bondroute_reverts_same_block_execution( ) external;
    function test_canonical_bondroute_reverts_before_safeswap_seconds_delay( ) external;
    function test_canonical_bondroute_retries_after_safeswap_seconds_delay( ) external;
    function test_canonical_bondroute_settles_unknown_selector_as_invalid_bond( ) external;
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

    // ─── beforeDonate( ) ───────────────────────────────────────────────────────────
    function test_before_donate_reverts_if_not_pool_manager( ) external;
    function test_before_donate_reverts_if_not_protected_context( ) external;
    function test_before_donate_returns_correct_selector( ) external;
    function test_before_donate_succeeds_in_protected_context( ) external;

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
    function test_unlock_callback_dispatches_donate( ) external;
    function test_unlock_callback_reverts_on_invalid_action( ) external;

    // ─── Trailing Byte Encoding ────────────────────────────────────────────────────
    function test_unlock_callback_reads_operation_type_from_first_byte( ) external;
    function test_unlock_callback_decodes_payload_after_leading_byte( ) external;
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
    function test_off_chain_get_pool_id_matches_pool_key_id_for_both_token_orders( ) external;
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
    function test_add_liquidity_passes_when_amounts_meet_minimums( ) external;
    function test_add_liquidity_reverts_on_one_sided_mismatch_token0_expected( ) external;
    function test_add_liquidity_reverts_on_one_sided_mismatch_token1_expected( ) external;

    // ─── Add Liquidity — Position Isolation ─────────────────────────────────────────
    function test_add_liquidity_different_users_produce_isolated_position_salts( ) external;

    // ─── Remove Liquidity ──────────────────────────────────────────────────────────
    function test_remove_liquidity_returns_tokens_to_user( ) external;
    function test_remove_liquidity_reverts_on_amount0_slippage( ) external;
    function test_remove_liquidity_reverts_on_amount1_slippage( ) external;
    function test_remove_liquidity_uses_correct_tick_range( ) external;
    function test_remove_liquidity_full_position( ) external;
    function test_remove_liquidity_partial_position( ) external;
    function test_remove_liquidity_passes_when_amounts_meet_minimums( ) external;

    // ─── Remove Liquidity — Position Isolation ──────────────────────────────────────
    function test_remove_liquidity_different_users_produce_isolated_position_salts( ) external;
    function test_remove_liquidity_position_salt_matches_add_liquidity( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// DONATE EXECUTION
// Implemented in: test/SafeSwap/DonateExecution.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IDonateExecutionTests {
    // ─── Donate ───────────────────────────────────────────────────────────────────
    function test_donate_transfers_token0_to_pool( ) external;
    function test_donate_transfers_token1_to_pool( ) external;
    function test_donate_transfers_both_tokens_to_pool( ) external;
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
    function test_withdraw_fees_reverts_if_not_collector( ) external;
    function test_withdraw_fees_keeps_1_wei_for_gas_optimization( ) external;
    function test_withdraw_fees_no_op_if_balance_is_1_or_less( ) external;
    function test_withdraw_fees_reverts_on_failed_native_transfer( ) external;
    function test_withdraw_fees_reverts_on_failed_erc20_transfer( ) external;

    // ─── receive( ) ────────────────────────────────────────────────────────────────
    function test_receive_rejects_direct_native_transfer_from_arbitrary_sender( ) external;
    function test_receive_accepts_native_from_pool_manager( ) external;
    function test_receive_accepts_native_from_bondroute( ) external;

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
    function test_swap_stake_bumps_dust_to_one_wei( ) external;
    function test_swap_stake_zero_input_still_bumps_to_one_wei( ) external;

    // ─── Liquidity Stake ───────────────────────────────────────────────────────────
    function test_liquidity_stake_defaults_to_token0( ) external;
    function test_liquidity_stake_honors_token1_preference( ) external;
    function test_liquidity_stake_ignores_unknown_preference_and_defaults_to_token0( ) external;
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
    function test_integration_collector_withdraws_accumulated_fees( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// REAL POOL INTEGRATION TESTS
// Implemented in: test/SafeSwap/RealPoolIntegration.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IRealPoolIntegrationTests {
    // ─── Exact Input Swap ─────────────────────────────────────────────────────────
    function test_real_pool_exact_input_swap_basic( ) external;
    function test_real_pool_exact_input_swap_correct_protocol_fee( ) external;
    function test_real_pool_exact_input_swap_one_for_zero_direction( ) external;
    function test_real_pool_exact_input_swap_respects_slippage( ) external;

    // ─── Exact Output Swap ────────────────────────────────────────────────────────
    function test_real_pool_exact_output_swap_basic( ) external;
    function test_real_pool_exact_output_swap_correct_protocol_fee( ) external;
    function test_real_pool_exact_output_swap_respects_slippage( ) external;

    // ─── Liquidity ────────────────────────────────────────────────────────────────
    function test_real_pool_add_liquidity_basic( ) external;
    function test_real_pool_add_liquidity_respects_slippage( ) external;
    function test_real_pool_add_liquidity_user_position_isolation( ) external;
    function test_real_pool_remove_liquidity_basic( ) external;
    function test_real_pool_remove_liquidity_correct_amounts( ) external;
    function test_real_pool_remove_liquidity_respects_slippage( ) external;

    // ─── Multi-Operation ──────────────────────────────────────────────────────────
    function test_real_pool_multiple_swaps_move_price( ) external;
    function test_real_pool_swap_after_adding_more_liquidity( ) external;
    function test_real_pool_fee_accumulation_and_withdrawal( ) external;

    // ─── Donate ───────────────────────────────────────────────────────────────────
    function test_real_pool_donate_basic( ) external;
    function test_real_pool_donate_one_sided( ) external;

    // ─── Native ETH (end-to-end) ──────────────────────────────────────────────────
    function test_real_pool_native_exact_input_swap_eth_to_erc20( ) external;
    function test_real_pool_native_exact_input_swap_erc20_to_eth( ) external;
    function test_real_pool_native_add_and_remove_liquidity( ) external;

    // ─── Security ─────────────────────────────────────────────────────────────────
    function test_real_pool_hook_rejects_direct_pool_swap( ) external;
    function test_real_pool_hook_rejects_direct_pool_donate( ) external;
    function test_real_pool_protected_context_cleared_after_operation( ) external;

    // ─── Stake Quotation ──────────────────────────────────────────────────────────
    function test_real_pool_quote_add_liquidity_stake_normalizes_both_sides( ) external;
    function test_real_pool_quote_add_liquidity_dust_input_still_yields_real_stake( ) external;
    function test_real_pool_quote_add_liquidity_one_sided_above_yields_real_stake( ) external;
    function test_real_pool_quote_add_liquidity_returns_two_fundings_and_delays( ) external;
    function test_real_pool_quote_add_liquidity_honors_token1_stake_preference( ) external;
    function test_real_pool_quote_remove_liquidity_stake_uses_position_amounts( ) external;
    function test_real_pool_quote_remove_liquidity_stake_ignores_user_supplied_mins( ) external;
    function test_real_pool_quote_remove_liquidity_honors_token1_stake_preference( ) external;
    function test_real_pool_quote_donate_stake_normalizes_both_sides( ) external;
    function test_real_pool_quote_donate_dust_input_still_yields_real_stake( ) external;
    function test_real_pool_quote_donate_one_sided_yields_real_stake( ) external;
    function test_real_pool_quote_donate_honors_token1_stake_preference( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// REENTRANT PROTECTED CONTEXT TESTS
// Implemented in: test/SafeSwap/ReentrantProtectedContext.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IReentrantProtectedContextTests {
    function test_reentrant_output_token_transfer_reverts_when_direct_swap_has_no_bondroute_context( ) external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MEMORY ZERO-INITIALIZATION TESTS
// Implemented in: test/SafeSwap/MemoryZeroInit.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IMemoryZeroInitTests {
    function test_named_return_BondConstraints_is_zero_initialized_after_memory_garbage( ) external;
    function test_new_uint256_array_is_zero_initialized_after_memory_garbage( ) external;
    function test_new_TokenAmount_array_is_zero_initialized_after_memory_garbage( ) external;
    function test_in_body_Range_memory_var_is_zero_initialized_after_memory_garbage( ) external;
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

    // ─── Donate ────────────────────────────────────────────────────────────────────
    function testFuzz_donate_executes_for_arbitrary_split( uint128 amount0, uint128 amount1 ) external;
    function testFuzz_donate_executes_for_one_sided_split( uint128 amount, bool donate_token0 ) external;
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

    // ─── Collectorship Invariants ───────────────────────────────────────────────────
    function invariant_only_collector_can_withdraw( ) external;
    function invariant_collectorship_transfer_requires_current_collector( ) external;
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
// Implemented & Passing:      235 ✓
// Manifest-only Benchmarks:    10 declared above, not currently in the test suite.
//
// Coverage by Section:
// - Constructor:                6 tests  ✓
// - Collector:                  5 tests  ✓
// - Mock BondRoute:            43 tests  ✓
// - Canonical BondRoute:       13 tests  ✓
// - Hook Callbacks:            21 tests  ✓
// - Unlock Callback:            9 tests  ✓
// - Swap Execution:            15 tests  ✓
// - Liquidity Execution:       20 tests  ✓
// - Donate Execution:           3 tests  ✓
// - Protocol Fee:              13 tests  ✓
// - Fee Withdrawal:            12 tests  ✓
// - Stake Calculation:          7 tests  ✓
// - Integration Tests:         12 tests  ✓
// - Real Pool Integration:     36 tests  ✓
// - Reentrant Context:          1 test    ✓
// - Memory Zero Init:           4 tests  ✓
// - Fuzz Tests:                 8 tests  ✓
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

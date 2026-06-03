// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title CommonTestManifest
 * @notice Test interface registry for shared SafeSwap primitives.
 * @dev Future test contracts in test/Common should implement the relevant interface below.
 */


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// HOOKADDRESS.SOL - BCD hook config and v4 permission decoding.
// Implemented in: test/Common/HookAddress.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IHookAddressTests {
    // ─── BCD Config Decode ───────────────────────────────────────────────────────
    function test_decode_valid_bcd_hook_address_returns_base_fee_and_rebate_percent() external;
    function test_decode_zero_digits_returns_zero_base_fee_and_zero_rebate_percent() external;
    function test_decode_max_supported_digits_returns_nine_hundred_ninety_nine_bps_and_ninety_percent() external;
    function test_decode_reverts_when_fee_marker_is_not_f() external;
    function test_decode_reverts_when_capture_marker_is_not_c() external;
    function test_decode_reverts_when_base_fee_hundreds_digit_is_not_decimal() external;
    function test_decode_reverts_when_base_fee_tens_digit_is_not_decimal() external;
    function test_decode_reverts_when_base_fee_ones_digit_is_not_decimal() external;
    function test_decode_reverts_when_rebate_digit_is_not_decimal() external;

    // ─── V4 Permission Bitmap ───────────────────────────────────────────────────
    function test_has_required_permissions_accepts_exact_safeswap_permission_bitmap() external;
    function test_has_required_permissions_rejects_missing_before_initialize_permission() external;
    function test_has_required_permissions_rejects_missing_before_add_liquidity_permission() external;
    function test_has_required_permissions_rejects_missing_before_remove_liquidity_permission() external;
    function test_has_required_permissions_rejects_missing_before_swap_permission() external;
    function test_has_required_permissions_rejects_extra_before_donate_permission() external;
    function test_has_required_permissions_rejects_extra_return_delta_permission() external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SAFESWAPCOMMON.SOL - Shared pool keys, fee math, token helpers, and settlement.
// Implemented in: test/Common/SafeSwapCommon.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ISafeSwapCommonTests {
    // ─── EIP-712 Hashing ────────────────────────────────────────────────────────
    function test_hash_pool_info_matches_abi_encoded_type_hash() external;
    function test_hash_pool_info_changes_when_base_fee_changes() external;
    function test_hash_pool_info_changes_when_rebate_percent_changes() external;
    function test_hash_pool_info_changes_when_tick_spacing_changes() external;
    function test_hash_token_amount_matches_abi_encoded_type_hash() external;
    function test_hash_token_amount_changes_when_token_changes() external;
    function test_hash_token_amount_changes_when_amount_changes() external;
    function test_hash_token_amount_restores_free_memory_pointer() external;

    // ─── Base Fee Units ─────────────────────────────────────────────────────────
    function test_base_fee_units_converts_basis_points_to_v4_pips() external;
    function test_base_fee_units_accepts_zero_base_fee() external;
    function test_base_fee_units_accepts_maximum_bcd_base_fee() external;

    // ─── Repricing Fee Math ──────────────────────────────────────────────────────
    function test_compute_repricing_fee_pips_returns_base_fee_when_tick_movement_is_zero() external;
    function test_compute_repricing_fee_pips_charges_capture_percent_of_tick_movement() external;
    function test_compute_repricing_fee_pips_uses_absolute_tick_movement() external;
    function test_compute_repricing_fee_pips_caps_repricing_component() external;
    function test_compute_repricing_fee_pips_caps_total_swap_fee() external;
    function test_compute_repricing_fee_pips_allows_zero_capture_percent() external;
    function test_compute_repricing_fee_pips_allows_ninety_percent_capture() external;

    // ─── Pool Key Construction ──────────────────────────────────────────────────
    function test_build_pool_key_sorts_currencies_independently_of_user_token_order() external;
    function test_build_pool_key_preserves_dynamic_fee_flag() external;
    function test_build_pool_key_preserves_hook_address_as_pool_identity() external;
    function test_build_pool_key_preserves_tick_spacing() external;

    // ─── Token Amount Helpers ───────────────────────────────────────────────────
    function test_sort_token_amount_pair_orders_tokens_and_amounts_together() external;
    function test_sort_token_amount_pair_reverts_when_tokens_are_identical() external;

    // ─── Stake Calculation ──────────────────────────────────────────────────────
    function test_calculate_swap_stake_returns_one_percent_of_input_amount() external;
    function test_calculate_swap_stake_rounds_dust_up_to_one_wei() external;
    function test_calculate_normalized_liquidity_stake_defaults_to_token0() external;
    function test_calculate_normalized_liquidity_stake_uses_token1_when_preferred() external;
    function test_calculate_normalized_liquidity_stake_converts_token1_value_into_token0_at_price() external;
    function test_calculate_normalized_liquidity_stake_converts_token0_value_into_token1_at_price() external;
    function test_calculate_normalized_liquidity_stake_rounds_dust_up_to_one_wei() external;
    function test_calculate_normalized_liquidity_stake_handles_zero_amount_side() external;

    // ─── Protocol Fee Math ──────────────────────────────────────────────────────
    function test_calculate_protocol_fee_uses_base_fee_when_above_floor() external;
    function test_calculate_protocol_fee_uses_minimum_fee_when_base_fee_is_below_floor() external;
    function test_calculate_protocol_fee_preserves_output_conservation() external;

    // ─── Settlement ─────────────────────────────────────────────────────────────
    function test_settle_input_sends_erc20_funding_directly_to_pool_manager() external;
    function test_settle_input_pulls_native_funding_into_calling_contract_then_settles_with_value() external;
    function test_settle_input_noops_for_zero_amount() external;
    function test_settle_and_take_sends_net_output_to_user_and_protocol_fee_to_recipient() external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SWAPSIMULATOR.SOL - Read-only v4 swap path simulation.
// Implemented in: test/Common/SwapSimulator.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ISwapSimulatorTests {
    // ─── Exact Input ─────────────────────────────────────────────────────────────
    function test_simulate_exact_input_matches_real_swap_inside_one_range() external;
    function test_simulate_exact_input_matches_real_swap_when_crossing_one_initialized_tick() external;
    function test_simulate_exact_input_matches_real_swap_when_crossing_multiple_initialized_ticks() external;

    // ─── Exact Output ────────────────────────────────────────────────────────────
    function test_simulate_exact_output_matches_real_swap_inside_one_range() external;
    function test_simulate_exact_output_matches_real_swap_when_crossing_one_initialized_tick() external;
    function test_simulate_exact_output_matches_real_swap_when_crossing_multiple_initialized_ticks() external;

    // ─── Edge Cases ─────────────────────────────────────────────────────────────
    function test_simulate_handles_zero_liquidity_without_corrupting_fee_quote() external;
    function test_simulate_bubbles_pool_manager_extsload_failures() external;
    function test_simulate_matches_real_swap_in_both_directions() external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// POOLMANAGERINTEGRATION.SOL - ChainConfig PoolManager resolution and shape checks.
// Implemented in: test/Common/PoolManagerIntegration.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IPoolManagerIntegrationTests {
    function test_constructor_reads_pool_manager_from_chain_config() external;
    function test_constructor_reverts_when_pool_manager_has_no_code() external;
    function test_constructor_reverts_when_protocol_fee_controller_call_fails() external;
    function test_constructor_reverts_when_protocol_fee_controller_return_is_malformed() external;
    function test_constructor_reverts_when_extsload_call_fails() external;
    function test_constructor_reverts_when_empty_extsload_return_is_malformed() external;
    function test_constructor_reverts_when_empty_extsload_returns_non_empty_array() external;
    function test_constructor_reverts_when_erc6909_interface_check_fails() external;
    function test_constructor_reverts_when_pool_manager_does_not_support_erc6909() external;
    function test_constructor_accepts_valid_pool_manager_shape() external;
}

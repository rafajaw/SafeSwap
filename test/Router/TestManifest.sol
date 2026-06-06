// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title RouterTestManifest
 * @notice Test interface registry for SafeSwap router, hook registry, swaps, quoter, and treasury.
 * @dev Future test contracts in test/Router should implement the relevant interface below.
 */


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// HOOKREGISTRY.SOL - Hook clone authorization and config resolution.
// Implemented in: test/Router/HookRegistry.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IHookRegistryTests {
    // ─── Registration ───────────────────────────────────────────────────────────
    function test_register_hook_accepts_clone_with_approved_runtime_codehash() external;
    function test_register_hook_sets_registered_hook_flag() external;
    function test_register_hook_stores_hook_under_packed_config_key() external;
    function test_register_hook_emits_hook_registered_event() external;
    function test_register_hook_rejects_unapproved_runtime_codehash() external;
    function test_register_hook_rejects_when_approved_codehash_is_unset() external;
    function test_register_hook_rejects_eip7702_delegation_designator_codehash() external;
    function test_register_hook_rejects_valid_codehash_at_address_with_invalid_bcd_config() external;
    function test_register_hook_rejects_submitted_config_that_does_not_match_address() external;
    function test_register_hook_rejects_wrong_v4_permission_bitmap() external;
    function test_register_hook_allows_repeated_registration_by_same_hook() external;
    function test_register_hook_rejects_duplicate_config_from_different_hook() external;

    // ─── Resolution ─────────────────────────────────────────────────────────────
    function test_get_hook_returns_registered_hook_for_config() external;
    function test_get_hook_reverts_for_unregistered_config() external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SAFESWAPROUTER.SOL - Deployment, native receiver, and treasury.
// Implemented in: test/Router/SafeSwapRouter.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ISafeSwapRouterTests {
    // ─── Deployment And Native Receiver ─────────────────────────────────────────
    function test_constructor_reads_pool_manager_and_treasury_from_chain_config() external;
    function test_constructor_reverts_when_pool_manager_is_invalid() external;
    function test_constructor_reverts_when_initial_treasury_is_zero() external;
    function test_constructor_reverts_when_signing_descriptor_has_no_code() external;
    function test_receive_accepts_native_token_from_bondroute() external;
    function test_receive_accepts_native_token_from_pool_manager() external;
    function test_receive_reverts_for_unknown_sender() external;

    // ─── Treasury ───────────────────────────────────────────────────────────────
    function test_protocol_fee_recipient_is_router() external;
    function test_get_treasury_returns_current_treasury() external;
    function test_treasury_can_withdraw_erc20_protocol_fees() external;
    function test_treasury_can_withdraw_native_protocol_fees() external;
    function test_withdraw_protocol_fees_keeps_one_wei_in_contract() external;
    function test_withdraw_protocol_fees_returns_zero_when_balance_is_zero() external;
    function test_withdraw_protocol_fees_returns_zero_when_balance_is_one_wei() external;
    function test_withdraw_protocol_fees_reverts_when_recipient_is_zero() external;
    function test_withdraw_protocol_fees_reverts_when_erc20_transfer_fails() external;
    function test_withdraw_protocol_fees_reverts_when_native_transfer_fails() external;
    function test_non_treasury_cannot_withdraw_protocol_fees() external;
    function test_transfer_treasury_reverts_when_caller_is_not_current_treasury() external;
    function test_transfer_treasury_reverts_when_new_treasury_is_current_treasury() external;
    function test_transfer_treasury_can_cancel_pending_transfer_with_zero_address() external;
    function test_accept_treasury_reverts_when_caller_is_not_pending_treasury() external;
    function test_treasury_transfer_updates_authority() external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// USER.SOL / SWAP LIBRARIES - Exact input, exact output, quoting, and BondRoute integration.
// Implemented in: test/Router/User.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IUserSwapTests {
    // ─── Exact Input Swaps ──────────────────────────────────────────────────────
    function test_swap_exact_input_resolves_hook_from_pool_config() external;
    function test_swap_exact_input_reverts_when_hook_config_is_unregistered() external;
    function test_swap_exact_input_builds_dynamic_fee_pool_key() external;
    function test_swap_exact_input_sets_zero_for_one_from_token_order() external;
    function test_swap_exact_input_uses_full_range_sqrt_price_limit() external;
    function test_swap_exact_input_encodes_unlock_callback_as_exact_input_action() external;
    function test_swap_exact_input_reverts_when_funding_count_is_not_one() external;
    function test_swap_exact_input_reverts_when_input_token_equals_output_token() external;
    function test_swap_exact_input_settles_input_and_takes_output() external;
    function test_swap_exact_input_takes_protocol_fee_from_pool_output() external;
    function test_swap_exact_input_sends_net_output_to_bond_context_user() external;
    function test_swap_exact_input_reverts_when_net_output_is_below_minimum() external;
    function test_swap_exact_input_handles_native_input() external;
    function test_swap_exact_input_handles_native_output() external;

    // ─── Exact Output Swaps ─────────────────────────────────────────────────────
    function test_swap_exact_output_resolves_hook_from_pool_config() external;
    function test_swap_exact_output_reverts_when_hook_config_is_unregistered() external;
    function test_swap_exact_output_builds_dynamic_fee_pool_key() external;
    function test_swap_exact_output_sets_zero_for_one_from_token_order() external;
    function test_swap_exact_output_uses_full_range_sqrt_price_limit() external;
    function test_swap_exact_output_encodes_unlock_callback_as_exact_output_action() external;
    function test_swap_exact_output_reverts_when_funding_count_is_not_one() external;
    function test_swap_exact_output_grosses_up_output_for_protocol_fee() external;
    function test_swap_exact_output_sends_exact_net_output_to_user() external;
    function test_swap_exact_output_reverts_when_required_input_exceeds_maximum() external;
    function test_swap_exact_output_handles_native_input() external;
    function test_swap_exact_output_handles_native_output() external;
    function test_swap_exact_output_rounds_protocol_fee_without_underpaying_user() external;

    // ─── Unlock Callback Gate ───────────────────────────────────────────────────
    function test_unlock_callback_reverts_when_caller_is_not_pool_manager() external;

    // ─── Quoter ────────────────────────────────────────────────────────────────
    function test_quote_exact_input_uses_same_base_fee_simulation_as_hook() external;
    function test_quote_exact_input_reverts_when_amount_exceeds_int256_max() external;
    function test_quote_exact_input_returns_total_fee_pips_movement_and_net_output() external;
    function test_quote_exact_input_fee_matches_executed_fee() external;
    function test_quote_exact_input_net_output_matches_execution_with_two_pass_simulation() external;
    function test_quote_exact_output_grosses_up_requested_net_output() external;
    function test_quote_exact_output_reverts_when_grossed_output_exceeds_int256_max() external;
    function test_quote_exact_output_required_input_matches_execution() external;
    function test_quote_reverts_for_unregistered_hook_config() external;

    // ─── Pool Id View ──────────────────────────────────────────────────────────
    function test_off_chain_get_pool_id_matches_dynamic_fee_pool_key() external;
    function test_off_chain_get_pool_id_reverts_for_unregistered_config() external;

    // ─── BondRoute Integration ─────────────────────────────────────────────────
    function test_bondroute_selectors_are_only_swap_functions() external;
    function test_bondroute_quote_reverts_for_unsupported_call() external;
    function test_bondroute_quote_reverts_for_short_call_data() external;
    function test_bondroute_quote_exact_input_requires_one_funding() external;
    function test_bondroute_quote_exact_output_requires_one_funding() external;
    function test_bondroute_quote_uses_swap_stake_percentage() external;
    function test_bondroute_signing_info_hashes_pool_info_and_token_amounts_readably() external;
    function test_bondroute_signing_info_reverts_for_unsupported_call() external;
    function test_bondroute_signing_info_reverts_for_short_call_data() external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// USER.SOL / SWAP LIBRARIES - Full-workflow (Tier 1): real swaps through BondRoute + router + hook + a real V4 pool,
//   asserting the surplus repricing fee is applied live, quote == execution, protocol-fee accounting, and graceful
//   bond settlement on slippage. Internal-behavior / edge branches stay in the Tier-2 IUserSwapTests interface above.
// Implemented in: test/Router/UserSwap.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IUserSwapWorkflowTests {
    function test_swap_exact_input_pays_user_the_quoted_net_output() external;
    function test_swap_exact_input_takes_protocol_fee_to_the_router_treasury() external;
    function test_swap_exact_input_applies_a_repricing_fee_above_the_base_fee() external;
    function test_swap_exact_input_reverts_on_slippage_as_graceful_bond_settlement() external;
    function test_swap_exact_output_delivers_the_exact_net_output() external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// END TO END - Real-pool dynamic fee path fairness.
// Implemented in: test/Router/PathFairness.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IPathFairnessTests {
    function test_dynamic_fee_increases_fee_growth_for_crossed_and_exited_liquidity() external;
    function test_dynamic_fee_compensates_ranges_proportional_to_volume_served() external;
    function test_dynamic_fee_path_fairness_holds_for_both_swap_directions() external;
    function test_dynamic_fee_path_fairness_contrasts_with_donate_snapshot_behavior() external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title NftTestManifest
 * @notice Test interface registry for the SafeSwap PositionManager NFT.
 * @dev Future test contracts in test/Nft should implement the relevant interface below.
 */


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SAFESWAPNFT.SOL - Deployment, ERC721 metadata, position ownership, and BondRoute lifecycle.
// Implemented in: test/Nft/SafeSwapNft.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ISafeSwapNftTests {
    // ─── Deployment And Configuration ────────────────────────────────────────────
    function test_constructor_reads_canonical_router_from_chain_config() external;
    function test_constructor_reverts_when_router_has_no_code() external;
    function test_constructor_reverts_when_descriptor_has_no_code() external;
    function test_constructor_reverts_when_signing_descriptor_has_no_code() external;
    function test_first_token_id_is_derived_not_sequential() external;
    function test_constructor_uses_shared_pool_manager_from_chain_config() external;
    function test_inherits_bondroute_native_receive_for_native_fundings() external;
    function test_receive_reverts_on_unknown_direct_native_transfer() external;

    // ─── Create Position ────────────────────────────────────────────────────────
    function test_create_position_resolves_hook_from_router_registry() external;
    function test_create_position_builds_dynamic_fee_pool_key() external;
    function test_create_position_initializes_uninitialized_pool_at_signed_price() external;
    function test_create_position_reverts_when_initialized_pool_price_differs_from_signed_price() external;
    function test_create_position_mints_token_id_to_bond_context_user() external;
    function test_create_position_derives_distinct_token_id_per_mint() external;
    function test_create_position_uses_token_id_as_v4_position_salt() external;
    function test_create_position_stores_immutable_metadata() external;
    function test_create_position_reverts_when_fundings_do_not_exactly_match_declared_deposits() external;

    // ─── Add Liquidity ──────────────────────────────────────────────────────────
    function test_add_liquidity_requires_owner_or_approved_operator() external;
    function test_add_liquidity_allows_approved_token_address() external;
    function test_add_liquidity_allows_approved_operator() external;
    function test_add_liquidity_uses_stored_position_metadata() external;
    function test_add_liquidity_uses_existing_token_id_as_v4_salt() external;
    function test_add_liquidity_reverts_when_liquidity_is_zero() external;
    function test_add_liquidity_reverts_when_liquidity_exceeds_int128_max() external;
    function test_add_liquidity_reverts_when_fundings_do_not_exactly_match_declared_deposits() external;
    function test_add_liquidity_reverts_when_deposit_token_addresses_do_not_match_position_tokens() external;
    function test_add_liquidity_handles_one_sided_deposits_only_when_other_minimum_is_zero() external;
    function test_add_liquidity_reverts_when_one_sided_deposit_omits_required_token_minimum() external;

    // ─── Remove Liquidity ───────────────────────────────────────────────────────
    function test_remove_liquidity_requires_owner_or_approved_operator() external;
    function test_remove_liquidity_allows_approved_token_address() external;
    function test_remove_liquidity_sends_tokens_directly_to_bond_context_user() external;
    function test_remove_liquidity_reverts_when_liquidity_is_zero() external;
    function test_remove_liquidity_reverts_when_funding_count_is_not_zero() external;
    function test_remove_liquidity_records_earned_fees_without_counting_principal() external;

    // ─── Collect Fees ───────────────────────────────────────────────────────────
    function test_collect_fees_requires_owner_or_approved_operator() external;
    function test_collect_fees_uses_zero_liquidity_delta() external;
    function test_collect_fees_sends_tokens_directly_to_bond_context_user() external;
    function test_collect_fees_records_earned_fee_totals() external;
    function test_collect_fees_reverts_when_funding_count_is_not_zero() external;

    // ─── Metadata And Views ─────────────────────────────────────────────────────
    function test_get_lp_position_returns_stored_metadata_for_existing_token() external;
    function test_get_lp_position_reverts_for_missing_token() external;
    function test_off_chain_position_info_reads_v4_position_owned_by_nft() external;
    function test_unlock_callback_reverts_when_caller_is_not_pool_manager() external;
    function test_unlock_callback_executes_prepared_liquidity_modification() external;

    // ─── BondRoute Integration ──────────────────────────────────────────────────
    function test_bondroute_selectors_are_only_position_lifecycle_functions() external;
    function test_bondroute_quote_reverts_for_unsupported_call() external;
    function test_bondroute_quote_reverts_for_short_call_data() external;
    function test_bondroute_quote_create_uses_declared_deposits_instead_of_preferred_fundings() external;
    function test_bondroute_quote_create_computes_normalized_liquidity_stake() external;
    function test_bondroute_quote_add_uses_declared_deposits_instead_of_preferred_fundings() external;
    function test_bondroute_quote_add_computes_normalized_liquidity_stake_from_current_pool_price() external;
    function test_bondroute_quote_remove_requires_no_fundings() external;
    function test_bondroute_quote_remove_computes_stake_from_removed_liquidity_value() external;
    function test_bondroute_quote_collect_requires_no_fundings() external;
    function test_bondroute_quote_collect_computes_stake_from_one_unit_liquidity_value() external;
    function test_bondroute_signing_info_hashes_position_params_readably() external;
    function test_bondroute_signing_info_returns_create_position_offset() external;
    function test_bondroute_signing_info_returns_add_liquidity_offset() external;
    function test_bondroute_signing_info_returns_remove_liquidity_offset() external;
    function test_bondroute_signing_info_returns_collect_fees_offset() external;
    function test_signing_descriptor_returns_all_nft_message_values() external;
    function test_bondroute_signing_info_reverts_for_unsupported_call() external;
    function test_bondroute_signing_info_reverts_for_short_call_data() external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SAFESWAPNFT.SOL - Full-workflow (Tier 1): real BondRoute + real V4 PoolManager + real hook clone, asserting
//   on real on-chain effects (user balances, V4 position liquidity by salt = tokenId). Focused/edge branches that
//   need injected state stay in the Tier-2 interface above (test/Nft/SafeSwapNft.t.sol).
// Implemented in: test/Nft/SafeSwapNftWorkflow.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ISafeSwapNftWorkflowTests {
    function test_create_position_initializes_pool_deposits_liquidity_and_mints() external;
    function test_create_position_derives_distinct_token_ids() external;
    function test_add_liquidity_increases_the_v4_position() external;
    function test_remove_liquidity_returns_tokens_and_reduces_the_position() external;
    function test_collect_fees_executes_with_no_accrued_fees_and_leaves_liquidity() external;
    function test_remove_by_non_owner_is_protocol_reverted_and_position_is_untouched() external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SAFESWAPPOSITIONDESCRIPTOR.SOL - On-chain metadata renderer: tokenURI / contractURI return base64 data URIs whose
//   JSON and SVG are built fully on-chain. Verified against a real created position (real V4 PoolManager) by base64-
//   decoding the URIs and inspecting the JSON fields, attributes, and embedded SVG.
// Implemented in: test/Nft/SafeSwapPositionDescriptor.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ISafeSwapPositionDescriptorTests {
    function test_token_uri_returns_base64_json_with_name_description_and_attributes() external;
    function test_token_uri_attributes_self_locate_position() external;
    function test_token_uri_image_matches_investor_card_layout() external;
    function test_token_uri_image_renders_out_of_range_neutral_variant() external;
    function test_contract_uri_returns_collection_metadata() external;
    function test_token_uri_reverts_for_nonexistent_token() external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// STRINGHELPERLIB.SOL - Shared NFT metadata string formatting helpers.
// Implemented in: test/Nft/StringHelperLib.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IStringHelperLibTests {
    function test_epoch_zero() external;
    function test_one_day() external;
    function test_leap_year_date() external;
    function test_time_of_day() external;
    function test_zero_padding() external;
    function test_format_bps_as_percent_trims_insignificant_zeroes() external;
    function test_format_bps_as_percent_string_trims_insignificant_zeroes() external;

    // ─── Token amount formatting (display cap vs canonical FULL_PRECISION) ────────
    function test_format_token_amount_handles_zero_and_zero_decimal_tokens() external;
    function test_format_token_amount_caps_fraction_at_max_decimals() external;
    function test_format_token_amount_full_precision_is_lossless() external;
    function test_format_token_amount_full_precision_distinguishes_sub_cap_amounts() external;
    function test_format_token_amount_full_precision_renders_exact_sub_unit() external;
    function test_format_token_amount_groups_thousands() external;
    function test_format_token_amount_zero_max_decimals_renders_integer_only() external;
    function test_format_token_amount_reverts_on_unsupported_decimals() external;
    function test_format_symbol_amount_appends_symbol() external;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// PRICELIB.SOL - Price conversion, range-fill, and compact decimal formatting helpers.
// Implemented in: test/Nft/PriceLib.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IPriceLibTests {
    function test_price_one_equal_decimals() external;
    function test_price_one_more_token1_decimals() external;
    function test_price_one_more_token0_decimals() external;
    function test_zero_sqrt_price_is_zero() external;
    function test_tick_zero_matches_q96() external;
    function test_price_is_monotonic_in_tick() external;
    function test_eth_usdc_price_approx_3000() external;
    function test_fill_midpoint() external;
    function test_fill_clamps_below_and_above() external;
    function test_fill_degenerate_range() external;
    function test_format_zero() external;
    function test_format_thousands() external;
    function test_format_units_two_decimals() external;
    function test_format_sub_one_four_decimals() external;
    function test_format_tiny_plain_decimal_no_exponent() external;
}

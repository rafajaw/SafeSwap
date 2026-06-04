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
    function test_constructor_initializes_first_token_id_to_one() external;
    function test_constructor_uses_shared_pool_manager_from_chain_config() external;
    function test_inherits_bondroute_native_receive_for_native_fundings() external;
    function test_receive_reverts_on_unknown_direct_native_transfer() external;

    // ─── Create Position ────────────────────────────────────────────────────────
    function test_create_position_resolves_hook_from_router_registry() external;
    function test_create_position_reverts_when_router_hook_resolution_reverts() external;
    function test_create_position_builds_dynamic_fee_pool_key() external;
    function test_create_position_initializes_uninitialized_pool_at_signed_price() external;
    function test_create_position_reverts_when_initialized_pool_price_differs_from_signed_price() external;
    function test_create_position_mints_token_id_to_bond_context_user() external;
    function test_create_position_increments_token_id_after_each_mint() external;
    function test_create_position_uses_token_id_as_v4_position_salt() external;
    function test_create_position_stores_immutable_metadata() external;
    function test_create_position_sorts_token_fundings_into_token0_and_token1() external;
    function test_create_position_reverts_when_liquidity_is_zero() external;
    function test_create_position_reverts_when_liquidity_exceeds_int128_max() external;
    function test_create_position_reverts_when_funding_count_is_not_two() external;
    function test_create_position_reverts_when_minimum_token_addresses_do_not_match_pool_tokens() external;
    function test_create_position_reverts_when_registered_hook_is_missing() external;
    function test_create_position_settles_erc20_deposits_into_pool_manager() external;
    function test_create_position_settles_native_deposits_through_nft_then_pool_manager() external;

    // ─── Add Liquidity ──────────────────────────────────────────────────────────
    function test_add_liquidity_requires_owner_or_approved_operator() external;
    function test_add_liquidity_allows_approved_token_address() external;
    function test_add_liquidity_allows_approved_operator() external;
    function test_add_liquidity_uses_stored_position_metadata() external;
    function test_add_liquidity_reverts_when_position_metadata_does_not_match_stored_pool_info() external;
    function test_add_liquidity_reverts_when_position_ticks_do_not_match_stored_ticks() external;
    function test_add_liquidity_uses_existing_token_id_as_v4_salt() external;
    function test_add_liquidity_reverts_when_liquidity_is_zero() external;
    function test_add_liquidity_reverts_when_liquidity_exceeds_int128_max() external;
    function test_add_liquidity_reverts_when_funding_count_is_not_two() external;
    function test_add_liquidity_reverts_when_minimum_token_addresses_do_not_match_position_tokens() external;
    function test_add_liquidity_enforces_minimum_deposit_amounts() external;
    function test_add_liquidity_handles_one_sided_deposits_only_when_other_minimum_is_zero() external;
    function test_add_liquidity_reverts_when_one_sided_deposit_omits_required_token_minimum() external;

    // ─── Remove Liquidity ───────────────────────────────────────────────────────
    function test_remove_liquidity_requires_owner_or_approved_operator() external;
    function test_remove_liquidity_allows_approved_token_address() external;
    function test_remove_liquidity_allows_approved_operator() external;
    function test_remove_liquidity_sends_tokens_directly_to_bond_context_user() external;
    function test_remove_liquidity_enforces_minimum_received_amounts() external;
    function test_remove_liquidity_reverts_when_liquidity_is_zero() external;
    function test_remove_liquidity_reverts_when_liquidity_exceeds_int128_max() external;
    function test_remove_liquidity_reverts_when_funding_count_is_not_zero() external;
    function test_remove_liquidity_reverts_when_minimum_token_addresses_do_not_match_position_tokens() external;
    function test_remove_liquidity_handles_native_token_outputs_directly_to_user() external;

    // ─── Collect Fees ───────────────────────────────────────────────────────────
    function test_collect_fees_requires_owner_or_approved_operator() external;
    function test_collect_fees_allows_approved_token_address() external;
    function test_collect_fees_allows_approved_operator() external;
    function test_collect_fees_uses_zero_liquidity_delta() external;
    function test_collect_fees_sends_tokens_directly_to_bond_context_user() external;
    function test_collect_fees_enforces_minimum_received_amounts() external;
    function test_collect_fees_reverts_when_funding_count_is_not_zero() external;
    function test_collect_fees_reverts_when_minimum_token_addresses_do_not_match_position_tokens() external;

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
    function test_bondroute_quote_create_requires_two_fundings() external;
    function test_bondroute_quote_create_computes_normalized_liquidity_stake() external;
    function test_bondroute_quote_add_requires_two_fundings() external;
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
    function test_create_position_uses_incrementing_token_ids() external;
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
    function test_token_uri_image_is_a_fully_on_chain_svg() external;
    function test_contract_uri_returns_collection_metadata() external;
    function test_token_uri_reverts_for_nonexistent_token() external;
}

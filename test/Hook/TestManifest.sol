// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title HookTestManifest
 * @notice Test interface registry for SafeSwap hook implementation and clone behavior.
 * @dev Future test contracts in test/Hook should implement the relevant interface below.
 */


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SAFESWAPHOOKIMPL.SOL - Clone context, registration, callback gates, and dynamic fee override.
// Implemented in: test/Hook/SafeSwapHookImpl.t.sol
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ISafeSwapHookImplTests {
    // ─── Clone And Implementation Context ───────────────────────────────────────
    function test_implementation_reverts_when_called_directly() external;
    function test_constructor_reads_pool_manager_router_and_nft_from_chain_config() external;
    function test_constructor_reverts_when_pool_manager_has_no_code() external;
    function test_constructor_reverts_when_router_has_no_code() external;
    function test_constructor_reverts_when_nft_has_no_code() external;
    function test_clone_getters_decode_base_fee_and_rebate_percent_from_clone_address() external;
    function test_clone_getters_revert_when_clone_address_does_not_encode_valid_config() external;
    function test_clone_runtime_codehash_is_shared_across_config_instances() external;
    function test_clone_runtime_codehash_changes_when_implementation_address_changes() external;

    // ─── Registration ───────────────────────────────────────────────────────────
    function test_initialize_once_registers_clone_with_router() external;
    function test_initialize_once_passes_decoded_base_fee_and_rebate_percent() external;
    function test_initialize_once_is_idempotent_for_same_registered_clone() external;
    function test_initialize_once_bubbles_router_registration_revert() external;
    function test_initialize_once_reverts_when_called_on_implementation() external;

    // ─── Permissionless Hook Deployment (deploy_hook) ───────────────────────────
    function test_get_hook_config_reverts_when_called_on_implementation() external;
    function test_clone_deploys_exact_canonical_eip1167_runtime_bytecode() external;
    function test_deploy_hook_reverts_when_a_contract_already_exists_at_the_salt_address() external;
    function test_deploy_hook_reverts_when_the_salt_address_is_not_a_valid_hook_config() external;
    function test_deploy_hook_forwards_to_the_implementation_when_called_on_a_clone() external;
    // NOTE: deploy_hook's success path (CREATE2 clone -> initialize_once registration -> HookSpawned event) and its
    //       CONFIG_MISMATCH / PERMISSIONS rejections all require the CREATE2 clone address to carry the HookAddress BCD
    //       config AND the exact V4 permission bits. A fully valid hook address costs ~2^38 to mine (24 BCD bits + 14
    //       permission bits), which is infeasible inside the unit suite. Those paths are exercised by the deploy/mining
    //       script (see TODO.md "Deploy tooling") against real mined salts. The guards above are address-shape independent
    //       and cover every deploy_hook branch reachable without a mined address: the implementation/clone forwarding
    //       split, the already-deployed collision guard, and the invalid-config decode revert.

    // ─── Initialize And Liquidity Callback Gates ────────────────────────────────
    function test_before_initialize_allows_only_pool_manager_call_with_nft_sender() external;
    function test_before_initialize_reverts_when_sender_is_not_nft() external;
    function test_before_initialize_reverts_when_caller_is_not_pool_manager() external;
    function test_before_add_liquidity_allows_only_pool_manager_call_with_nft_sender() external;
    function test_before_add_liquidity_reverts_when_sender_is_not_nft() external;
    function test_before_add_liquidity_reverts_when_caller_is_not_pool_manager() external;
    function test_before_remove_liquidity_allows_only_pool_manager_call_with_nft_sender() external;
    function test_before_remove_liquidity_reverts_when_sender_is_not_nft() external;
    function test_before_remove_liquidity_reverts_when_caller_is_not_pool_manager() external;

    // ─── Swap Callback Gate ─────────────────────────────────────────────────────
    function test_before_swap_allows_only_pool_manager_call_with_router_sender() external;
    function test_before_swap_reverts_when_sender_is_not_router() external;
    function test_before_swap_reverts_when_caller_is_not_pool_manager() external;

    // ─── Dynamic Fee Override ───────────────────────────────────────────────────
    function test_before_swap_returns_override_fee_with_base_fee_when_movement_is_zero() external;
    function test_before_swap_returns_override_fee_with_repricing_component_when_swap_moves_price() external;
    function test_before_swap_returns_zero_before_swap_delta() external;
    function test_before_swap_returns_before_swap_selector() external;
    function test_before_swap_reverts_when_repricing_fee_exceeds_v4_limit() external;
    function test_before_swap_uses_config_from_hook_address_not_hook_data() external;
    function test_before_swap_uses_pre_swap_pool_state() external;

    // ─── V4 Permissions ─────────────────────────────────────────────────────────
    function test_required_permissions_include_initialize_add_remove_and_swap() external;
    function test_required_permissions_exclude_before_donate() external;
    function test_hook_permission_validation_rejects_addresses_with_extra_permission_bits() external;
}

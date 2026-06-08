// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IHookRegistryTests } from "@test/Router/TestManifest.sol";
import { ChainConfigTestHelper } from "@test/helpers/ChainConfigTestHelper.t.sol";
import { SafeSwapTestHelper } from "@test/helpers/SafeSwapTestHelper.t.sol";

import "@SafeSwapCommon/Definitions.sol";
import { HookAddress } from "@SafeSwapCommon/HookAddress.sol";
import {
    HookRegistry,
    HookRegistered,
    UnauthorizedHookCode,
    HookConfigMismatch,
    HookPermissionsMismatch,
    HookConfigAlreadyRegistered,
    HookConfigNotRegistered
} from "@SafeSwapRouter/HookRegistry.sol";
import { KeyNotSet } from "@ChainConfig/IChainConfig.sol";


contract HookRegistryHarness is HookRegistry {
}


/**
 * @title HookRegistryTest
 * @notice Focused tests for config-hook registration and lookup. The hook runtime is synthetic here because the registry
 *         authorizes by exact codehash plus address bits; hook callback behavior is covered in the hook implementation suite.
 */
contract HookRegistryTest is IHookRegistryTests, ChainConfigTestHelper, SafeSwapTestHelper {

    address internal constant _EIP7702_DELEGATE  =  address(0x7702);

    uint16 internal constant _BASE_FEE_BPS     =  30;
    uint8  internal constant _CAPTURE_PERCENT  =  50;
    uint160 internal constant _SALT_BIT        =  uint160(1) << 80;

    bytes internal constant _APPROVED_RUNTIME  =  hex"600160005260206000f3";
    bytes internal constant _OTHER_RUNTIME     =  hex"600260005260206000f3";

    HookRegistryHarness internal _registry;
    address internal _hook;

    function setUp( ) public
    {
        vm.chainId( 31_337 );
        vm.warp( _DEFAULT_CONFIG_TIMESTAMP + 1 days );

        _deploy_chain_config( );

        _registry  =  new HookRegistryHarness();
        _hook      =  _hook_address( _BASE_FEE_BPS, _CAPTURE_PERCENT, HookAddress.REQUIRED_PERMISSIONS );

        _etch_runtime( _hook, _APPROVED_RUNTIME );
    }


    // ━━━━  REGISTRATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_register_hook_accepts_clone_with_approved_runtime_codehash( )
    external
    {
        _publish_approved_runtime( );

        _register_from_hook( _hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );

        assertEq( _registry.get_hook_address( _BASE_FEE_BPS, _CAPTURE_PERCENT ), _hook, "approved hook should register for its config." );
    }

    function test_get_hook_config_returns_config_for_registered_hook( )
    external
    {
        _publish_approved_runtime( );

        _register_from_hook( _hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );

        ( uint16 base_fee_bps, uint8 rebate_percent )  =  _registry.get_hook_config( _hook );
        assertEq( base_fee_bps, _BASE_FEE_BPS, "get_hook_config should decode the registered hook's base fee." );
        assertEq( rebate_percent, _CAPTURE_PERCENT, "get_hook_config should decode the registered hook's capture." );
    }

    function test_get_hook_config_reverts_for_unregistered_hook( )
    external
    {
        vm.expectRevert( abi.encodeWithSelector( HookConfigNotRegistered.selector, _BASE_FEE_BPS, _CAPTURE_PERCENT ) );
        _registry.get_hook_config( _hook );
    }

    function test_register_hook_emits_hook_registered_event( )
    external
    {
        _publish_approved_runtime( );

        vm.expectEmit( true, true, true, true );
        emit HookRegistered( _hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );

        _register_from_hook( _hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );
    }

    function test_register_hook_rejects_unapproved_runtime_codehash( )
    external
    {
        _publish_approved_runtime( );

        _etch_runtime( _hook, _OTHER_RUNTIME );

        vm.expectRevert( abi.encodeWithSelector( UnauthorizedHookCode.selector, _hook, keccak256(_OTHER_RUNTIME) ) );
        _register_from_hook( _hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );
    }

    function test_register_hook_rejects_when_approved_codehash_is_unset( )
    external
    {
        HookRegistryHarness registry_without_config  =  new HookRegistryHarness();

        vm.expectRevert( abi.encodeWithSelector( KeyNotSet.selector, CONFIG_SIGNER, SAFESWAP_HOOK_CODEHASH_KEY ) );
        vm.prank( _hook );
        registry_without_config.register_hook( _BASE_FEE_BPS, _CAPTURE_PERCENT );
    }

    function test_register_hook_rejects_eip7702_delegation_designator_codehash( )
    external
    {
        _publish_approved_runtime( );

        bytes memory delegation_designator  =  abi.encodePacked( hex"ef0100", _EIP7702_DELEGATE );
        _etch_runtime( _hook, delegation_designator );

        vm.expectRevert( abi.encodeWithSelector( UnauthorizedHookCode.selector, _hook, keccak256(delegation_designator) ) );
        _register_from_hook( _hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );
    }

    function test_register_hook_rejects_valid_codehash_at_address_with_invalid_bcd_config( )
    external
    {
        _publish_approved_runtime( );

        address invalid_hook  =  _hook_address_with_config_nibbles( 0xE, 0, 3, 0, HookAddress.CAPTURE_MARKER, 5, HookAddress.REQUIRED_PERMISSIONS );
        _etch_runtime( invalid_hook, _APPROVED_RUNTIME );

        vm.expectRevert( abi.encodeWithSelector( HookAddress.InvalidHookConfig.selector, invalid_hook ) );
        _register_from_hook( invalid_hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );
    }

    function test_register_hook_rejects_submitted_config_that_does_not_match_address( )
    external
    {
        _publish_approved_runtime( );

        vm.expectRevert( abi.encodeWithSelector( HookConfigMismatch.selector, _hook, _BASE_FEE_BPS, _CAPTURE_PERCENT, 45, _CAPTURE_PERCENT ) );
        _register_from_hook( _hook, 45, _CAPTURE_PERCENT );
    }

    function test_register_hook_rejects_wrong_v4_permission_bitmap( )
    external
    {
        _publish_approved_runtime( );

        address hook_with_wrong_permissions  =  _hook_address( _BASE_FEE_BPS, _CAPTURE_PERCENT, HookAddress.REQUIRED_PERMISSIONS | uint160(1 << 5) );
        _etch_runtime( hook_with_wrong_permissions, _APPROVED_RUNTIME );

        vm.expectRevert( abi.encodeWithSelector( HookPermissionsMismatch.selector, hook_with_wrong_permissions ) );
        _register_from_hook( hook_with_wrong_permissions, _BASE_FEE_BPS, _CAPTURE_PERCENT );
    }

    function test_register_hook_allows_repeated_registration_by_same_hook( )
    external
    {
        _publish_approved_runtime( );

        _register_from_hook( _hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );
        _register_from_hook( _hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );

        assertEq( _registry.get_hook_address( _BASE_FEE_BPS, _CAPTURE_PERCENT ), _hook, "same hook should remain registered for the config." );
    }

    function test_register_hook_rejects_duplicate_config_from_different_hook( )
    external
    {
        _publish_approved_runtime( );

        address duplicate_hook  =  address( uint160(_hook) | _SALT_BIT );
        _etch_runtime( duplicate_hook, _APPROVED_RUNTIME );

        _register_from_hook( _hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );

        vm.expectRevert( abi.encodeWithSelector( HookConfigAlreadyRegistered.selector, _BASE_FEE_BPS, _CAPTURE_PERCENT, _hook ) );
        _register_from_hook( duplicate_hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );
    }


    // ━━━━  RESOLUTION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_get_hook_address_returns_registered_hook_for_config( )
    external
    {
        _publish_approved_runtime( );

        _register_from_hook( _hook, _BASE_FEE_BPS, _CAPTURE_PERCENT );

        assertEq( _registry.get_hook_address( _BASE_FEE_BPS, _CAPTURE_PERCENT ), _hook, "get_hook_address should return the registered hook." );
    }

    function test_get_hook_address_reverts_for_unregistered_config( )
    external
    {
        vm.expectRevert( abi.encodeWithSelector( HookConfigNotRegistered.selector, _BASE_FEE_BPS, _CAPTURE_PERCENT ) );
        _registry.get_hook_address( _BASE_FEE_BPS, _CAPTURE_PERCENT );
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _register_from_hook( address hook, uint16 base_fee_bps, uint8 capture_percent ) internal
    {
        vm.prank( hook );
        _registry.register_hook( base_fee_bps, capture_percent );
    }

    function _publish_approved_runtime( ) internal
    {
        _publish_config_bytes32( SAFESWAP_HOOK_CODEHASH_KEY, keccak256(_APPROVED_RUNTIME) );
    }

    function _etch_runtime( address account, bytes memory runtime ) internal
    {
        vm.etch( account, runtime );
    }
}

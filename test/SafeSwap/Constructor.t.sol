// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";
import { Hooks } from "@UniswapV4Core/libraries/Hooks.sol";

contract NotPoolManager { }


contract ConstructorTest is SafeSwapTestBase {
    function test_constructor_sets_collector_correctly( ) external view
    {
        assertEq(
            hook.get_collector( ),
            collector,
            "Constructor should set collector from ChainConfig."
        );
    }

    function test_constructor_reverts_if_pool_manager_not_set( ) external
    {
        // Clear pool manager entry in ChainConfig.
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, POOL_MANAGER_KEY, address(0) );

        vm.expectRevert( bytes("SafeSwap: Invalid pool_manager") );
        deployCodeTo( "TestBase.t.sol:TestableSafeSwap", address(uint160(0x4AA0)) );

        // Restore pool manager entry.
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, POOL_MANAGER_KEY, address(pool_manager) );
    }

    function test_constructor_reverts_if_chain_config_points_to_non_pool_manager( ) external
    {
        NotPoolManager not_pool_manager  =  new NotPoolManager( );

        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, POOL_MANAGER_KEY, address(not_pool_manager) );

        vm.expectRevert( bytes("SafeSwap: Invalid pool_manager") );
        deployCodeTo( "TestBase.t.sol:TestableSafeSwap", address(uint160(0x4AA0)) );

        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, POOL_MANAGER_KEY, address(pool_manager) );
    }

    function test_constructor_reverts_if_initial_collector_not_set( ) external
    {
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, INITIAL_COLLECTOR_KEY, address(0) );

        vm.expectRevert( bytes("SafeSwap: Invalid initial_collector") );
        deployCodeTo( "TestBase.t.sol:TestableSafeSwap", address(uint160(0x4AA0)) );

        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, INITIAL_COLLECTOR_KEY, collector );
    }

    function test_constructor_reverts_if_hook_address_has_wrong_flags( ) external
    {
        // V4's Hooks.validateHookPermissions reverts with HookAddressNotValid(address) when the deployment
        // address bits don't match the declared Permissions struct. Use partial match because the address
        // argument depends on the test contract's deployment nonce.
        vm.expectPartialRevert( Hooks.HookAddressNotValid.selector );
        new TestableSafeSwap( );
    }

    function test_constructor_announces_protocol_to_bondroute( ) external
    {
        // The announcement happens during construction.
        // We verify by deploying a new hook and checking the event.
        vm.expectEmit( true, true, true, true, BONDROUTE_ADDRESS );
        emit MockBondRoute.ProtocolAnnounced( SAFESWAP_PROTOCOL_NAME, SAFESWAP_PROTOCOL_DESCRIPTION );

        deployCodeTo( "TestBase.t.sol:TestableSafeSwap", address(uint160(0x4AA0)) );
    }
}

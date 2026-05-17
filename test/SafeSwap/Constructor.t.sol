// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";

contract NotPoolManager { }


contract ConstructorTest is SafeSwapTestBase {
    function test_constructor_sets_pool_manager_from_chain_config( ) external view
    {
        assertEq(
            address(hook.PoolManager( )),
            address(pool_manager),
            "Constructor should set PoolManager from ChainConfig."
        );
    }

    function test_constructor_sets_collector_correctly( ) external view
    {
        assertEq(
            hook.collector( ),
            collector,
            "Constructor should set collector to initial_collector parameter."
        );
    }

    function test_constructor_reverts_if_pool_manager_not_set( ) external
    {
        // Clear pool manager entry in ChainConfig.
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( collector, POOL_MANAGER_KEY, address(0) );

        vm.expectRevert( bytes("SafeSwap: Invalid pool_manager") );
        deployCodeTo( "TestBase.t.sol:TestableSafeSwap", abi.encode( collector ), address(uint160(0x4AA0)) );

        // Restore pool manager entry.
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( collector, POOL_MANAGER_KEY, address(pool_manager) );
    }

    function test_constructor_reverts_if_chain_config_points_to_non_pool_manager( ) external
    {
        NotPoolManager not_pool_manager  =  new NotPoolManager( );

        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( collector, POOL_MANAGER_KEY, address(not_pool_manager) );

        vm.expectRevert( bytes("SafeSwap: Invalid pool_manager") );
        deployCodeTo( "TestBase.t.sol:TestableSafeSwap", abi.encode( collector ), address(uint160(0x4AA0)) );

        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( collector, POOL_MANAGER_KEY, address(pool_manager) );
    }

    function test_constructor_reverts_if_hook_address_has_wrong_flags( ) external
    {
        vm.expectRevert( bytes("SafeSwap: Invalid hook address") );
        new TestableSafeSwap( collector );
    }

    function test_constructor_announces_protocol_to_bondroute( ) external
    {
        // The announcement happens during construction.
        // We verify by deploying a new hook and checking the event.
        vm.expectEmit( true, true, true, true, BONDROUTE_ADDRESS );
        emit MockBondRoute.ProtocolAnnounced( "SafeSwap", "Trustless MEV-free Uniswap V4 Hook" );

        deployCodeTo( "TestBase.t.sol:TestableSafeSwap", abi.encode( collector ), address(uint160(0x4AA0)) );
    }
}

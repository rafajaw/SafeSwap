// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract ConstructorTest is SafeSwapTestBase {

    function test_constructor_sets_pool_manager_from_open_storage( ) external view
    {
        assertEq(
            address(hook.PoolManager( )),
            address(pool_manager),
            "Constructor should set PoolManager from OpenStorage."
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
        // Deploy new OpenStorage without pool manager set.
        MockOpenStorage empty_storage  =  new MockOpenStorage( );

        // Etch empty storage to OpenStorage address.
        vm.etch( address(0x00000000000000004F70656E53746F72616765), address(empty_storage).code );

        // Clear the pool manager slot.
        bytes32 pm_slot  =  keccak256( abi.encode( POOL_MANAGER_KEY, uint256(0) ) );
        vm.store( address(0x00000000000000004F70656E53746F72616765), pm_slot, bytes32(0) );

        vm.expectRevert( PoolManagerNotSet.selector );
        new TestableSafeSwap( collector );

        // Restore original storage.
        vm.store( address(0x00000000000000004F70656E53746F72616765), pm_slot, bytes32(uint256(uint160(address(pool_manager)))) );
    }

    function test_constructor_announces_protocol_to_bondroute( ) external
    {
        // The announcement happens during construction.
        // We verify by deploying a new hook and checking the event.
        vm.expectEmit( true, true, true, true, BONDROUTE_ADDRESS );
        emit MockBondRoute.ProtocolAnnounced( "SafeSwap", "Trustless MEV-free Uniswap V4 Hook" );

        new TestableSafeSwap( collector );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract CollectorTest is SafeSwapTestBase {

    function test_get_collector_returns_initial_collector( ) external view
    {
        assertEq(
            hook.get_collector( ),
            collector,
            "get_collector should return the initial collector set in constructor."
        );
    }

    function test_transfer_collector_sets_pending( ) external
    {
        address new_collector  =  makeAddr( "new_collector" );

        vm.prank( collector );
        hook.transfer_collector( new_collector );

        assertEq(
            hook.get_collector( ),
            collector,
            "collector should not change until accepted."
        );

        // Pending was set: the nominee can complete the transfer without revert.
        vm.prank( new_collector );
        hook.accept_collector( );
    }

    function test_accept_collector_completes_transfer( ) external
    {
        address new_collector  =  makeAddr( "new_collector" );

        vm.prank( collector );
        hook.transfer_collector( new_collector );

        vm.prank( new_collector );
        hook.accept_collector( );

        assertEq(
            hook.get_collector( ),
            new_collector,
            "collector should be updated after accept_collector."
        );

        // Pending was cleared: a second accept reverts with the expected zero pending address.
        vm.prank( new_collector );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, new_collector, address(0) ) );
        hook.accept_collector( );
    }

    function test_transfer_collector_reverts_for_non_collector( ) external
    {
        address new_collector  =  makeAddr( "new_collector" );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, collector ) );
        hook.transfer_collector( new_collector );
    }

    function test_accept_collector_reverts_for_non_pending( ) external
    {
        address new_collector  =  makeAddr( "new_collector" );

        vm.prank( collector );
        hook.transfer_collector( new_collector );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, new_collector ) );
        hook.accept_collector( );
    }
}

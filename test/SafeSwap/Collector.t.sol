// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract CollectorTest is SafeSwapTestBase {

    function test_collector_returns_initial_collector( ) external view
    {
        assertEq(
            hook.collector( ),
            collector,
            "collector() should return the initial collector set in constructor."
        );
    }

    function test_transfer_collector_sets_pending( ) external
    {
        address new_collector  =  makeAddr( "new_collector" );

        vm.prank( collector );
        hook.transfer_collector( new_collector );

        assertEq(
            hook.pending_collector( ),
            new_collector,
            "pending_collector should be set after transfer_collector."
        );

        assertEq(
            hook.collector( ),
            collector,
            "collector should not change until accepted."
        );
    }

    function test_accept_collector_completes_transfer( ) external
    {
        address new_collector  =  makeAddr( "new_collector" );

        vm.prank( collector );
        hook.transfer_collector( new_collector );

        vm.prank( new_collector );
        hook.accept_collector( );

        assertEq(
            hook.collector( ),
            new_collector,
            "collector should be updated after accept_collector."
        );

        assertEq(
            hook.pending_collector( ),
            address(0),
            "pending_collector should be cleared after accept."
        );
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract TreasuryTest is SafeSwapTestBase {

    function test_get_treasury_returns_initial_treasury( ) external view
    {
        assertEq(
            hook.get_treasury( ),
            treasury,
            "get_treasury should return the initial treasury set in constructor."
        );
    }

    function test_transfer_treasury_sets_pending( ) external
    {
        address new_treasury  =  makeAddr( "new_treasury" );

        vm.prank( treasury );
        hook.transfer_treasury( new_treasury );

        assertEq(
            hook.get_treasury( ),
            treasury,
            "treasury should not change until accepted."
        );

        // Pending was set: the nominee can complete the transfer without revert.
        vm.prank( new_treasury );
        hook.accept_treasury( );
    }

    function test_accept_treasury_completes_transfer( ) external
    {
        address new_treasury  =  makeAddr( "new_treasury" );

        vm.prank( treasury );
        hook.transfer_treasury( new_treasury );

        vm.prank( new_treasury );
        hook.accept_treasury( );

        assertEq(
            hook.get_treasury( ),
            new_treasury,
            "treasury should be updated after accept_treasury."
        );

        // Pending was cleared: a second accept reverts with the expected zero pending address.
        vm.prank( new_treasury );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, new_treasury, address(0) ) );
        hook.accept_treasury( );
    }

    function test_transfer_treasury_reverts_for_non_treasury( ) external
    {
        address new_treasury  =  makeAddr( "new_treasury" );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, treasury ) );
        hook.transfer_treasury( new_treasury );
    }

    function test_transfer_treasury_reverts_for_current_treasury( ) external
    {
        vm.prank( treasury );
        vm.expectRevert( abi.encodeWithSelector( Invalid.selector, "new_treasury", uint256(uint160(treasury)) ) );
        hook.transfer_treasury( treasury );
    }

    function test_accept_treasury_reverts_for_non_pending( ) external
    {
        address new_treasury  =  makeAddr( "new_treasury" );

        vm.prank( treasury );
        hook.transfer_treasury( new_treasury );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, new_treasury ) );
        hook.accept_treasury( );
    }
}

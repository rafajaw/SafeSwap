// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract DonateExecutionTest is SafeSwapTestBase {

    function test_donate_transfers_token0_to_pool( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 0 );
        DonateParams memory params  =  _create_donate_params( );

        pool_manager.set_mock_donate_amounts( -100 ether, 0 );

        uint256 user_token0_before  =  token0.balanceOf( user );

        hook.test_execute_donate( context, params );

        assertEq( user_token0_before - token0.balanceOf( user ), 0, "Mock BondRoute skips actual transfer." );
    }

    function test_donate_transfers_token1_to_pool( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 0, 100 ether );
        DonateParams memory params  =  _create_donate_params( );

        pool_manager.set_mock_donate_amounts( 0, -100 ether );

        hook.test_execute_donate( context, params );
    }

    function test_donate_transfers_both_tokens_to_pool( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 200 ether );
        DonateParams memory params  =  _create_donate_params( );

        pool_manager.set_mock_donate_amounts( -100 ether, -200 ether );

        hook.test_execute_donate( context, params );
    }
}

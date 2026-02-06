// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract FeeWithdrawalTest is SafeSwapTestBase {

    // ━━━━  withdraw_fees( )  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_withdraw_fees_transfers_erc20_to_recipient( ) external
    {
        token0.mint( address(hook), 100 ether );

        uint256 recipient_balance_before  =  token0.balanceOf( treasury );

        vm.prank( collector );
        hook.withdraw_fees( token0, treasury );

        uint256 recipient_balance_after  =  token0.balanceOf( treasury );

        assertEq(
            recipient_balance_after - recipient_balance_before,
            100 ether,
            "Recipient should receive balance minus 1 wei."
        );
    }

    function test_withdraw_fees_transfers_native_to_recipient( ) external
    {
        // Send ETH to hook.
        vm.deal( address(hook), 100 ether );

        uint256 recipient_balance_before  =  treasury.balance;

        vm.prank( collector );
        hook.withdraw_fees( NATIVE_TOKEN, treasury );

        uint256 recipient_balance_after  =  treasury.balance;

        // Should receive 100 - 1 wei.
        assertEq(
            recipient_balance_after - recipient_balance_before,
            100 ether - 1,
            "Recipient should receive native balance minus 1 wei."
        );
    }

    function test_withdraw_fees_reverts_if_not_collector( ) external
    {
        token0.mint( address(hook), 100 ether );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, collector ) );
        hook.withdraw_fees( token0, treasury );
    }

    function test_withdraw_fees_keeps_1_wei_for_gas_optimization( ) external
    {
        token0.mint( address(hook), 100 ether );

        vm.prank( collector );
        hook.withdraw_fees( token0, treasury );

        uint256 remaining_balance  =  token0.balanceOf( address(hook) );

        assertEq(
            remaining_balance,
            1,
            "Should keep exactly 1 wei for gas optimization."
        );
    }

    function test_withdraw_fees_no_op_if_balance_is_1_or_less( ) external
    {
        uint256 recipient_balance_before  =  token0.balanceOf( treasury );

        vm.prank( collector );
        hook.withdraw_fees( token0, treasury );

        uint256 recipient_balance_after  =  token0.balanceOf( treasury );

        assertEq(
            recipient_balance_after,
            recipient_balance_before,
            "No transfer when balance is 1 or less."
        );
    }

    function test_withdraw_fees_reverts_on_failed_native_transfer( ) external
    {
        vm.deal( address(hook), 100 ether );

        RejectingRecipient rejector  =  new RejectingRecipient( );

        vm.prank( collector );
        vm.expectRevert( abi.encodeWithSelector( TransferFailed.selector, address(NATIVE_TOKEN), address(rejector), 100 ether - 1 ) );
        hook.withdraw_fees( NATIVE_TOKEN, address(rejector) );
    }

    function test_withdraw_fees_reverts_on_failed_erc20_transfer( ) external
    {
        failing_token.mint( address(hook), 100 ether );
        failing_token.set_should_fail( true );

        vm.prank( collector );
        vm.expectRevert( abi.encodeWithSelector( TransferFailed.selector, address(failing_token), treasury, 100 ether - 1 ) );
        hook.withdraw_fees( IERC20(address(failing_token)), treasury );
    }


    // ━━━━  receive( )  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_receive_accepts_native_token( ) external
    {
        uint256 balance_before  =  address(hook).balance;

        vm.deal( user, 10 ether );
        vm.prank( user );
        ( bool success, )  =  address(hook).call{ value: 10 ether }( "" );

        assertTrue( success, "Hook should accept native token." );
        assertEq(
            address(hook).balance,
            balance_before + 10 ether,
            "Hook balance should increase."
        );
    }


    // ━━━━  Multi-Token Withdrawal  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_withdraw_fees_multiple_tokens_sequentially( ) external
    {
        token0.mint( address(hook), 100 ether );
        token1.mint( address(hook), 200 ether );

        vm.startPrank( collector );

        hook.withdraw_fees( token0, treasury );
        hook.withdraw_fees( token1, treasury );

        vm.stopPrank( );

        // +1 accounts for dust initialized in setUp.
        assertEq(
            token0.balanceOf( treasury ),
            100 ether + 1,
            "Treasury should receive token0."
        );
        assertEq(
            token1.balanceOf( treasury ),
            200 ether + 1,
            "Treasury should receive token1."
        );
    }

    function test_withdraw_fees_to_different_recipients( ) external
    {
        token0.mint( address(hook), 100 ether );
        token1.mint( address(hook), 200 ether );

        address recipient1  =  makeAddr( "recipient1" );
        address recipient2  =  makeAddr( "recipient2" );

        vm.startPrank( collector );

        hook.withdraw_fees( token0, recipient1 );
        hook.withdraw_fees( token1, recipient2 );

        vm.stopPrank( );

        // Hook has dust from setUp, so transfers full minted amount.
        assertEq(
            token0.balanceOf( recipient1 ),
            100 ether,
            "Recipient1 should receive token0."
        );
        assertEq(
            token1.balanceOf( recipient2 ),
            200 ether,
            "Recipient2 should receive token1."
        );
    }
}

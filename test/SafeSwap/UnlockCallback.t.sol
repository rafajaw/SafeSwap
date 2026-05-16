// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract UnlockCallbackTest is SafeSwapTestBase {

    function setUp( ) public override
    {
        super.setUp( );

        // Enable real token transfers via BondRoute.
        MockBondRoute(payable(BONDROUTE_ADDRESS)).set_skip_actual_transfer( false );

        vm.startPrank( user );
        token0.approve( BONDROUTE_ADDRESS, type(uint256).max );
        token1.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );
    }


    // ━━━━  Access Control  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_unlock_callback_reverts_if_not_pool_manager( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        bytes memory data  =  bytes.concat( abi.encode( context, params ), bytes1(uint8(UniswapHook.Action.ExactInputSwap)) );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, address(pool_manager) ) );
        hook.unlockCallback( data );
    }


    // ━━━━  Operation Type Dispatch  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_unlock_callback_dispatches_exact_input_swap( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        // Set mock amounts (negative for input, positive for output).
        pool_manager.set_mock_swap_amounts( -100 ether, 95 ether );

        bytes memory data  =  bytes.concat( abi.encode( context, params ), bytes1(uint8(UniswapHook.Action.ExactInputSwap)) );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        // The unlock callback should be called by pool manager.
        vm.prank( address(pool_manager) );
        hook.unlockCallback( data );

        // Verify dispatch happened: user paid token0 and received token1.
        assertEq(
            user_token0_before - token0.balanceOf( user ),
            100 ether,
            "Exact input dispatch: user should pay 100 ether of token0."
        );
        // fee = 95 * 3000 / 10_000_000 = 0.0285, user gets 94.9715.
        assertEq(
            token1.balanceOf( user ) - user_token1_before,
            94.9715 ether,
            "Exact input dispatch: user should receive 94.9715 ether of token1."
        );
    }

    function test_unlock_callback_dispatches_exact_output_swap( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 90 ether );

        // Set mock amounts.
        pool_manager.set_mock_swap_amounts( -95 ether, 90 ether );

        bytes memory data  =  bytes.concat( abi.encode( context, params ), bytes1(uint8(UniswapHook.Action.ExactOutputSwap)) );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.unlockCallback( data );

        // Verify dispatch happened: user paid token0 and received token1.
        assertEq(
            user_token0_before - token0.balanceOf( user ),
            95 ether,
            "Exact output dispatch: user should pay 95 ether of token0."
        );
        // fee = 90 * 3000 / 10_000_000 = 0.027, user gets 89.973.
        assertEq(
            token1.balanceOf( user ) - user_token1_before,
            89.973 ether,
            "Exact output dispatch: user should receive 89.973 ether of token1."
        );
    }

    function test_unlock_callback_dispatches_add_liquidity( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory params  =  _create_add_liquidity_params( );

        // Set mock amounts (negative means user provides).
        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        bytes memory data  =  bytes.concat( abi.encode( context, params ), bytes1(uint8(UniswapHook.Action.AddLiquidity)) );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.unlockCallback( data );

        // Verify dispatch happened: user provided both tokens.
        assertEq(
            user_token0_before - token0.balanceOf( user ),
            50 ether,
            "Add liquidity dispatch: user should provide 50 ether of token0."
        );
        assertEq(
            user_token1_before - token1.balanceOf( user ),
            50 ether,
            "Add liquidity dispatch: user should provide 50 ether of token1."
        );
    }

    function test_unlock_callback_dispatches_remove_liquidity( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 0 );
        RemoveLiquidityParams memory params  =  _create_remove_liquidity_params( 100 ether );

        // Set mock amounts (positive means pool returns to user).
        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        bytes memory data  =  bytes.concat( abi.encode( context, params ), bytes1(uint8(UniswapHook.Action.RemoveLiquidity)) );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.unlockCallback( data );

        // Verify dispatch happened: user received both tokens.
        assertEq(
            token0.balanceOf( user ) - user_token0_before,
            50 ether,
            "Remove liquidity dispatch: user should receive 50 ether of token0."
        );
        assertEq(
            token1.balanceOf( user ) - user_token1_before,
            50 ether,
            "Remove liquidity dispatch: user should receive 50 ether of token1."
        );
    }

    function test_unlock_callback_dispatches_donate( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 200 ether );
        DonateParams memory params  =  _create_donate_params( );

        pool_manager.set_mock_donate_amounts( -100 ether, -200 ether );

        bytes memory data  =  bytes.concat( abi.encode( context, params ), bytes1(uint8(UniswapHook.Action.Donate)) );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.unlockCallback( data );

        assertEq(
            user_token0_before - token0.balanceOf( user ),
            100 ether,
            "Donate dispatch: user should provide 100 ether of token0."
        );
        assertEq(
            user_token1_before - token1.balanceOf( user ),
            200 ether,
            "Donate dispatch: user should provide 200 ether of token1."
        );
    }

    function test_unlock_callback_reverts_on_invalid_action( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        // Use invalid action (99 is outside enum range 0-3).
        bytes memory data  =  bytes.concat( abi.encode( context, params ), bytes1(uint8(99)) );

        vm.prank( address(pool_manager) );
        // Enum conversion panics with error code 0x21.
        vm.expectRevert( abi.encodeWithSelector( bytes4(0x4e487b71), uint256(0x21) ) );
        hook.unlockCallback( data );
    }


    // ━━━━  Trailing Byte Encoding  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_unlock_callback_reads_operation_type_from_last_byte( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        pool_manager.set_mock_swap_amounts( -100 ether, 95 ether );

        // Construct data with trailing byte.
        bytes memory encoded_payload  =  abi.encode( context, params );
        bytes memory data  =  bytes.concat( encoded_payload, bytes1(uint8(UniswapHook.Action.ExactInputSwap)) );

        // Verify the last byte is the operation type.
        assertEq(
            uint8(data[ data.length - 1 ]),
            uint8(UniswapHook.Action.ExactInputSwap),
            "Last byte should be operation type."
        );

        uint256 user_token0_before  =  token0.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.unlockCallback( data );

        // Verify execution actually happened (not just no revert).
        assertEq(
            user_token0_before - token0.balanceOf( user ),
            100 ether,
            "Operation should execute: user pays 100 ether of token0."
        );
    }

    function test_unlock_callback_decodes_payload_without_trailing_byte( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        pool_manager.set_mock_swap_amounts( -100 ether, 95 ether );

        bytes memory encoded_payload  =  abi.encode( context, params );
        bytes memory data  =  bytes.concat( encoded_payload, bytes1(uint8(UniswapHook.Action.ExactInputSwap)) );

        // The payload length should be data.length - 1.
        assertEq(
            data.length,
            encoded_payload.length + 1,
            "Data should be payload + 1 byte for operation type."
        );

        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.unlockCallback( data );

        // Verify payload decoded correctly by checking execution output.
        // fee = 95 * 3000 / 10_000_000 = 0.0285, user gets 94.9715.
        assertEq(
            token1.balanceOf( user ) - user_token1_before,
            94.9715 ether,
            "Payload decoded correctly: user receives expected token1 output."
        );
    }
}

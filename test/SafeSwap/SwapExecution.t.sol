// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract SwapExecutionTest is SafeSwapTestBase {
    using PoolIdLibrary for PoolKey;

    function setUp( ) public override
    {
        super.setUp( );

        // Enable real token transfers via BondRoute for execution tests.
        MockBondRoute(payable(BONDROUTE_ADDRESS)).set_skip_actual_transfer( false );

        // Approve the etched BondRoute address to spend user tokens.
        vm.startPrank( user );
        token0.approve( BONDROUTE_ADDRESS, type(uint256).max );
        token1.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );
    }


    // ━━━━  Exact Input Swap  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_exact_input_swap_transfers_correct_amount_in( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        // Set mock: user sends 100, receives 95.
        pool_manager.set_mock_swap_amounts( -100 ether, 95 ether );

        uint256 balance_before  =  token0.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_input_swap( context, params );

        assertEq(
            balance_before - token0.balanceOf( user ),
            100 ether,
            "User should pay exactly 100 ether of token0."
        );
    }

    function test_exact_input_swap_transfers_correct_amount_out( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        pool_manager.set_mock_swap_amounts( -100 ether, 95 ether );

        uint256 balance_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_input_swap( context, params );

        // amount_out = 95 ether, protocol fee = 95 * 3000 / 10_000_000 = 0.0285 ether.
        // User receives 95 - 0.0285 = 94.9715 ether.
        assertEq(
            token1.balanceOf( user ) - balance_before,
            94.9715 ether,
            "User should receive 94.9715 ether of token1 after protocol fee."
        );
    }

    function test_exact_input_swap_reverts_on_slippage_exceeded( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 95 ether );  // min 95 out (net of fee).

        // Mock returns 90 gross, so user_output net of fee = 90 - (90 * 3000 / 10_000_000) = 89.973.
        pool_manager.set_mock_swap_amounts( -100 ether, 90 ether );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, 89.973 ether, 95 ether ) );
        hook.harness_execute_exact_input_swap( context, params );
    }

    function test_exact_input_swap_zero_for_one_direction( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );

        // token0 < token1, so token0 -> token1 is zeroForOne = true.
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token1,
            minimum_amount_out: 90 ether,
            pool_info: _default_pool_info( )
        });

        pool_manager.set_mock_swap_amounts( -100 ether, 95 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_input_swap( context, params );

        // User pays token0, receives token1 minus protocol fee.
        assertEq(
            user_token0_before - token0.balanceOf( user ),
            100 ether,
            "Zero-for-one: user should pay 100 ether of token0."
        );
        // fee = 95 * 3000 / 10_000_000 = 0.0285, user gets 94.9715.
        assertEq(
            token1.balanceOf( user ) - user_token1_before,
            94.9715 ether,
            "Zero-for-one: user should receive 94.9715 ether of token1."
        );
    }

    function test_exact_input_swap_one_for_zero_direction( ) external
    {
        // Swap token1 -> token0 (one for zero).
        TokenAmount[] memory fundings  =  new TokenAmount[]( 1 );
        fundings[ 0 ]  =  TokenAmount({ token: token1, amount: 100 ether });

        BondContext memory context  =  BondContext({
            user: user,
            stake: TokenAmount({ token: token1, amount: 1 ether }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });

        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token0,
            minimum_amount_out: 90 ether,
            pool_info: _default_pool_info( )
        });

        // For one_for_zero, amount0 is positive (output), amount1 is negative (input).
        pool_manager.set_mock_swap_amounts( 95 ether, -100 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_input_swap( context, params );

        // User pays token1, receives token0 minus protocol fee.
        assertEq(
            user_token1_before - token1.balanceOf( user ),
            100 ether,
            "One-for-zero: user should pay 100 ether of token1."
        );
        // fee = 95 * 3000 / 10_000_000 = 0.0285, user gets 94.9715.
        assertEq(
            token0.balanceOf( user ) - user_token0_before,
            94.9715 ether,
            "One-for-zero: user should receive 94.9715 ether of token0."
        );
    }

    function test_exact_input_swap_deducts_protocol_fee( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        // Mock returns 100 ether output.
        pool_manager.set_mock_swap_amounts( -100 ether, 100 ether );

        uint256 hook_balance_before  =  token1.balanceOf( address(hook) );
        uint256 user_balance_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_input_swap( context, params );

        // Protocol fee = 100 * 3000 / 10_000_000 = 0.03 ether (0.03% on 0.3% pool).
        assertEq(
            token1.balanceOf( address(hook) ) - hook_balance_before,
            0.03 ether,
            "Hook should receive 0.03 ether protocol fee."
        );
        // User receives 100 - 0.03 = 99.97 ether.
        assertEq(
            token1.balanceOf( user ) - user_balance_before,
            99.97 ether,
            "User should receive 99.97 ether after protocol fee."
        );
    }


    // ━━━━  Exact Output Swap  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_exact_output_swap_transfers_correct_amount_in( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 90 ether );

        // Mock: pool requires 95 input, gives 90 output.
        pool_manager.set_mock_swap_amounts( -95 ether, 90 ether );

        uint256 balance_before  =  token0.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_output_swap( context, params );

        // User pays amount_in from delta = 95 ether.
        assertEq(
            balance_before - token0.balanceOf( user ),
            95 ether,
            "User should pay 95 ether of token0 (from delta)."
        );
    }

    function test_exact_output_swap_transfers_correct_amount_out( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 90 ether );

        pool_manager.set_mock_swap_amounts( -95 ether, 90 ether );

        uint256 balance_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_output_swap( context, params );

        // Exact-output: user receives exactly the requested amount; protocol fee is grossed up on top.
        assertEq(
            token1.balanceOf( user ) - balance_before,
            90 ether,
            "User should receive exactly the requested output amount."
        );
    }

    function test_exact_output_swap_reverts_on_slippage_exceeded( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 95 ether );
        ExactOutputSwapParams memory params  =  ExactOutputSwapParams({
            token_out: token1,
            amount_out: 90 ether,
            pool_info: _default_pool_info( )
        });

        // Mock requires 100 input, exceeds max (95 from fundings).
        pool_manager.set_mock_swap_amounts( -100 ether, 90 ether );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, 100 ether, 95 ether ) );
        hook.harness_execute_exact_output_swap( context, params );
    }

    function test_exact_output_swap_zero_for_one_direction( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 90 ether );

        pool_manager.set_mock_swap_amounts( -95 ether, 90 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_output_swap( context, params );

        // User pays token0 (95 from delta), receives exactly the requested amount of token1.
        assertEq(
            user_token0_before - token0.balanceOf( user ),
            95 ether,
            "Zero-for-one: user should pay 95 ether of token0."
        );
        assertEq(
            token1.balanceOf( user ) - user_token1_before,
            90 ether,
            "Zero-for-one: user should receive exactly 90 ether of token1."
        );
    }

    function test_exact_output_swap_one_for_zero_direction( ) external
    {
        TokenAmount[] memory fundings  =  new TokenAmount[]( 1 );
        fundings[ 0 ]  =  TokenAmount({ token: token1, amount: 100 ether });

        BondContext memory context  =  BondContext({
            user: user,
            stake: TokenAmount({ token: token1, amount: 1 ether }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });

        ExactOutputSwapParams memory params  =  ExactOutputSwapParams({
            token_out: token0,
            amount_out: 90 ether,
            pool_info: _default_pool_info( )
        });

        pool_manager.set_mock_swap_amounts( 90 ether, -95 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_output_swap( context, params );

        // User pays token1 (95 from delta), receives exactly the requested amount of token0.
        assertEq(
            user_token1_before - token1.balanceOf( user ),
            95 ether,
            "One-for-zero: user should pay 95 ether of token1."
        );
        assertEq(
            token0.balanceOf( user ) - user_token0_before,
            90 ether,
            "One-for-zero: user should receive exactly 90 ether of token0."
        );
    }

    function test_exact_output_swap_deducts_protocol_fee( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 110 ether );
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 100 ether );

        pool_manager.set_mock_swap_amounts( -105 ether, 100 ether );

        uint256 hook_balance_before  =  token1.balanceOf( address(hook) );
        uint256 user_balance_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_output_swap( context, params );

        // Gross-up math: pool produces 100 * 10_000_000 / 9_997_000 = 100.030009002700810243 ether.
        // User receives exactly 100 ether (their request); the hook keeps the grossed-up surplus.
        assertEq(
            token1.balanceOf( user ) - user_balance_before,
            100 ether,
            "User should receive exactly the requested output amount."
        );
        assertEq(
            token1.balanceOf( address(hook) ) - hook_balance_before,
            30_009_002_700_810_243,
            "Hook should receive the grossed-up surplus as protocol fee."
        );
    }


    // ━━━━  Pool Key Building  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_build_pool_key_orders_currencies_correctly( ) external view
    {
        // token0 < token1 by setup.
        PoolKey memory key1  =  hook.harness_build_pool_key( token0, token1, POOL_FEE_030, TICK_SPACING_60 );
        assertEq(
            Currency.unwrap(key1.currency0),
            address(token0),
            "Currency0 should be the lower address."
        );
        assertEq(
            Currency.unwrap(key1.currency1),
            address(token1),
            "Currency1 should be the higher address."
        );

        // Reverse order should still produce same key.
        PoolKey memory key2  =  hook.harness_build_pool_key( token1, token0, POOL_FEE_030, TICK_SPACING_60 );
        assertEq(
            Currency.unwrap(key2.currency0),
            address(token0),
            "Currency0 should still be the lower address when reversed."
        );
        assertEq(
            Currency.unwrap(key2.currency1),
            address(token1),
            "Currency1 should still be the higher address when reversed."
        );
    }

    function test_build_pool_key_sets_hook_address( ) external view
    {
        PoolKey memory key  =  hook.harness_build_pool_key( token0, token1, POOL_FEE_030, TICK_SPACING_60 );

        assertEq(
            address(key.hooks),
            address(hook),
            "Pool key should set this contract as the hook."
        );
    }

    function test_off_chain_get_pool_id_matches_pool_key_id_for_both_token_orders( ) external view
    {
        PoolInfo memory pool_info  =  PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 });
        PoolKey memory key         =  hook.harness_build_pool_key( token0, token1, POOL_FEE_030, TICK_SPACING_60 );

        assertEq(
            PoolId.unwrap(hook.__OFF_CHAIN__get_pool_id( token0, token1, pool_info )),
            PoolId.unwrap(key.toId( )),
            "Pool id should match the canonical PoolKey id."
        );

        assertEq(
            PoolId.unwrap(hook.__OFF_CHAIN__get_pool_id( token1, token0, pool_info )),
            PoolId.unwrap(key.toId( )),
            "Pool id should be independent of token argument order."
        );
    }
}

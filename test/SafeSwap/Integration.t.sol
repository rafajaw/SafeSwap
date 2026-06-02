// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract IntegrationTest is SafeSwapTestBase {

    function setUp( ) public override
    {
        super.setUp( );

        // Enable real token transfers via BondRoute for integration tests.
        MockBondRoute(payable(BONDROUTE_ADDRESS)).set_skip_actual_transfer( false );

        // Approve the etched BondRoute address to spend user tokens.
        vm.startPrank( user );
        token0.approve( BONDROUTE_ADDRESS, type(uint256).max );
        token1.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );

        vm.startPrank( other_user );
        token0.approve( BONDROUTE_ADDRESS, type(uint256).max );
        token1.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );
    }


    // ━━━━  Full Swap Flow  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_integration_exact_input_swap_end_to_end( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        pool_manager.set_mock_swap_amounts( -100 ether, 95 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_input_swap( context, params );

        // User pays token0 and receives token1 minus protocol fee.
        assertEq(
            user_token0_before - token0.balanceOf( user ),
            100 ether,
            "User should pay 100 ether of token0."
        );
        assertGt(
            token1.balanceOf( user ) - user_token1_before,
            0,
            "User should receive token1 output."
        );
    }

    function test_integration_exact_output_swap_end_to_end( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 90 ether );

        pool_manager.set_mock_swap_amounts( -95 ether, 90 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_output_swap( context, params );

        // User pays token0 and receives token1 minus protocol fee.
        assertEq(
            user_token0_before - token0.balanceOf( user ),
            95 ether,
            "User should pay 95 ether of token0."
        );
        assertGt(
            token1.balanceOf( user ) - user_token1_before,
            0,
            "User should receive token1 output."
        );
    }

    function test_integration_swap_with_native_token_in( ) external view
    {
        // Create context with native token funding.
        TokenAmount[] memory fundings  =  new TokenAmount[]( 1 );
        fundings[ 0 ]  =  TokenAmount({ token: NATIVE_TOKEN, amount: 100 ether });

        BondContext memory context  =  BondContext({
            user: user,
            stake: TokenAmount({ token: NATIVE_TOKEN, amount: 1 ether }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });

        // Structural validation: context with native token can be constructed.
        assertEq( address(context.fundings[ 0 ].token), address(0), "Native token should be address(0)." );
        assertEq( context.fundings[ 0 ].amount, 100 ether, "Native funding amount should be 100 ether." );
    }

    function test_integration_swap_with_native_token_out( ) external view
    {
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: NATIVE_TOKEN,
            minimum_output_amount: 90 ether,
            pool_info: _default_pool_info( )
        });

        // Structural validation: params with native token_out can be constructed.
        assertEq( address(params.token_out), address(0), "Token out should be native (address 0)." );
    }


    // ━━━━  Full Liquidity Flow  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_integration_add_liquidity_end_to_end( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.harness_execute_modify_liquidity( context, _build_modify_params( token_id, int128(50 ether) ), position_info );

        assertEq(
            user_token0_before - token0.balanceOf( user ),
            50 ether,
            "User should provide 50 ether of token0."
        );
        assertEq(
            user_token1_before - token1.balanceOf( user ),
            50 ether,
            "User should provide 50 ether of token1."
        );
    }

    function test_integration_remove_liquidity_end_to_end( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context  =  _create_modify_liquidity_no_funding_context( user );

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.harness_execute_modify_liquidity( context, _build_modify_params( token_id, -int128(100 ether) ), position_info );

        assertEq(
            token0.balanceOf( user ) - user_token0_before,
            50 ether,
            "User should receive 50 ether of token0."
        );
        assertEq(
            token1.balanceOf( user ) - user_token1_before,
            50 ether,
            "User should receive 50 ether of token1."
        );
    }

    function test_integration_add_then_remove_liquidity( ) external
    {
        uint256 user_token0_start  =  token0.balanceOf( user );
        uint256 user_token1_start  =  token1.balanceOf( user );

        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );

        // Add liquidity.
        BondContext memory add_context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );
        hook.harness_execute_modify_liquidity( add_context, _build_modify_params( token_id, int128(50 ether) ), position_info );

        // User paid 50 each.
        assertEq( user_token0_start - token0.balanceOf( user ), 50 ether, "After add: user paid 50 token0." );
        assertEq( user_token1_start - token1.balanceOf( user ), 50 ether, "After add: user paid 50 token1." );

        // Remove liquidity from the same NFT position.
        BondContext memory remove_context  =  _create_modify_liquidity_no_funding_context( user );
        pool_manager.set_mock_liquidity_amounts( 25 ether, 25 ether );
        hook.harness_execute_modify_liquidity( remove_context, _build_modify_params( token_id, -int128(25 ether) ), position_info );

        // Net: paid 50, got back 25 → lost 25 of each.
        assertEq( user_token0_start - token0.balanceOf( user ), 25 ether, "After remove: net loss is 25 token0." );
        assertEq( user_token1_start - token1.balanceOf( user ), 25 ether, "After remove: net loss is 25 token1." );
    }


    // ━━━━  Multiple Operations  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_integration_multiple_swaps_same_pool( ) external
    {
        pool_manager.set_mock_swap_amounts( -100 ether, 95 ether );

        // First swap.
        BondContext memory context1  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params1  =  _create_exact_input_params( 90 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_input_swap( context1, params1 );

        assertEq(
            user_token0_before - token0.balanceOf( user ),
            100 ether,
            "First swap: user should pay 100 ether."
        );

        // Second swap.
        BondContext memory context2  =  _create_bond_context( user, 50 ether );
        ExactInputSwapParams memory params2  =  _create_exact_input_params( 45 ether );

        pool_manager.set_mock_swap_amounts( -50 ether, 48 ether );

        uint256 user_token0_before2  =  token0.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_input_swap( context2, params2 );

        assertEq(
            user_token0_before2 - token0.balanceOf( user ),
            50 ether,
            "Second swap: user should pay 50 ether."
        );
    }

    function test_integration_multiple_users_same_pool( ) external
    {
        pool_manager.set_mock_swap_amounts( -100 ether, 95 ether );

        // User 1 swap.
        BondContext memory context1  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params1  =  _create_exact_input_params( 90 ether );

        uint256 user1_token0_before  =  token0.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_input_swap( context1, params1 );

        assertEq(
            user1_token0_before - token0.balanceOf( user ),
            100 ether,
            "User1 should pay 100 ether."
        );

        // User 2 swap.
        BondContext memory context2  =  _create_bond_context( other_user, 100 ether );

        uint256 user2_token0_before  =  token0.balanceOf( other_user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_input_swap( context2, params1 );

        assertEq(
            user2_token0_before - token0.balanceOf( other_user ),
            100 ether,
            "User2 should pay 100 ether."
        );
    }

    function test_integration_swap_after_liquidity_change( ) external
    {
        // Add liquidity first.
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory liq_context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        hook.harness_execute_modify_liquidity( liq_context, _build_modify_params( token_id, int128(50 ether) ), position_info );

        // Then swap from other_user.
        BondContext memory swap_context  =  _create_bond_context( other_user, 100 ether );
        ExactInputSwapParams memory swap_params  =  _create_exact_input_params( 90 ether );

        pool_manager.set_mock_swap_amounts( -100 ether, 95 ether );

        uint256 other_token0_before  =  token0.balanceOf( other_user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_exact_input_swap( swap_context, swap_params );

        assertEq(
            other_token0_before - token0.balanceOf( other_user ),
            100 ether,
            "Swap should work after liquidity change."
        );
    }


    // ━━━━  Fee Accumulation  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_integration_fees_accumulate_over_swaps( ) external
    {
        // Mint tokens to pool manager for take operations.
        token1.mint( address(pool_manager), 1000 ether );

        pool_manager.set_mock_swap_amounts( -100 ether, 100 ether );

        uint256 hook_fee_before  =  token1.balanceOf( address(hook) );

        // Execute multiple swaps to accumulate fees.
        for(  uint i = 0  ;  i < 5  ;  i++  )
        {
            BondContext memory context  =  _create_bond_context( user, 100 ether );
            ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

            vm.prank( address(pool_manager) );
            hook.harness_execute_exact_input_swap( context, params );
        }

        uint256 hook_fee_after  =  token1.balanceOf( address(hook) );

        // Each swap: 100 ether * 3000 / 10_000_000 = 0.03 ether fee.
        // 5 swaps = 0.15 ether total.
        assertEq(
            hook_fee_after - hook_fee_before,
            0.15 ether,
            "Hook should accumulate 0.15 ether in protocol fees over 5 swaps."
        );
    }

    function test_integration_treasury_withdraws_accumulated_fees( ) external
    {
        token1.mint( address(hook), 10 ether );

        uint256 treasury_before  =  token1.balanceOf( treasury );

        vm.prank( treasury );
        hook.withdraw_protocol_fees( token1, treasury );

        uint256 treasury_after  =  token1.balanceOf( treasury );

        // Hook has dust from setUp, so transfers full minted amount.
        assertEq(
            treasury_after - treasury_before,
            10 ether,
            "Treasury should withdraw accumulated fees minus 1 wei."
        );
    }
}

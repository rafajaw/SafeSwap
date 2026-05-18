// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract LiquidityExecutionTest is SafeSwapTestBase {

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

        vm.startPrank( other_user );
        token0.approve( BONDROUTE_ADDRESS, type(uint256).max );
        token1.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );
    }


    // ━━━━  Add Liquidity  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_add_liquidity_calculates_liquidity_correctly( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory params  =  _create_add_liquidity_params( );

        // Mock returns negative deltas (user provides tokens).
        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( context, params );

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

    function test_add_liquidity_transfers_token0_to_pool( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory params  =  _create_add_liquidity_params( );

        pool_manager.set_mock_liquidity_amounts( -80 ether, -20 ether );

        uint256 pm_balance_before  =  token0.balanceOf( address(pool_manager) );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( context, params );

        assertEq(
            token0.balanceOf( address(pool_manager) ) - pm_balance_before,
            80 ether,
            "Pool manager should receive 80 ether of token0."
        );
    }

    function test_add_liquidity_transfers_token1_to_pool( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory params  =  _create_add_liquidity_params( );

        pool_manager.set_mock_liquidity_amounts( -20 ether, -80 ether );

        uint256 pm_balance_before  =  token1.balanceOf( address(pool_manager) );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( context, params );

        assertEq(
            token1.balanceOf( address(pool_manager) ) - pm_balance_before,
            80 ether,
            "Pool manager should receive 80 ether of token1."
        );
    }

    function test_add_liquidity_reverts_on_amount0_slippage( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            min_a: TokenAmount({ token: token0, amount: 60 ether }),  // Require at least 60 ether.
            min_b: TokenAmount({ token: token1, amount: 0 }),
            salt: bytes32(0)
        });

        // Mock returns only 50 ether for token0, less than min.
        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, 50 ether, 60 ether ) );
        hook.harness_execute_add_liquidity( context, params );
    }

    function test_add_liquidity_reverts_on_amount1_slippage( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            min_a: TokenAmount({ token: token0, amount: 0 }),
            min_b: TokenAmount({ token: token1, amount: 60 ether }),  // Require at least 60 ether.
            salt: bytes32(0)
        });

        // Mock returns only 50 ether for token1, less than min.
        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, 50 ether, 60 ether ) );
        hook.harness_execute_add_liquidity( context, params );
    }

    function test_add_liquidity_passes_when_amounts_meet_minimums( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            min_a: TokenAmount({ token: token0, amount: 50 ether }),
            min_b: TokenAmount({ token: token1, amount: 50 ether }),
            salt: bytes32(0)
        });

        // Mock returns exactly the minimums.
        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( context, params );

        assertEq(
            user_token0_before - token0.balanceOf( user ),
            50 ether,
            "Token0 should transfer when amount meets minimum."
        );
        assertEq(
            user_token1_before - token1.balanceOf( user ),
            50 ether,
            "Token1 should transfer when amount meets minimum."
        );
    }

    function test_add_liquidity_reverts_on_one_sided_mismatch_token1_expected( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            min_a: TokenAmount({ token: token0, amount: 0 }),
            min_b: TokenAmount({ token: token1, amount: 50 ether }),  // User expects token1 deposit.
            salt: bytes32(0)
        });

        // Pool decides only token0 is needed (e.g., price moved out of range above).
        pool_manager.set_mock_liquidity_amounts( -100 ether, 0 );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( OneSidedDepositMismatch.selector, address(token1), 50 ether ) );
        hook.harness_execute_add_liquidity( context, params );
    }

    function test_add_liquidity_reverts_on_one_sided_mismatch_token0_expected( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            min_a: TokenAmount({ token: token0, amount: 50 ether }),  // User expects token0 deposit.
            min_b: TokenAmount({ token: token1, amount: 0 }),
            salt: bytes32(0)
        });

        // Pool decides only token1 is needed.
        pool_manager.set_mock_liquidity_amounts( 0, -100 ether );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( OneSidedDepositMismatch.selector, address(token0), 50 ether ) );
        hook.harness_execute_add_liquidity( context, params );
    }

    function test_add_liquidity_handles_single_sided_deposit( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 0 );
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 100,  // Wide range below current price.
            tick_upper: -TICK_SPACING_60 * 50,
            min_a: TokenAmount({ token: token0, amount: 0 }),
            min_b: TokenAmount({ token: token1, amount: 0 }),
            salt: bytes32(0)
        });

        // Single-sided: only token0 is deposited, token1 delta is 0.
        pool_manager.set_mock_liquidity_amounts( -100 ether, 0 );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( context, params );

        assertEq(
            user_token0_before - token0.balanceOf( user ),
            100 ether,
            "User should provide all token0 in single-sided deposit."
        );
        assertEq(
            token1.balanceOf( user ),
            user_token1_before,
            "Token1 balance should remain unchanged in single-sided deposit."
        );
    }

    function test_add_liquidity_uses_correct_tick_range( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        int24 tick_lower  =  -1200;
        int24 tick_upper  =  1200;

        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: tick_lower,
            tick_upper: tick_upper,
            min_a: TokenAmount({ token: token0, amount: 0 }),
            min_b: TokenAmount({ token: token1, amount: 0 }),
            salt: bytes32(0)
        });

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( context, params );

        // Verify execution completed (tick range accepted by pool manager).
        assertGt(
            user_token0_before - token0.balanceOf( user ),
            0,
            "Tokens should be provided for custom tick range."
        );
    }

    function test_add_liquidity_uses_salt_for_position( ) external
    {
        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        bytes32 custom_salt  =  keccak256( "custom_position" );

        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            min_a: TokenAmount({ token: token0, amount: 0 }),
            min_b: TokenAmount({ token: token1, amount: 0 }),
            salt: custom_salt
        });

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( context, params );

        // Verify execution completed with custom salt (position identifier).
        assertEq(
            user_token0_before - token0.balanceOf( user ),
            50 ether,
            "Tokens should transfer with custom salt position."
        );
    }

    function test_add_liquidity_different_users_same_salt_produce_different_effective_salts( ) external
    {
        bytes32 same_salt  =  keccak256( "shared_salt" );

        // User A adds liquidity.
        BondContext memory context_a  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            min_a: TokenAmount({ token: token0, amount: 0 }),
            min_b: TokenAmount({ token: token1, amount: 0 }),
            salt: same_salt
        });

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( context_a, params );

        bytes32 salt_from_user_a  =  pool_manager.last_modify_salt( );

        // User B adds liquidity with the same params.salt.
        BondContext memory context_b  =  _create_bond_context_two_fundings( other_user, 100 ether, 100 ether );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( context_b, params );

        bytes32 salt_from_user_b  =  pool_manager.last_modify_salt( );

        assertTrue(
            salt_from_user_a != salt_from_user_b,
            "Different users with same params.salt must produce different effective salts - positions must be isolated."
        );
    }

    function test_add_liquidity_same_user_same_salt_produce_same_effective_salt( ) external
    {
        bytes32 same_salt  =  keccak256( "my_position" );

        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            min_a: TokenAmount({ token: token0, amount: 0 }),
            min_b: TokenAmount({ token: token1, amount: 0 }),
            salt: same_salt
        });

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( context, params );

        bytes32 salt_first_call  =  pool_manager.last_modify_salt( );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( context, params );

        bytes32 salt_second_call  =  pool_manager.last_modify_salt( );

        assertEq(
            salt_first_call,
            salt_second_call,
            "Same user with same params.salt must produce identical effective salt - position must be addressable."
        );
    }


    // ━━━━  Remove Liquidity  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_remove_liquidity_returns_tokens_to_user( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 0 );
        RemoveLiquidityParams memory params  =  _create_remove_liquidity_params( 100 ether );

        // Positive deltas mean pool returns tokens to user.
        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_remove_liquidity( context, params );

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

    function test_remove_liquidity_reverts_on_amount0_slippage( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 0 );
        RemoveLiquidityParams memory params  =  RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            liquidity: 100 ether,
            amount0_min: 60 ether,  // Require at least 60 ether.
            amount1_min: 0,
            salt: bytes32(0)
        });

        // Returns only 50 ether for token0.
        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, 50 ether, 60 ether ) );
        hook.harness_execute_remove_liquidity( context, params );
    }

    function test_remove_liquidity_reverts_on_amount1_slippage( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 0 );
        RemoveLiquidityParams memory params  =  RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            liquidity: 100 ether,
            amount0_min: 0,
            amount1_min: 60 ether,  // Require at least 60 ether.
            salt: bytes32(0)
        });

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, 50 ether, 60 ether ) );
        hook.harness_execute_remove_liquidity( context, params );
    }

    function test_remove_liquidity_passes_when_amounts_meet_minimums( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 0 );
        RemoveLiquidityParams memory params  =  RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            liquidity: 100 ether,
            amount0_min: 50 ether,
            amount1_min: 50 ether,
            salt: bytes32(0)
        });

        // Returns exactly the minimums.
        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_remove_liquidity( context, params );

        assertEq(
            token0.balanceOf( user ) - user_token0_before,
            50 ether,
            "User should receive token0 when amount meets minimum."
        );
        assertEq(
            token1.balanceOf( user ) - user_token1_before,
            50 ether,
            "User should receive token1 when amount meets minimum."
        );
    }

    function test_remove_liquidity_uses_correct_tick_range( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 0 );
        int24 tick_lower  =  -1200;
        int24 tick_upper  =  1200;

        RemoveLiquidityParams memory params  =  RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: _default_pool_info( ),
            tick_lower: tick_lower,
            tick_upper: tick_upper,
            liquidity: 100 ether,
            amount0_min: 0,
            amount1_min: 0,
            salt: bytes32(0)
        });

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_remove_liquidity( context, params );

        assertEq(
            token0.balanceOf( user ) - user_token0_before,
            50 ether,
            "Tokens should be returned for custom tick range."
        );
    }

    function test_remove_liquidity_uses_salt_for_position( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 0 );
        bytes32 custom_salt  =  keccak256( "custom_position" );

        RemoveLiquidityParams memory params  =  RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            liquidity: 100 ether,
            amount0_min: 0,
            amount1_min: 0,
            salt: custom_salt
        });

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_remove_liquidity( context, params );

        assertEq(
            token0.balanceOf( user ) - user_token0_before,
            50 ether,
            "Tokens should be returned with custom salt position."
        );
    }

    function test_remove_liquidity_different_users_same_salt_produce_different_effective_salts( ) external
    {
        bytes32 same_salt  =  keccak256( "shared_salt" );

        RemoveLiquidityParams memory params  =  RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            liquidity: 100 ether,
            amount0_min: 0,
            amount1_min: 0,
            salt: same_salt
        });

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        // User A removes liquidity.
        BondContext memory context_a  =  _create_bond_context( user, 0 );

        vm.prank( address(pool_manager) );
        hook.harness_execute_remove_liquidity( context_a, params );

        bytes32 salt_from_user_a  =  pool_manager.last_modify_salt( );

        // User B removes liquidity with the same params.salt.
        BondContext memory context_b  =  _create_bond_context( other_user, 0 );

        vm.prank( address(pool_manager) );
        hook.harness_execute_remove_liquidity( context_b, params );

        bytes32 salt_from_user_b  =  pool_manager.last_modify_salt( );

        assertTrue(
            salt_from_user_a != salt_from_user_b,
            "Different users with same params.salt must produce different effective salts - positions must be isolated."
        );
    }

    function test_remove_liquidity_effective_salt_matches_add_liquidity( ) external
    {
        bytes32 same_salt  =  keccak256( "my_position" );

        // Add liquidity as user.
        BondContext memory add_context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        AddLiquidityParams memory add_params  =  AddLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            min_a: TokenAmount({ token: token0, amount: 0 }),
            min_b: TokenAmount({ token: token1, amount: 0 }),
            salt: same_salt
        });

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        vm.prank( address(pool_manager) );
        hook.harness_execute_add_liquidity( add_context, add_params );

        bytes32 salt_from_add  =  pool_manager.last_modify_salt( );

        // Remove liquidity as same user with same salt.
        BondContext memory remove_context  =  _create_bond_context( user, 0 );
        RemoveLiquidityParams memory remove_params  =  RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: _default_pool_info( ),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            liquidity: 100 ether,
            amount0_min: 0,
            amount1_min: 0,
            salt: same_salt
        });

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        vm.prank( address(pool_manager) );
        hook.harness_execute_remove_liquidity( remove_context, remove_params );

        bytes32 salt_from_remove  =  pool_manager.last_modify_salt( );

        assertEq(
            salt_from_add,
            salt_from_remove,
            "Same user with same salt must produce identical effective salt across add and remove - position must be round-trippable."
        );
    }

    function test_remove_liquidity_full_position( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 0 );
        RemoveLiquidityParams memory params  =  _create_remove_liquidity_params( 100 ether );

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_remove_liquidity( context, params );

        assertEq(
            token0.balanceOf( user ) - user_token0_before,
            50 ether,
            "Full removal: user should receive all token0."
        );
        assertEq(
            token1.balanceOf( user ) - user_token1_before,
            50 ether,
            "Full removal: user should receive all token1."
        );
    }

    function test_remove_liquidity_partial_position( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 0 );
        RemoveLiquidityParams memory params  =  _create_remove_liquidity_params( 50 ether );  // Half.

        pool_manager.set_mock_liquidity_amounts( 25 ether, 25 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.harness_execute_remove_liquidity( context, params );

        assertEq(
            token0.balanceOf( user ) - user_token0_before,
            25 ether,
            "Partial removal: user should receive half of token0."
        );
        assertEq(
            token1.balanceOf( user ) - user_token1_before,
            25 ether,
            "Partial removal: user should receive half of token1."
        );
    }
}

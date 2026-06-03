// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


/// @dev Direct-execution tests for the unified ModifyLiquidityLib.execute path (create/add share the
///      settle branch via liquidity_delta > 0; remove/collect share the take branch via <= 0). Positions
///      are NFT-backed, so the V4 position salt is the LP token id, not the user address.
contract LiquidityExecutionTest is SafeSwapTestBase {

    function setUp( ) public override
    {
        super.setUp( );

        // Enable real token transfers via BondRoute for execution tests.
        MockBondRoute(payable(BONDROUTE_ADDRESS)).set_skip_actual_transfer( false );

        vm.startPrank( user );
        token0.approve( BONDROUTE_ADDRESS, type(uint256).max );
        token1.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );

        vm.startPrank( other_user );
        token0.approve( BONDROUTE_ADDRESS, type(uint256).max );
        token1.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );
    }


    // ━━━━  Add Liquidity (liquidity_delta > 0 → settle)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_add_liquidity_settles_both_tokens_from_user( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, int128(50 ether) );

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );  // Negative: user provides tokens.

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.harness_execute_modify_liquidity( context, params, position_info );

        assertEq( user_token0_before - token0.balanceOf( user ), 50 ether, "User should provide 50 ether of token0." );
        assertEq( user_token1_before - token1.balanceOf( user ), 50 ether, "User should provide 50 ether of token1." );
    }

    function test_add_liquidity_transfers_token0_to_pool( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, int128(80 ether) );

        pool_manager.set_mock_liquidity_amounts( -80 ether, -20 ether );

        uint256 pm_balance_before  =  token0.balanceOf( address(pool_manager) );

        hook.harness_execute_modify_liquidity( context, params, position_info );

        assertEq( token0.balanceOf( address(pool_manager) ) - pm_balance_before, 80 ether, "Pool manager should receive 80 ether of token0." );
    }

    function test_add_liquidity_transfers_token1_to_pool( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, int128(80 ether) );

        pool_manager.set_mock_liquidity_amounts( -20 ether, -80 ether );

        uint256 pm_balance_before  =  token1.balanceOf( address(pool_manager) );

        hook.harness_execute_modify_liquidity( context, params, position_info );

        assertEq( token1.balanceOf( address(pool_manager) ) - pm_balance_before, 80 ether, "Pool manager should receive 80 ether of token1." );
    }

    function test_add_liquidity_reverts_on_amount0_slippage( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, int128(50 ether) );
        params.minimum_amount_a  =  TokenAmount({ token: token0, amount: 60 ether });  // Require at least 60 ether token0.

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, 50 ether, 60 ether ) );
        hook.harness_execute_modify_liquidity( context, params, position_info );
    }

    function test_add_liquidity_reverts_on_amount1_slippage( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, int128(50 ether) );
        params.minimum_amount_b  =  TokenAmount({ token: token1, amount: 60 ether });  // Require at least 60 ether token1.

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, 50 ether, 60 ether ) );
        hook.harness_execute_modify_liquidity( context, params, position_info );
    }

    function test_add_liquidity_passes_when_amounts_meet_minimums( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, int128(50 ether) );
        params.minimum_amount_a  =  TokenAmount({ token: token0, amount: 50 ether });
        params.minimum_amount_b  =  TokenAmount({ token: token1, amount: 50 ether });

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.harness_execute_modify_liquidity( context, params, position_info );

        assertEq( user_token0_before - token0.balanceOf( user ), 50 ether, "Token0 should transfer when amount meets minimum." );
        assertEq( user_token1_before - token1.balanceOf( user ), 50 ether, "Token1 should transfer when amount meets minimum." );
    }

    function test_add_liquidity_reverts_on_one_sided_mismatch_token1_expected( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, int128(100 ether) );
        params.minimum_amount_b  =  TokenAmount({ token: token1, amount: 50 ether });  // User expects token1 deposit.

        // Pool decides only token0 is needed (price out of range above).
        pool_manager.set_mock_liquidity_amounts( -100 ether, 0 );

        vm.expectRevert( abi.encodeWithSelector( OneSidedDepositMismatch.selector, address(token1), 50 ether ) );
        hook.harness_execute_modify_liquidity( context, params, position_info );
    }

    function test_add_liquidity_reverts_on_one_sided_mismatch_token0_expected( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, int128(100 ether) );
        params.minimum_amount_a  =  TokenAmount({ token: token0, amount: 50 ether });  // User expects token0 deposit.

        // Pool decides only token1 is needed.
        pool_manager.set_mock_liquidity_amounts( 0, -100 ether );

        vm.expectRevert( abi.encodeWithSelector( OneSidedDepositMismatch.selector, address(token0), 50 ether ) );
        hook.harness_execute_modify_liquidity( context, params, position_info );
    }

    function test_add_liquidity_handles_single_sided_deposit( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_bond_context_two_fundings( user, 100 ether, 0 );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, int128(100 ether) );

        // Single-sided: only token0 is deposited, token1 delta is 0 with no token1 minimum.
        pool_manager.set_mock_liquidity_amounts( -100 ether, 0 );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.harness_execute_modify_liquidity( context, params, position_info );

        assertEq( user_token0_before - token0.balanceOf( user ), 100 ether, "User should provide all token0 in single-sided deposit." );
        assertEq( token1.balanceOf( user ), user_token1_before, "Token1 balance should remain unchanged in single-sided deposit." );
    }

    function test_add_liquidity_uses_lp_token_id_as_position_salt( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, int128(50 ether) );

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        hook.harness_execute_modify_liquidity( context, params, position_info );

        assertEq( pool_manager.last_modify_salt( ), bytes32(token_id), "V4 position salt must be the LP NFT token id." );
    }

    function test_add_liquidity_distinct_positions_produce_distinct_salts( ) external
    {
        ( uint256 token_id_a, SafeSwapPositionInfo memory position_a )  =  _mint_default_position( user );
        ( uint256 token_id_b, SafeSwapPositionInfo memory position_b )  =  _mint_default_position( other_user );

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        BondContext memory context_a  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        hook.harness_execute_modify_liquidity( context_a, _build_modify_params( token_id_a, int128(50 ether) ), position_a );
        bytes32 salt_a  =  pool_manager.last_modify_salt( );

        BondContext memory context_b  =  _create_bond_context_two_fundings( other_user, 100 ether, 100 ether );
        hook.harness_execute_modify_liquidity( context_b, _build_modify_params( token_id_b, int128(50 ether) ), position_b );
        bytes32 salt_b  =  pool_manager.last_modify_salt( );

        assertEq( salt_a, bytes32(token_id_a), "Position A salt must equal its token id." );
        assertEq( salt_b, bytes32(token_id_b), "Position B salt must equal its token id." );
        assertTrue( salt_a != salt_b, "Distinct positions must produce distinct V4 salts." );
    }


    // ━━━━  Remove Liquidity (liquidity_delta < 0 → take)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_remove_liquidity_returns_tokens_to_user( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_modify_liquidity_no_funding_context( user );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, -int128(100 ether) );

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );  // Positive: pool returns tokens.

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.harness_execute_modify_liquidity( context, params, position_info );

        assertEq( token0.balanceOf( user ) - user_token0_before, 50 ether, "User should receive 50 ether of token0." );
        assertEq( token1.balanceOf( user ) - user_token1_before, 50 ether, "User should receive 50 ether of token1." );
    }

    function test_remove_liquidity_reverts_on_amount0_slippage( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_modify_liquidity_no_funding_context( user );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, -int128(100 ether) );
        params.minimum_amount_a  =  TokenAmount({ token: token0, amount: 60 ether });

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, 50 ether, 60 ether ) );
        hook.harness_execute_modify_liquidity( context, params, position_info );
    }

    function test_remove_liquidity_reverts_on_amount1_slippage( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_modify_liquidity_no_funding_context( user );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, -int128(100 ether) );
        params.minimum_amount_b  =  TokenAmount({ token: token1, amount: 60 ether });

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, 50 ether, 60 ether ) );
        hook.harness_execute_modify_liquidity( context, params, position_info );
    }

    function test_remove_liquidity_passes_when_amounts_meet_minimums( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_modify_liquidity_no_funding_context( user );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, -int128(100 ether) );
        params.minimum_amount_a  =  TokenAmount({ token: token0, amount: 50 ether });
        params.minimum_amount_b  =  TokenAmount({ token: token1, amount: 50 ether });

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.harness_execute_modify_liquidity( context, params, position_info );

        assertEq( token0.balanceOf( user ) - user_token0_before, 50 ether, "User should receive token0 when amount meets minimum." );
        assertEq( token1.balanceOf( user ) - user_token1_before, 50 ether, "User should receive token1 when amount meets minimum." );
    }

    function test_remove_liquidity_full_position( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_modify_liquidity_no_funding_context( user );

        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.harness_execute_modify_liquidity( context, _build_modify_params( token_id, -int128(100 ether) ), position_info );

        assertEq( token0.balanceOf( user ) - user_token0_before, 50 ether, "Full removal: user should receive all token0." );
        assertEq( token1.balanceOf( user ) - user_token1_before, 50 ether, "Full removal: user should receive all token1." );
    }

    function test_remove_liquidity_partial_position( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_modify_liquidity_no_funding_context( user );

        pool_manager.set_mock_liquidity_amounts( 25 ether, 25 ether );

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.harness_execute_modify_liquidity( context, _build_modify_params( token_id, -int128(50 ether) ), position_info );

        assertEq( token0.balanceOf( user ) - user_token0_before, 25 ether, "Partial removal: user should receive half of token0." );
        assertEq( token1.balanceOf( user ) - user_token1_before, 25 ether, "Partial removal: user should receive half of token1." );
    }

    function test_remove_liquidity_salt_matches_token_id_round_trip( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );

        // Add then remove on the same NFT must hit the same V4 position salt.
        BondContext memory add_context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );
        hook.harness_execute_modify_liquidity( add_context, _build_modify_params( token_id, int128(50 ether) ), position_info );
        bytes32 salt_from_add  =  pool_manager.last_modify_salt( );

        BondContext memory remove_context  =  _create_modify_liquidity_no_funding_context( user );
        pool_manager.set_mock_liquidity_amounts( 50 ether, 50 ether );
        hook.harness_execute_modify_liquidity( remove_context, _build_modify_params( token_id, -int128(50 ether) ), position_info );
        bytes32 salt_from_remove  =  pool_manager.last_modify_salt( );

        assertEq( salt_from_add, bytes32(token_id), "Add salt must be the token id." );
        assertEq( salt_from_add, salt_from_remove, "Same NFT must round-trip to the same position salt across add and remove." );
    }


    // ━━━━  Collect Fees (liquidity_delta == 0 → take)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_collect_fees_takes_accrued_fees_to_user( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_modify_liquidity_no_funding_context( user );

        pool_manager.set_mock_liquidity_amounts( 3 ether, 7 ether );  // Accrued fees.

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.harness_execute_modify_liquidity( context, _build_modify_params( token_id, int128(0) ), position_info );

        assertEq( pool_manager.last_modify_salt( ), bytes32(token_id), "Collect must target the NFT's position salt." );
        assertEq( token0.balanceOf( user ) - user_token0_before, 3 ether, "User should receive accrued token0 fees." );
        assertEq( token1.balanceOf( user ) - user_token1_before, 7 ether, "User should receive accrued token1 fees." );
    }

    function test_collect_fees_reverts_on_slippage( ) external
    {
        ( uint256 token_id, SafeSwapPositionInfo memory position_info )  =  _mint_default_position( user );
        BondContext memory context        =  _create_modify_liquidity_no_funding_context( user );
        ModifyLiquidityParams memory params  =  _build_modify_params( token_id, int128(0) );
        params.minimum_amount_a  =  TokenAmount({ token: token0, amount: 5 ether });  // Expect at least 5 ether token0 fees.

        pool_manager.set_mock_liquidity_amounts( 3 ether, 7 ether );

        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, 3 ether, 5 ether ) );
        hook.harness_execute_modify_liquidity( context, params, position_info );
    }
}

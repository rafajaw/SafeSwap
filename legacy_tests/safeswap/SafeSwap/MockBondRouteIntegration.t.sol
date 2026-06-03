// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";


contract MockBondRouteIntegrationTest is SafeSwapTestBase {

    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// @dev Mint a default-range LP position so add/remove/collect quotes have an existing position to read.
    function _seed_default_position( ) private returns ( uint256 token_id )
    {
        token_id  =  hook.harness_mint_lp_position( user, token0, token1, _default_pool_info( ), DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER );
    }

    function _seed_position_with_fee( uint24 fee ) private returns ( uint256 token_id )
    {
        token_id  =  hook.harness_mint_lp_position( user, token0, token1, PoolInfo({ fee: fee, tick_spacing: TICK_SPACING_60 }), DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER );
    }


    // ━━━━  BondRoute_get_protected_selectors( )  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_get_protected_selectors_returns_seven_selectors( ) external view
    {
        bytes4[] memory selectors  =  hook.BondRoute_get_protected_selectors( );

        assertEq( selectors.length, 7, "Should return exactly 7 protected selectors." );
    }

    function test_get_protected_selectors_includes_swap_exact_input( ) external view
    {
        assertTrue( _selectors_include( hook.swap_exact_input.selector ), "Protected selectors should include swap_exact_input." );
    }

    function test_get_protected_selectors_includes_swap_exact_output( ) external view
    {
        assertTrue( _selectors_include( hook.swap_exact_output.selector ), "Protected selectors should include swap_exact_output." );
    }

    function test_get_protected_selectors_includes_create_position( ) external view
    {
        assertTrue( _selectors_include( hook.create_position.selector ), "Protected selectors should include create_position." );
    }

    function test_get_protected_selectors_includes_add_liquidity( ) external view
    {
        assertTrue( _selectors_include( hook.add_liquidity.selector ), "Protected selectors should include add_liquidity." );
    }

    function test_get_protected_selectors_includes_remove_liquidity( ) external view
    {
        assertTrue( _selectors_include( hook.remove_liquidity.selector ), "Protected selectors should include remove_liquidity." );
    }

    function test_get_protected_selectors_includes_collect_fees( ) external view
    {
        assertTrue( _selectors_include( hook.collect_fees.selector ), "Protected selectors should include collect_fees." );
    }

    function test_get_protected_selectors_includes_donate( ) external view
    {
        assertTrue( _selectors_include( hook.donate.selector ), "Protected selectors should include donate." );
    }

    function test_get_protected_selectors_gas_below_50000( ) external
    {
        uint256 gas_before  =  gasleft( );
        hook.BondRoute_get_protected_selectors( );
        uint256 gas_used  =  gas_before - gasleft( );

        assertLt( gas_used, 50000, "BondRoute_get_protected_selectors should use less than 50,000 gas." );
    }

    function _selectors_include( bytes4 target ) private view returns ( bool )
    {
        bytes4[] memory selectors  =  hook.BondRoute_get_protected_selectors( );
        for(  uint i = 0  ;  i < selectors.length  ;  i++  )
        {
            if(  selectors[ i ] == target  )  return true;
        }
        return false;
    }


    // ━━━━  BondRoute_entry_point( ) timing  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_entry_point_reverts_before_minimum_seconds_delay( ) external
    {
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );
        bytes memory call_data  =  _encode_exact_input_calldata( params );

        BondContext memory context  =  _create_bond_context( user, 100 ether );
        context.creation_block      =  block.number - MIN_BOND_EXECUTION_DELAY_IN_BLOCKS;
        context.creation_timestamp  =  block.timestamp - MIN_BOND_EXECUTION_DELAY_IN_SECONDS + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                PossiblyBondFarming.selector,
                EXECUTION_TOO_SOON_SECONDS,
                bytes32(MIN_BOND_EXECUTION_DELAY_IN_SECONDS + 1)
            )
        );

        vm.prank( BONDROUTE_ADDRESS );
        hook.BondRoute_entry_point( call_data, context );
    }


    // ━━━━  BondRoute_quote_call( ) - Exact Input Swap  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_exact_input_returns_correct_min_stake( ) external view
    {
        bytes memory call_data  =  _encode_exact_input_calldata( _create_exact_input_params( 90 ether ) );
        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( constraints.min_stake.amount, 1 ether, "Min stake should be 1% of swap amount." );
    }

    function test_quote_call_exact_input_returns_correct_min_fundings( ) external view
    {
        bytes memory call_data  =  _encode_exact_input_calldata( _create_exact_input_params( 90 ether ) );
        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( constraints.min_fundings.length, 1, "Should require exactly 1 funding." );
        assertEq( address(constraints.min_fundings[ 0 ].token), address(token0), "Funding token should be token_in." );
        assertEq( constraints.min_fundings[ 0 ].amount, 100 ether, "Funding amount should equal amount_in." );
    }

    function test_quote_call_exact_input_returns_correct_execution_delays( ) external view
    {
        bytes memory call_data  =  _encode_exact_input_calldata( _create_exact_input_params( 90 ether ) );
        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( constraints.min_execution_delay_in_blocks, 3, "Min execution delay should be 3 blocks." );
        assertEq( constraints.max_execution_delay_in_seconds, 1 hours, "Max execution delay should be 1 hour." );
    }

    function test_quote_call_exact_input_reverts_if_tokens_same( ) external
    {
        ExactInputSwapParams memory params  =  ExactInputSwapParams({ token_out: token0, minimum_output_amount: 90 ether, pool_info: _default_pool_info( ) });
        bytes memory call_data  =  _encode_exact_input_calldata( params );
        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        vm.expectRevert( "Tokens must be different" );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }

    function test_quote_call_exact_input_stake_is_in_input_token( ) external view
    {
        bytes memory call_data  =  _encode_exact_input_calldata( _create_exact_input_params( 90 ether ) );
        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( address(constraints.min_stake.token), address(token0), "Stake token should always be the input token." );
    }

    function test_quote_call_exact_input_reverts_if_funding_count_not_1( ) external
    {
        bytes memory call_data  =  _encode_exact_input_calldata( _create_exact_input_params( 90 ether ) );

        TokenAmount[] memory zero_fundings  =  new TokenAmount[](0);
        vm.expectRevert( "Swaps require exactly 1 funding" );
        hook.BondRoute_quote_call( call_data, token0, zero_fundings );

        TokenAmount[] memory two_fundings  =  _create_liquidity_fundings( 100 ether, 100 ether );
        vm.expectRevert( "Swaps require exactly 1 funding" );
        hook.BondRoute_quote_call( call_data, token0, two_fundings );
    }


    // ━━━━  BondRoute_quote_call( ) - Exact Output Swap  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_exact_output_returns_correct_min_stake( ) external view
    {
        bytes memory call_data  =  _encode_exact_output_calldata( _create_exact_output_params( 90 ether ) );
        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( constraints.min_stake.amount, 1 ether, "Min stake should be 1% of max swap amount." );
    }

    function test_quote_call_exact_output_returns_correct_min_fundings( ) external view
    {
        bytes memory call_data  =  _encode_exact_output_calldata( _create_exact_output_params( 90 ether ) );
        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( constraints.min_fundings.length, 1, "Should require exactly 1 funding." );
        assertEq( constraints.min_fundings[ 0 ].amount, 100 ether, "Funding amount should equal maximum_amount_in." );
    }

    function test_quote_call_exact_output_returns_correct_execution_delays( ) external view
    {
        bytes memory call_data  =  _encode_exact_output_calldata( _create_exact_output_params( 90 ether ) );
        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( constraints.min_execution_delay_in_blocks, 3, "Min execution delay should be 3 blocks." );
        assertEq( constraints.max_execution_delay_in_seconds, 1 hours, "Max execution delay should be 1 hour." );
    }

    function test_quote_call_exact_output_reverts_if_tokens_same( ) external
    {
        ExactOutputSwapParams memory params  =  ExactOutputSwapParams({ token_out: token0, exact_output_amount: 90 ether, pool_info: _default_pool_info( ) });
        bytes memory call_data  =  _encode_exact_output_calldata( params );
        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        vm.expectRevert( "Tokens must be different" );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }

    function test_quote_call_exact_output_reverts_if_funding_count_not_1( ) external
    {
        bytes memory call_data  =  _encode_exact_output_calldata( _create_exact_output_params( 90 ether ) );

        TokenAmount[] memory zero_fundings  =  new TokenAmount[](0);
        vm.expectRevert( "Swaps require exactly 1 funding" );
        hook.BondRoute_quote_call( call_data, token0, zero_fundings );

        TokenAmount[] memory two_fundings  =  _create_liquidity_fundings( 100 ether, 100 ether );
        vm.expectRevert( "Swaps require exactly 1 funding" );
        hook.BondRoute_quote_call( call_data, token0, two_fundings );
    }


    // ━━━━  BondRoute_quote_call( ) - Create Position (token_id == 0 path)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_create_position_reverts_if_tokens_same( ) external
    {
        bytes memory call_data  =  _encode_create_position_calldata( _create_create_position_params( ) );

        TokenAmount[] memory preferred_fundings  =  new TokenAmount[](2);
        preferred_fundings[ 0 ]  =  TokenAmount({ token: token0, amount: 100 ether });
        preferred_fundings[ 1 ]  =  TokenAmount({ token: token0, amount: 100 ether });

        vm.expectRevert( "Tokens must be different" );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }

    function test_quote_call_create_position_reverts_if_funding_count_not_2( ) external
    {
        bytes memory call_data  =  _encode_create_position_calldata( _create_create_position_params( ) );

        TokenAmount[] memory zero_fundings  =  new TokenAmount[](0);
        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, 0, int128(100 ether), uint256(0) ) );
        hook.BondRoute_quote_call( call_data, token0, zero_fundings );

        TokenAmount[] memory one_funding  =  _create_swap_fundings( 100 ether );
        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, 0, int128(100 ether), uint256(1) ) );
        hook.BondRoute_quote_call( call_data, token0, one_funding );
    }

    function test_quote_call_create_position_returns_correct_execution_delays( ) external view
    {
        bytes memory call_data  =  _encode_create_position_calldata( _create_create_position_params( ) );

        TokenAmount[] memory preferred_fundings  =  _create_liquidity_fundings( 100 ether, 100 ether );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( constraints.min_execution_delay_in_blocks, 3, "Min delay should be 3 blocks." );
        assertEq( constraints.max_execution_delay_in_seconds, 1 hours, "Max delay should be 1 hour for all SafeSwap actions." );
    }


    // ━━━━  BondRoute_quote_call( ) - Add Liquidity (existing position)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_add_liquidity_reverts_if_tokens_same( ) external
    {
        uint256 token_id  =  _seed_default_position( );
        bytes memory call_data  =  _encode_add_liquidity_calldata( _create_add_liquidity_params( token_id, 100 ether ) );

        TokenAmount[] memory preferred_fundings  =  new TokenAmount[](2);
        preferred_fundings[ 0 ]  =  TokenAmount({ token: token0, amount: 100 ether });
        preferred_fundings[ 1 ]  =  TokenAmount({ token: token0, amount: 100 ether });

        vm.expectRevert( "Tokens must be different" );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }

    function test_quote_call_add_liquidity_reverts_if_funding_count_not_2( ) external
    {
        uint256 token_id  =  _seed_default_position( );
        bytes memory call_data  =  _encode_add_liquidity_calldata( _create_add_liquidity_params( token_id, 100 ether ) );

        TokenAmount[] memory zero_fundings  =  new TokenAmount[](0);
        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, token_id, int128(100 ether), uint256(0) ) );
        hook.BondRoute_quote_call( call_data, token0, zero_fundings );

        TokenAmount[] memory one_funding  =  _create_swap_fundings( 100 ether );
        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, token_id, int128(100 ether), uint256(1) ) );
        hook.BondRoute_quote_call( call_data, token0, one_funding );
    }

    function test_quote_call_add_liquidity_returns_correct_execution_delays( ) external
    {
        uint256 token_id  =  _seed_default_position( );
        bytes memory call_data  =  _encode_add_liquidity_calldata( _create_add_liquidity_params( token_id, 100 ether ) );

        TokenAmount[] memory preferred_fundings  =  _create_liquidity_fundings( 100 ether, 100 ether );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( constraints.min_execution_delay_in_blocks, 3, "Min delay should be 3 blocks." );
        assertEq( constraints.max_execution_delay_in_seconds, 1 hours, "Max delay should be 1 hour for all SafeSwap actions." );
    }


    // ━━━━  BondRoute_quote_call( ) - Remove Liquidity  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_remove_liquidity_reverts_on_minimum_token_mismatch( ) external
    {
        uint256 token_id  =  _seed_default_position( );

        // Both minimum-received entries reference token0 — neither maps to the position's token1.
        RemovePositionLiquidityParams memory params  =  RemovePositionLiquidityParams({
            token_id: token_id,
            liquidity: 100 ether,
            minimum_received_a: TokenAmount({ token: token0, amount: 0 }),
            minimum_received_b: TokenAmount({ token: token0, amount: 0 })
        });
        bytes memory call_data  =  _encode_remove_liquidity_calldata( params );

        TokenAmount[] memory no_fundings  =  new TokenAmount[]( 0 );

        vm.expectRevert(
            abi.encodeWithSelector(
                ModifyLiquidityTokensMismatch.selector,
                address(token0),
                address(token1),
                address(token0),
                address(token0)
            )
        );
        hook.BondRoute_quote_call( call_data, token0, no_fundings );
    }

    function test_quote_call_remove_liquidity_returns_correct_execution_delays( ) external
    {
        uint256 token_id  =  _seed_default_position( );
        bytes memory call_data  =  _encode_remove_liquidity_calldata( _create_remove_liquidity_params( token_id, 100 ether ) );

        TokenAmount[] memory no_fundings  =  new TokenAmount[]( 0 );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, no_fundings );

        assertEq( constraints.min_execution_delay_in_blocks, 3, "Min delay should be 3 blocks." );
        assertEq( constraints.max_execution_delay_in_seconds, 1 hours, "Max delay should be 1 hour for all SafeSwap actions." );
    }


    // ━━━━  BondRoute_quote_call( ) - Collect Fees  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_collect_fees_returns_correct_execution_delays( ) external
    {
        uint256 token_id  =  _seed_default_position( );
        bytes memory call_data  =  _encode_collect_fees_calldata( _create_collect_fees_params( token_id ) );

        TokenAmount[] memory no_fundings  =  new TokenAmount[]( 0 );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, no_fundings );

        assertEq( constraints.min_fundings.length, 0, "Collect fees should require no fundings." );
        assertEq( constraints.min_execution_delay_in_blocks, 3, "Min delay should be 3 blocks." );
        assertEq( constraints.max_execution_delay_in_seconds, 1 hours, "Max delay should be 1 hour for all SafeSwap actions." );
    }


    // ━━━━  BondRoute_quote_call( ) - Donate  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_donate_reverts_if_tokens_same( ) external
    {
        bytes memory call_data  =  _encode_donate_calldata( _create_donate_params( ) );

        TokenAmount[] memory preferred_fundings  =  new TokenAmount[](2);
        preferred_fundings[ 0 ]  =  TokenAmount({ token: token0, amount: 100 ether });
        preferred_fundings[ 1 ]  =  TokenAmount({ token: token0, amount: 200 ether });

        vm.expectRevert( "Tokens must be different" );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }

    function test_quote_call_donate_reverts_if_funding_count_not_2( ) external
    {
        bytes memory call_data  =  _encode_donate_calldata( _create_donate_params( ) );

        TokenAmount[] memory one_funding  =  _create_swap_fundings( 100 ether );
        vm.expectRevert( "Donate requires exactly 2 fundings" );
        hook.BondRoute_quote_call( call_data, token0, one_funding );
    }

    function test_quote_call_donate_returns_correct_execution_delays( ) external view
    {
        bytes memory call_data  =  _encode_donate_calldata( _create_donate_params( ) );

        TokenAmount[] memory preferred_fundings  =  _create_liquidity_fundings( 100 ether, 100 ether );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( constraints.min_execution_delay_in_blocks, 3, "Min delay should be 3 blocks." );
        assertEq( constraints.max_execution_delay_in_seconds, 1 hours, "Max delay should be 1 hour for all SafeSwap actions." );
    }


    // ━━━━  BondRoute_quote_call( ) - Unknown Selector  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_reverts_on_unknown_selector( ) external
    {
        bytes memory call_data  =  abi.encodeWithSelector( bytes4(0xdeadbeef) );
        TokenAmount[] memory preferred_fundings  =  new TokenAmount[]( 0 );

        vm.expectRevert( UnsupportedCall.selector );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }

    function test_quote_call_reverts_on_short_call( ) external
    {
        bytes memory call_data  =  hex"deadbe";
        TokenAmount[] memory preferred_fundings  =  new TokenAmount[]( 0 );

        vm.expectRevert( UnsupportedCall.selector );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }


    // ━━━━  BondRoute_quote_call( ) - Dynamic-Fee Pool Rejection  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_rejects_dynamic_fee_on_every_selector( ) external
    {
        uint24 dynamic_fee  =  LPFeeLibrary.DYNAMIC_FEE_FLAG;
        bytes memory expected_revert  =  abi.encodeWithSelector( UnsupportedFeeTier.selector, dynamic_fee );

        TokenAmount[] memory swap_funding       =  _create_swap_fundings( 100 ether );
        TokenAmount[] memory liquidity_fundings  =  _create_liquidity_fundings( 100 ether, 100 ether );
        TokenAmount[] memory no_fundings         =  new TokenAmount[]( 0 );

        // Exact input swap.
        ExactInputSwapParams memory exact_input_params  =  _create_exact_input_params( 90 ether );
        exact_input_params.pool_info.fee  =  dynamic_fee;
        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_exact_input_calldata( exact_input_params ), token0, swap_funding );

        // Exact output swap.
        ExactOutputSwapParams memory exact_output_params  =  _create_exact_output_params( 90 ether );
        exact_output_params.pool_info.fee  =  dynamic_fee;
        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_exact_output_calldata( exact_output_params ), token0, swap_funding );

        // Create position (fee carried directly in the signed params).
        CreatePositionParams memory create_params  =  _create_create_position_params( );
        create_params.pool_info.fee  =  dynamic_fee;
        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_create_position_calldata( create_params ), token0, liquidity_fundings );

        // Donate (fee carried directly in the signed params).
        DonateParams memory donate_params  =  _create_donate_params( );
        donate_params.pool_info.fee  =  dynamic_fee;
        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_donate_calldata( donate_params ), token0, liquidity_fundings );

        // Add / remove / collect inherit the fee from a dynamic-fee position's stored metadata.
        uint256 dynamic_fee_token_id  =  _seed_position_with_fee( dynamic_fee );

        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_add_liquidity_calldata( _create_add_liquidity_params( dynamic_fee_token_id, 100 ether ) ), token0, liquidity_fundings );

        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_remove_liquidity_calldata( _create_remove_liquidity_params( dynamic_fee_token_id, 100 ether ) ), token0, no_fundings );

        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_collect_fees_calldata( _create_collect_fees_params( dynamic_fee_token_id ) ), token0, no_fundings );
    }


    // ━━━━  BondRoute_get_signing_info( )  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_get_signing_info_exact_input_returns_valid_type_string( ) external view
    {
        bytes memory call_data  =  _encode_exact_input_calldata( _create_exact_input_params( 90 ether ) );
        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );
        _assert_valid_signing_info( typed_string, struct_hash, token_amount_offset );
    }

    function test_get_signing_info_exact_output_returns_valid_type_string( ) external view
    {
        bytes memory call_data  =  _encode_exact_output_calldata( _create_exact_output_params( 90 ether ) );
        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );
        _assert_valid_signing_info( typed_string, struct_hash, token_amount_offset );
    }

    function test_get_signing_info_create_position_returns_valid_type_string( ) external view
    {
        bytes memory call_data  =  _encode_create_position_calldata( _create_create_position_params( ) );
        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );
        _assert_valid_signing_info( typed_string, struct_hash, token_amount_offset );
    }

    function test_get_signing_info_add_liquidity_returns_valid_type_string( ) external view
    {
        bytes memory call_data  =  _encode_add_liquidity_calldata( _create_add_liquidity_params( 1, 100 ether ) );
        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );
        _assert_valid_signing_info( typed_string, struct_hash, token_amount_offset );
    }

    function test_get_signing_info_remove_liquidity_returns_valid_type_string( ) external view
    {
        bytes memory call_data  =  _encode_remove_liquidity_calldata( _create_remove_liquidity_params( 1, 100 ether ) );
        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );
        _assert_valid_signing_info( typed_string, struct_hash, token_amount_offset );
    }

    function test_get_signing_info_collect_fees_returns_valid_type_string( ) external view
    {
        bytes memory call_data  =  _encode_collect_fees_calldata( _create_collect_fees_params( 1 ) );
        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );
        _assert_valid_signing_info( typed_string, struct_hash, token_amount_offset );
    }

    function test_get_signing_info_donate_returns_valid_type_string( ) external view
    {
        bytes memory call_data  =  _encode_donate_calldata( _create_donate_params( ) );
        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );
        _assert_valid_signing_info( typed_string, struct_hash, token_amount_offset );
    }

    function _assert_valid_signing_info(
        string memory typed_string,
        bytes32 struct_hash,
        uint256 token_amount_offset
    ) private pure
    {
        bytes memory ts  =  bytes(typed_string);

        assertTrue( ts.length > 0,                 "Type string should not be empty." );
        assertTrue( struct_hash != bytes32(0),     "Struct hash should not be zero." );
        assertTrue( token_amount_offset > 0,       "Token amount offset should be positive." );

        // Verify the type string starts with the BondRoute envelope prefix.
        bytes memory prefix  =  bytes("ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,");
        assertTrue( ts.length >= prefix.length,    "Type string shorter than expected prefix." );
        for(  uint i = 0  ;  i < prefix.length  ;  i++  )
        {
            assertEq( ts[ i ], prefix[ i ],        "Type string should start with correct prefix." );
        }

        // Verify TokenAmount appears at the reported offset.
        bytes memory token_amount_type  =  bytes("TokenAmount(address token,uint256 amount)");
        assertTrue(
            ts.length >= token_amount_offset + token_amount_type.length,
            "Type string shorter than offset + TokenAmount type."
        );
        for(  uint i = 0  ;  i < token_amount_type.length  ;  i++  )
        {
            assertEq(
                ts[ token_amount_offset + i ],
                token_amount_type[ i ],
                "TokenAmount type should appear at specified offset."
            );
        }
    }

    function test_get_signing_info_reverts_on_unknown_selector( ) external
    {
        bytes memory call_data  =  abi.encodeWithSelector( bytes4(0xdeadbeef) );
        vm.expectRevert( UnsupportedCall.selector );
        hook.BondRoute_get_signing_info( call_data );
    }

    function test_get_signing_info_reverts_on_short_call( ) external
    {
        bytes memory call_data  =  hex"deadbe";
        vm.expectRevert( UnsupportedCall.selector );
        hook.BondRoute_get_signing_info( call_data );
    }

    function test_get_signing_info_struct_hash_changes_with_params( ) external view
    {
        ExactInputSwapParams memory params1  =  ExactInputSwapParams({ token_out: token1, minimum_output_amount: 90 ether, pool_info: _default_pool_info( ) });
        ExactInputSwapParams memory params2  =  ExactInputSwapParams({ token_out: token1, minimum_output_amount: 100 ether, pool_info: _default_pool_info( ) });

        ( , bytes32 struct_hash1, )  =  hook.BondRoute_get_signing_info( _encode_exact_input_calldata( params1 ) );
        ( , bytes32 struct_hash2, )  =  hook.BondRoute_get_signing_info( _encode_exact_input_calldata( params2 ) );

        assertTrue( struct_hash1 != struct_hash2, "Different params should produce different struct hashes." );
    }


    // ━━━━  Protected Function Access Control  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_swap_exact_input_reverts_if_not_bondroute( ) external
    {
        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.swap_exact_input( _create_exact_input_params( 90 ether ) );
    }

    function test_swap_exact_output_reverts_if_not_bondroute( ) external
    {
        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.swap_exact_output( _create_exact_output_params( 90 ether ) );
    }

    function test_create_position_reverts_if_not_bondroute( ) external
    {
        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.create_position( _create_create_position_params( ) );
    }

    function test_add_liquidity_reverts_if_not_bondroute( ) external
    {
        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.add_liquidity( _create_add_liquidity_params( 1, 100 ether ) );
    }

    function test_remove_liquidity_reverts_if_not_bondroute( ) external
    {
        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.remove_liquidity( _create_remove_liquidity_params( 1, 100 ether ) );
    }

    function test_collect_fees_reverts_if_not_bondroute( ) external
    {
        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.collect_fees( _create_collect_fees_params( 1 ) );
    }

    function test_donate_reverts_if_not_bondroute( ) external
    {
        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.donate( _create_donate_params( ) );
    }
}

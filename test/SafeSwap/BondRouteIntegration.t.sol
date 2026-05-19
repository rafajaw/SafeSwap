// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";


contract BondRouteIntegrationTest is SafeSwapTestBase {

    // ━━━━  BondRoute_get_protected_selectors( )  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_get_protected_selectors_returns_five_selectors( ) external view
    {
        bytes4[] memory selectors  =  hook.BondRoute_get_protected_selectors( );

        assertEq(
            selectors.length,
            5,
            "Should return exactly 5 protected selectors."
        );
    }

    function test_get_protected_selectors_includes_swap_exact_input( ) external view
    {
        bytes4[] memory selectors  =  hook.BondRoute_get_protected_selectors( );
        bool found  =  false;

        for(  uint i = 0  ;  i < selectors.length  ;  i = i + 1  )
        {
            if(  selectors[ i ] == hook.swap_exact_input.selector  )  found  =  true;
        }

        assertTrue( found, "Protected selectors should include swap_exact_input." );
    }

    function test_get_protected_selectors_includes_swap_exact_output( ) external view
    {
        bytes4[] memory selectors  =  hook.BondRoute_get_protected_selectors( );
        bool found  =  false;

        for(  uint i = 0  ;  i < selectors.length  ;  i = i + 1  )
        {
            if(  selectors[ i ] == hook.swap_exact_output.selector  )  found  =  true;
        }

        assertTrue( found, "Protected selectors should include swap_exact_output." );
    }

    function test_get_protected_selectors_includes_add_liquidity( ) external view
    {
        bytes4[] memory selectors  =  hook.BondRoute_get_protected_selectors( );
        bool found  =  false;

        for(  uint i = 0  ;  i < selectors.length  ;  i = i + 1  )
        {
            if(  selectors[ i ] == hook.add_liquidity.selector  )  found  =  true;
        }

        assertTrue( found, "Protected selectors should include add_liquidity." );
    }

    function test_get_protected_selectors_includes_remove_liquidity( ) external view
    {
        bytes4[] memory selectors  =  hook.BondRoute_get_protected_selectors( );
        bool found  =  false;

        for(  uint i = 0  ;  i < selectors.length  ;  i = i + 1  )
        {
            if(  selectors[ i ] == hook.remove_liquidity.selector  )  found  =  true;
        }

        assertTrue( found, "Protected selectors should include remove_liquidity." );
    }

    function test_get_protected_selectors_includes_donate( ) external view
    {
        bytes4[] memory selectors  =  hook.BondRoute_get_protected_selectors( );
        bool found  =  false;

        for(  uint i = 0  ;  i < selectors.length  ;  i = i + 1  )
        {
            if(  selectors[ i ] == hook.donate.selector  )  found  =  true;
        }

        assertTrue( found, "Protected selectors should include donate." );
    }

    function test_get_protected_selectors_gas_below_50000( ) external
    {
        uint256 gas_before  =  gasleft( );
        hook.BondRoute_get_protected_selectors( );
        uint256 gas_used  =  gas_before - gasleft( );

        assertLt(
            gas_used,
            50000,
            "BondRoute_get_protected_selectors should use less than 50,000 gas."
        );
    }


    // ━━━━  BondRoute_quote_call( ) - Exact Input Swap  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_exact_input_returns_correct_min_stake( ) external view
    {
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );
        bytes memory call_data  =  _encode_exact_input_calldata( params );

        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        // Stake is 1% of amount_in.
        assertEq(
            constraints.min_stake.amount,
            1 ether,
            "Min stake should be 1% of swap amount."
        );
    }

    function test_quote_call_exact_input_returns_correct_min_fundings( ) external view
    {
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );
        bytes memory call_data  =  _encode_exact_input_calldata( params );

        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq(
            constraints.min_fundings.length,
            1,
            "Should require exactly 1 funding."
        );
        assertEq(
            address(constraints.min_fundings[ 0 ].token),
            address(token0),
            "Funding token should be token_in."
        );
        assertEq(
            constraints.min_fundings[ 0 ].amount,
            100 ether,
            "Funding amount should equal amount_in."
        );
    }

    function test_quote_call_exact_input_returns_correct_execution_delays( ) external view
    {
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );
        bytes memory call_data  =  _encode_exact_input_calldata( params );

        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq(
            constraints.min_execution_delay_in_blocks,
            3,
            "Min execution delay should be 3 blocks."
        );
        assertEq(
            constraints.max_execution_delay_in_seconds,
            1 hours,
            "Max execution delay should be 1 hour."
        );
    }

    function test_quote_call_exact_input_reverts_if_tokens_same( ) external
    {
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token0,
            minimum_amount_out: 90 ether,
            pool_info: _default_pool_info( )
        });
        bytes memory call_data  =  _encode_exact_input_calldata( params );

        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        vm.expectRevert( "Tokens must be different" );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }

    function test_quote_call_exact_input_stake_is_in_input_token( ) external view
    {
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );
        bytes memory call_data  =  _encode_exact_input_calldata( params );

        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq(
            address(constraints.min_stake.token),
            address(token0),
            "Stake token should always be the input token."
        );
    }


    function test_quote_call_exact_input_reverts_if_funding_count_not_1( ) external
    {
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );
        bytes memory call_data  =  _encode_exact_input_calldata( params );

        // 0 fundings.
        TokenAmount[] memory zero_fundings  =  new TokenAmount[](0);
        vm.expectRevert( "Swaps require exactly 1 funding" );
        hook.BondRoute_quote_call( call_data, token0, zero_fundings );

        // 2 fundings.
        TokenAmount[] memory two_fundings  =  _create_liquidity_fundings( 100 ether, 100 ether );
        vm.expectRevert( "Swaps require exactly 1 funding" );
        hook.BondRoute_quote_call( call_data, token0, two_fundings );
    }


    // ━━━━  BondRoute_quote_call( ) - Exact Output Swap  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_exact_output_returns_correct_min_stake( ) external view
    {
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 90 ether );
        bytes memory call_data  =  _encode_exact_output_calldata( params );

        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        // Stake is 1% of maximum_amount_in.
        assertEq(
            constraints.min_stake.amount,
            1 ether,
            "Min stake should be 1% of max swap amount."
        );
    }

    function test_quote_call_exact_output_returns_correct_min_fundings( ) external view
    {
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 90 ether );
        bytes memory call_data  =  _encode_exact_output_calldata( params );

        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq(
            constraints.min_fundings.length,
            1,
            "Should require exactly 1 funding."
        );
        assertEq(
            constraints.min_fundings[ 0 ].amount,
            100 ether,
            "Funding amount should equal maximum_amount_in."
        );
    }

    function test_quote_call_exact_output_returns_correct_execution_delays( ) external view
    {
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 90 ether );
        bytes memory call_data  =  _encode_exact_output_calldata( params );

        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq(
            constraints.min_execution_delay_in_blocks,
            3,
            "Min execution delay should be 3 blocks."
        );
        assertEq(
            constraints.max_execution_delay_in_seconds,
            1 hours,
            "Max execution delay should be 1 hour."
        );
    }

    function test_quote_call_exact_output_reverts_if_tokens_same( ) external
    {
        ExactOutputSwapParams memory params  =  ExactOutputSwapParams({
            token_out: token0,
            amount_out: 90 ether,
            pool_info: _default_pool_info( )
        });
        bytes memory call_data  =  _encode_exact_output_calldata( params );

        TokenAmount[] memory preferred_fundings  =  _create_swap_fundings( 100 ether );

        vm.expectRevert( "Tokens must be different" );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }


    function test_quote_call_exact_output_reverts_if_funding_count_not_1( ) external
    {
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 90 ether );
        bytes memory call_data  =  _encode_exact_output_calldata( params );

        // 0 fundings.
        TokenAmount[] memory zero_fundings  =  new TokenAmount[](0);
        vm.expectRevert( "Swaps require exactly 1 funding" );
        hook.BondRoute_quote_call( call_data, token0, zero_fundings );

        // 2 fundings.
        TokenAmount[] memory two_fundings  =  _create_liquidity_fundings( 100 ether, 100 ether );
        vm.expectRevert( "Swaps require exactly 1 funding" );
        hook.BondRoute_quote_call( call_data, token0, two_fundings );
    }


    // ━━━━  BondRoute_quote_call( ) - Add Liquidity  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_add_liquidity_reverts_if_tokens_same( ) external
    {
        AddLiquidityParams memory params  =  _create_add_liquidity_params( );
        bytes memory call_data  =  _encode_add_liquidity_calldata( params );

        // Both fundings use the same token.
        TokenAmount[] memory preferred_fundings  =  new TokenAmount[](2);
        preferred_fundings[ 0 ]  =  TokenAmount({ token: token0, amount: 100 ether });
        preferred_fundings[ 1 ]  =  TokenAmount({ token: token0, amount: 100 ether });

        vm.expectRevert( "Tokens must be different" );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }


    function test_quote_call_add_liquidity_reverts_if_funding_count_not_2( ) external
    {
        AddLiquidityParams memory params  =  _create_add_liquidity_params( );
        bytes memory call_data  =  _encode_add_liquidity_calldata( params );

        // 0 fundings.
        TokenAmount[] memory zero_fundings  =  new TokenAmount[](0);
        vm.expectRevert( "Add liquidity requires exactly 2 fundings" );
        hook.BondRoute_quote_call( call_data, token0, zero_fundings );

        // 1 funding.
        TokenAmount[] memory one_funding  =  _create_swap_fundings( 100 ether );
        vm.expectRevert( "Add liquidity requires exactly 2 fundings" );
        hook.BondRoute_quote_call( call_data, token0, one_funding );

        // 3 fundings.
        TokenAmount[] memory three_fundings  =  new TokenAmount[](3);
        three_fundings[ 0 ]  =  TokenAmount({ token: token0, amount: 100 ether });
        three_fundings[ 1 ]  =  TokenAmount({ token: token1, amount: 100 ether });
        three_fundings[ 2 ]  =  TokenAmount({ token: token2, amount: 100 ether });
        vm.expectRevert( "Add liquidity requires exactly 2 fundings" );
        hook.BondRoute_quote_call( call_data, token0, three_fundings );
    }

    function test_quote_call_add_liquidity_returns_correct_execution_delays( ) external view
    {
        AddLiquidityParams memory params  =  _create_add_liquidity_params( );
        bytes memory call_data  =  _encode_add_liquidity_calldata( params );

        TokenAmount[] memory preferred_fundings  =  _create_liquidity_fundings( 100 ether, 100 ether );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( constraints.min_execution_delay_in_blocks,   3,       "Min delay should be 3 blocks." );
        assertEq( constraints.max_execution_delay_in_seconds,  1 hours, "Max delay should be 1 hour for all SafeSwap actions." );
    }


    // ━━━━  BondRoute_quote_call( ) - Remove Liquidity  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_remove_liquidity_reverts_if_tokens_same( ) external
    {
        RemoveLiquidityParams memory params  =  RemoveLiquidityParams({
            pool_info: _default_pool_info( ),
            tick_lower: -600,
            tick_upper: 600,
            liquidity: 100 ether,
            min_a: TokenAmount({ token: token0, amount: 0 }),
            min_b: TokenAmount({ token: token0, amount: 0 })
        });
        bytes memory call_data  =  _encode_remove_liquidity_calldata( params );

        TokenAmount[] memory preferred_fundings  =  new TokenAmount[]( 0 );

        vm.expectRevert( "Tokens must be different" );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }

    function test_quote_call_remove_liquidity_returns_correct_execution_delays( ) external view
    {
        RemoveLiquidityParams memory params  =  _create_remove_liquidity_params( 100 ether );
        bytes memory call_data  =  _encode_remove_liquidity_calldata( params );

        TokenAmount[] memory no_fundings  =  new TokenAmount[]( 0 );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, no_fundings );

        assertEq( constraints.min_execution_delay_in_blocks,   3,       "Min delay should be 3 blocks." );
        assertEq( constraints.max_execution_delay_in_seconds,  1 hours, "Max delay should be 1 hour for all SafeSwap actions." );
    }


    // ━━━━  BondRoute_quote_call( ) - Donate  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_donate_reverts_if_tokens_same( ) external
    {
        DonateParams memory params  =  DonateParams({
            pool_info: _default_pool_info( )
        });
        bytes memory call_data  =  _encode_donate_calldata( params );

        TokenAmount[] memory preferred_fundings  =  new TokenAmount[](2);
        preferred_fundings[ 0 ]  =  TokenAmount({ token: token0, amount: 100 ether });
        preferred_fundings[ 1 ]  =  TokenAmount({ token: token0, amount: 200 ether });

        vm.expectRevert( "Tokens must be different" );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }

    function test_quote_call_donate_reverts_if_funding_count_not_2( ) external
    {
        DonateParams memory params  =  _create_donate_params( );
        bytes memory call_data  =  _encode_donate_calldata( params );

        TokenAmount[] memory one_funding  =  _create_swap_fundings( 100 ether );
        vm.expectRevert( "Donate requires exactly 2 fundings" );
        hook.BondRoute_quote_call( call_data, token0, one_funding );
    }

    function test_quote_call_donate_returns_correct_execution_delays( ) external view
    {
        DonateParams memory params  =  _create_donate_params( );
        bytes memory call_data  =  _encode_donate_calldata( params );

        TokenAmount[] memory preferred_fundings  =  _create_liquidity_fundings( 100 ether, 100 ether );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, token0, preferred_fundings );

        assertEq( constraints.min_execution_delay_in_blocks,   3,       "Min delay should be 3 blocks." );
        assertEq( constraints.max_execution_delay_in_seconds,  1 hours, "Max delay should be 1 hour for all SafeSwap actions." );
    }


    // ━━━━  BondRoute_quote_call( ) - Unknown Selector  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_reverts_on_unknown_selector( ) external
    {
        bytes memory call_data  =  abi.encodeWithSelector( bytes4(0xdeadbeef) );

        TokenAmount[] memory preferred_fundings  =  new TokenAmount[]( 0 );

        vm.expectRevert( abi.encodeWithSelector( UnknownSelector.selector, bytes4(0xdeadbeef) ) );
        hook.BondRoute_quote_call( call_data, token0, preferred_fundings );
    }


    // ━━━━  BondRoute_quote_call( ) - Dynamic-Fee Pool Rejection  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_call_rejects_dynamic_fee_on_every_selector( ) external
    {
        uint24 dynamic_fee  =  LPFeeLibrary.DYNAMIC_FEE_FLAG;
        bytes memory expected_revert  =  abi.encodeWithSelector( UnsupportedFeeTier.selector, dynamic_fee );

        // Exact input swap.
        ExactInputSwapParams memory exact_input_params  =  _create_exact_input_params( 90 ether );
        exact_input_params.pool_info.fee  =  dynamic_fee;
        TokenAmount[] memory swap_funding  =  _create_swap_fundings( 100 ether );
        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_exact_input_calldata( exact_input_params ), token0, swap_funding );

        // Exact output swap.
        ExactOutputSwapParams memory exact_output_params  =  _create_exact_output_params( 90 ether );
        exact_output_params.pool_info.fee  =  dynamic_fee;
        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_exact_output_calldata( exact_output_params ), token0, swap_funding );

        // Add liquidity.
        AddLiquidityParams memory add_params  =  _create_add_liquidity_params( );
        add_params.pool_info.fee  =  dynamic_fee;
        TokenAmount[] memory liquidity_fundings  =  _create_liquidity_fundings( 100 ether, 100 ether );
        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_add_liquidity_calldata( add_params ), token0, liquidity_fundings );

        // Remove liquidity.
        RemoveLiquidityParams memory remove_params  =  _create_remove_liquidity_params( 100 ether );
        remove_params.pool_info.fee  =  dynamic_fee;
        TokenAmount[] memory no_fundings  =  new TokenAmount[]( 0 );
        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_remove_liquidity_calldata( remove_params ), token0, no_fundings );

        // Donate.
        DonateParams memory donate_params  =  _create_donate_params( );
        donate_params.pool_info.fee  =  dynamic_fee;
        vm.expectRevert( expected_revert );
        hook.BondRoute_quote_call( _encode_donate_calldata( donate_params ), token0, liquidity_fundings );
    }


    // ━━━━  BondRoute_get_signing_info( )  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_get_signing_info_exact_input_returns_valid_type_string( ) external view
    {
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );
        bytes memory call_data  =  _encode_exact_input_calldata( params );

        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );

        assertTrue( bytes(typed_string).length > 0, "Type string should not be empty." );
        assertTrue( struct_hash != bytes32(0), "Struct hash should not be zero." );
        assertTrue( token_amount_offset > 0, "Token amount offset should be positive." );

        // Verify the type string starts correctly.
        bytes memory prefix  =  bytes("ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,");
        for(  uint i = 0  ;  i < prefix.length  ;  i = i + 1  )
        {
            assertEq( bytes(typed_string)[ i ], prefix[ i ], "Type string should start with correct prefix." );
        }

        // Verify TokenAmount appears at the specified offset.
        bytes memory token_amount_type  =  bytes("TokenAmount(address token,uint256 amount)");
        for(  uint i = 0  ;  i < token_amount_type.length  ;  i = i + 1  )
        {
            assertEq(
                bytes(typed_string)[ token_amount_offset + i ],
                token_amount_type[ i ],
                "TokenAmount type should appear at specified offset."
            );
        }
    }

    function test_get_signing_info_exact_output_returns_valid_type_string( ) external view
    {
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 90 ether );
        bytes memory call_data  =  _encode_exact_output_calldata( params );

        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );

        assertTrue( bytes(typed_string).length > 0, "Type string should not be empty." );
        assertTrue( struct_hash != bytes32(0), "Struct hash should not be zero." );
        assertTrue( token_amount_offset > 0, "Token amount offset should be positive." );
    }

    function test_get_signing_info_add_liquidity_returns_valid_type_string( ) external view
    {
        AddLiquidityParams memory params  =  _create_add_liquidity_params( );
        bytes memory call_data  =  _encode_add_liquidity_calldata( params );

        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );

        assertTrue( bytes(typed_string).length > 0, "Type string should not be empty." );
        assertTrue( struct_hash != bytes32(0), "Struct hash should not be zero." );
        assertTrue( token_amount_offset > 0, "Token amount offset should be positive." );
    }

    function test_get_signing_info_remove_liquidity_returns_valid_type_string( ) external view
    {
        RemoveLiquidityParams memory params  =  _create_remove_liquidity_params( 100 ether );
        bytes memory call_data  =  _encode_remove_liquidity_calldata( params );

        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );

        assertTrue( bytes(typed_string).length > 0, "Type string should not be empty." );
        assertTrue( struct_hash != bytes32(0), "Struct hash should not be zero." );
        assertTrue( token_amount_offset > 0, "Token amount offset should be positive." );
    }

    function test_get_signing_info_donate_returns_valid_type_string( ) external view
    {
        DonateParams memory params  =  _create_donate_params( );
        bytes memory call_data  =  _encode_donate_calldata( params );

        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  hook.BondRoute_get_signing_info( call_data );

        assertTrue( bytes(typed_string).length > 0, "Type string should not be empty." );
        assertTrue( struct_hash != bytes32(0), "Struct hash should not be zero." );
        assertTrue( token_amount_offset > 0, "Token amount offset should be positive." );
    }

    function test_get_signing_info_reverts_on_unknown_selector( ) external
    {
        bytes memory call_data  =  abi.encodeWithSelector( bytes4(0xdeadbeef) );

        vm.expectRevert( abi.encodeWithSelector( UnknownSelector.selector, bytes4(0xdeadbeef) ) );
        hook.BondRoute_get_signing_info( call_data );
    }

    function test_get_signing_info_struct_hash_changes_with_params( ) external view
    {
        ExactInputSwapParams memory params1  =  ExactInputSwapParams({
            token_out: token1,
            minimum_amount_out: 90 ether,
            pool_info: _default_pool_info( )
        });

        ExactInputSwapParams memory params2  =  ExactInputSwapParams({
            token_out: token1,
            minimum_amount_out: 100 ether,  // Different amount.
            pool_info: _default_pool_info( )
        });

        bytes memory call_data1  =  _encode_exact_input_calldata( params1 );
        bytes memory call_data2  =  _encode_exact_input_calldata( params2 );

        ( , bytes32 struct_hash1, )  =  hook.BondRoute_get_signing_info( call_data1 );
        ( , bytes32 struct_hash2, )  =  hook.BondRoute_get_signing_info( call_data2 );

        assertTrue( struct_hash1 != struct_hash2, "Different params should produce different struct hashes." );
    }


    // ━━━━  Protected Function Access Control  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_swap_exact_input_reverts_if_not_bondroute( ) external
    {
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.swap_exact_input( params );
    }

    function test_swap_exact_output_reverts_if_not_bondroute( ) external
    {
        ExactOutputSwapParams memory params  =  _create_exact_output_params( 90 ether );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.swap_exact_output( params );
    }

    function test_add_liquidity_reverts_if_not_bondroute( ) external
    {
        AddLiquidityParams memory params  =  _create_add_liquidity_params( );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.add_liquidity( params );
    }

    function test_remove_liquidity_reverts_if_not_bondroute( ) external
    {
        RemoveLiquidityParams memory params  =  _create_remove_liquidity_params( 100 ether );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.remove_liquidity( params );
    }

    function test_donate_reverts_if_not_bondroute( ) external
    {
        DonateParams memory params  =  _create_donate_params( );

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, BONDROUTE_ADDRESS ) );
        hook.donate( params );
    }
}

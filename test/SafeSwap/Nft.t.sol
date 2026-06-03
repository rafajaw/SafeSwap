// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract NftTest is SafeSwapTestBase {

    function test_create_position_mints_lp_nft_and_uses_token_id_salt( ) external
    {
        CreatePositionParams memory params  =  _create_create_position_params( );
        BondContext memory context          =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        context.stake.amount                =  2 ether;

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        _execute_bondroute_call( _encode_create_position_calldata( params ), context );

        assertEq( safeswap_nft.ownerOf( 1 ), user, "User should own the minted LP NFT." );
        assertEq( safeswap_nft.balanceOf( user ), 1, "User should hold exactly one LP NFT." );
        assertEq( pool_manager.last_modify_salt( ), bytes32(uint256(1)), "V4 position salt should be the LP NFT token id." );

        SafeSwapPositionInfo memory position_info  =  safeswap_nft.get_lp_position( 1 );

        assertEq( address(position_info.token0), address(token0), "NFT metadata should store token0." );
        assertEq( address(position_info.token1), address(token1), "NFT metadata should store token1." );
        assertEq( position_info.fee, params.pool_info.fee, "NFT metadata should store pool fee." );
        assertEq( position_info.tick_spacing, params.pool_info.tick_spacing, "NFT metadata should store tick spacing." );
        assertEq( position_info.tick_lower, params.tick_lower, "NFT metadata should store lower tick." );
        assertEq( position_info.tick_upper, params.tick_upper, "NFT metadata should store upper tick." );
    }

    function test_safeswap_nft_transfer_moves_position_authority( ) external
    {
        CreatePositionParams memory create_params   =  _create_create_position_params( );
        BondContext memory create_context           =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        create_context.stake.amount                 =  2 ether;

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        _execute_bondroute_call( _encode_create_position_calldata( create_params ), create_context );

        vm.prank( user );
        safeswap_nft.transferFrom( user, other_user, 1 );

        RemovePositionLiquidityParams memory remove_params  =  _create_remove_liquidity_params( 1, 50 ether );
        BondContext memory old_owner_context                =  _create_modify_liquidity_no_funding_context( user );

        bytes memory unauthorized_revert  =  _execute_bondroute_call_expect_revert( _encode_remove_liquidity_calldata( remove_params ), old_owner_context );
        assertEq(
            unauthorized_revert,
            abi.encodeWithSelector( PositionUnauthorized.selector, 1, user, other_user ),
            "Previous NFT owner should no longer be authorized after transfer."
        );

        BondContext memory new_owner_context  =  _create_modify_liquidity_no_funding_context( other_user );

        pool_manager.set_mock_liquidity_amounts( 25 ether, 25 ether );

        uint256 other_user_token0_before  =  token0.balanceOf( other_user );
        uint256 other_user_token1_before  =  token1.balanceOf( other_user );

        _execute_bondroute_call( _encode_remove_liquidity_calldata( remove_params ), new_owner_context );

        assertEq( pool_manager.last_modify_salt( ), bytes32(uint256(1)), "Transferred NFT should keep the same V4 position salt." );
        assertEq( token0.balanceOf( other_user ) - other_user_token0_before, 25 ether, "New NFT owner should receive token0." );
        assertEq( token1.balanceOf( other_user ) - other_user_token1_before, 25 ether, "New NFT owner should receive token1." );
    }


    // ━━━━  POSITION AUTHORITY (approved / operator)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_position_approved_address_can_operate( ) external
    {
        uint256 token_id  =  _create_position_owned_by( user );

        vm.prank( user );
        safeswap_nft.approve( other_user, token_id );

        RemovePositionLiquidityParams memory remove_params  =  _create_remove_liquidity_params( token_id, 50 ether );
        BondContext memory approved_context                 =  _create_modify_liquidity_no_funding_context( other_user );

        pool_manager.set_mock_liquidity_amounts( 25 ether, 25 ether );

        // Single-token approval grants the operation authority; the call must succeed (no PositionUnauthorized).
        _execute_bondroute_call( _encode_remove_liquidity_calldata( remove_params ), approved_context );

        assertEq( pool_manager.last_modify_salt( ), bytes32(token_id), "Approved caller should operate on the owner's position." );
    }

    function test_position_operator_can_operate( ) external
    {
        uint256 token_id  =  _create_position_owned_by( user );

        vm.prank( user );
        safeswap_nft.setApprovalForAll( other_user, true );

        RemovePositionLiquidityParams memory remove_params  =  _create_remove_liquidity_params( token_id, 50 ether );
        BondContext memory operator_context                 =  _create_modify_liquidity_no_funding_context( other_user );

        pool_manager.set_mock_liquidity_amounts( 25 ether, 25 ether );

        // Operator (approval-for-all) grants the operation authority across all of the owner's positions.
        _execute_bondroute_call( _encode_remove_liquidity_calldata( remove_params ), operator_context );

        assertEq( pool_manager.last_modify_salt( ), bytes32(token_id), "Operator should operate on the owner's position." );
    }


    // ━━━━  POSITION NFT CONTRACT GUARDS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_mint_position_reverts_for_non_hook_caller( ) external
    {
        SafeSwapPositionInfo memory position_info  =  SafeSwapPositionInfo({
            token0:        token0,
            token1:        token1,
            fee:           _default_pool_info( ).fee,
            tick_spacing:  _default_pool_info( ).tick_spacing,
            tick_lower:    DEFAULT_TICK_LOWER,
            tick_upper:    DEFAULT_TICK_UPPER
        });

        // Only the configured SafeSwap hook may mint LP positions.
        vm.expectRevert( abi.encodeWithSelector( OnlySafeSwapHook.selector, address(this), address(hook) ) );
        safeswap_nft.mint_position( user, position_info );
    }

    function test_get_lp_position_reverts_for_nonexistent_token( ) external
    {
        vm.expectRevert( abi.encodeWithSignature( "ERC721NonexistentToken(uint256)", uint256(999) ) );
        safeswap_nft.get_lp_position( 999 );
    }


    // ━━━━  POOL INITIALIZATION PRICE GUARD  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_create_position_reverts_on_pool_price_mismatch( ) external
    {
        // The mock pool is already initialized at SQRT_PRICE_1_1; creating at a different price must revert.
        CreatePositionParams memory params  =  _create_create_position_params( );
        params.sqrt_price_x96               =  SQRT_PRICE_1_1 + 1;

        BondContext memory context  =  _create_bond_context_two_fundings( user, 100 ether, 100 ether );
        context.stake.amount        =  2 ether;

        bytes memory revert_data  =  _execute_bondroute_call_expect_revert( _encode_create_position_calldata( params ), context );

        assertEq( bytes4(revert_data), PoolInitializationPriceMismatch.selector, "Create against existing pool at wrong price should revert with PoolInitializationPriceMismatch." );
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// @dev Mints an LP position to `owner` through the BondRoute create flow. First mint per test → token id 1.
    function _create_position_owned_by( address owner ) private returns ( uint256 token_id )
    {
        CreatePositionParams memory params  =  _create_create_position_params( );
        BondContext memory context          =  _create_bond_context_two_fundings( owner, 100 ether, 100 ether );
        context.stake.amount                =  2 ether;

        pool_manager.set_mock_liquidity_amounts( -50 ether, -50 ether );

        _execute_bondroute_call( _encode_create_position_calldata( params ), context );

        token_id  =  1;
    }
}

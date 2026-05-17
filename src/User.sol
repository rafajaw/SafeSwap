// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/UniswapHook.sol";
import "@SafeSwap/integrations/BondRouteProtected.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolId } from "@UniswapV4Core/types/PoolId.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";

using StateLibrary for IPoolManager;


/**
 * @title User
 * @notice User-facing functions - swap and liquidity operations
 */
abstract contract User is UniswapHook, BondRouteProtected {

    constructor( address config_signer )
    UniswapHook( config_signer )
    BondRouteProtected( "SafeSwap", "Trustless MEV-free Uniswap V4 Hook" ) { }

    // ━━━━  USER FUNCTIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function swap_exact_input( ExactInputSwapParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        _allow_next_hook_callback( );

        PoolManager.unlock( bytes.concat( abi.encode( context, params ), bytes1(uint8(Action.ExactInputSwap)) ) );

        _clear_next_hook_callback( );
    }

    function swap_exact_output( ExactOutputSwapParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        _allow_next_hook_callback( );

        PoolManager.unlock( bytes.concat( abi.encode( context, params ), bytes1(uint8(Action.ExactOutputSwap)) ) );

        _clear_next_hook_callback( );
    }

    function add_liquidity( AddLiquidityParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        _allow_next_hook_callback( );

        PoolManager.unlock( bytes.concat( abi.encode( context, params ), bytes1(uint8(Action.AddLiquidity)) ) );

        _clear_next_hook_callback( );
    }

    function remove_liquidity( RemoveLiquidityParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        _allow_next_hook_callback( );

        PoolManager.unlock( bytes.concat( abi.encode( context, params ), bytes1(uint8(Action.RemoveLiquidity)) ) );

        _clear_next_hook_callback( );
    }

    function donate( DonateParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        _allow_next_hook_callback( );

        PoolManager.unlock( bytes.concat( abi.encode( context, params ), bytes1(uint8(Action.Donate)) ) );

        _clear_next_hook_callback( );
    }


    // ━━━━  OFF-CHAIN GETTERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function __OFF_CHAIN__get_position_info( PoolId pool_id, address user, int24 tick_lower, int24 tick_upper, bytes32 salt )
    external view returns ( uint128 liquidity, uint256 fee_growth_inside_0_last_x128, uint256 fee_growth_inside_1_last_x128 )
    {
        bytes32 effective_salt  =  SafeSwapCommon._position_salt( user, salt );

        ( liquidity, fee_growth_inside_0_last_x128, fee_growth_inside_1_last_x128 )  =  PoolManager.getPositionInfo(
            pool_id,
            address(this),
            tick_lower,
            tick_upper,
            effective_salt
        );
    }
}

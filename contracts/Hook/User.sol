// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/UniswapHook.sol";
import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapNft/ISafeSwapPositionNft.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";

using StateLibrary for IPoolManager;
using PoolIdLibrary for PoolKey;


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error PositionUnauthorized( uint256 token_id, address caller, address owner );
error PoolInitializationPriceMismatch( PoolId pool_id, uint160 current_sqrt_price_x96, uint160 expected_sqrt_price_x96 );


/**
 * @title User
 * @notice User-facing SafeSwap operations and position helper functions.
 */
abstract contract User is UniswapHook, BondRouteProtected {

    ISafeSwapPositionNft internal immutable PositionNft;

    constructor( )
    UniswapHook( )
    BondRouteProtected( SAFESWAP_PROTOCOL_NAME, SAFESWAP_PROTOCOL_DESCRIPTION )
    {
        address position_nft  =  ChainConfig.read_address( CONFIG_SIGNER, POSITION_NFT_KEY );
        if(  position_nft.code.length == 0  )  revert( "SafeSwap: Invalid position_nft" );

        PositionNft  =  ISafeSwapPositionNft(position_nft);
    }

    // ━━━━  USER FUNCTIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Execute an exact-input Uniswap V4 swap through BondRoute.
     * @param params Swap output token, minimum net output, and pool configuration.
     *
     * @dev BONDROUTE EXECUTION:
     *      - Callable only through a valid BondRoute bond.
     *      - Input token and input amount come from the bond fundings, not from `params`.
     *      - Stake is quoted as `SWAP_STAKE_PERCENTAGE` of the committed input amount.
     *
     * @dev POOL COMPATIBILITY:
     *      - Inherits Uniswap V4 PoolManager token compatibility; SafeSwap adds BondRoute gating, not custom token accounting.
     *      - Dynamic-fee pools are not supported.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if called outside BondRoute.
     *      - `SlippageExceeded(uint256 amount_received, uint256 minimum_required)` if net output is below `minimum_output_amount`.
     *      - `UnsupportedFeeTier(uint24 fee)` if the target pool uses dynamic fees.
     */
    function swap_exact_input( ExactInputSwapParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.ExactInputSwap)), abi.encode( context, params ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Execute an exact-output Uniswap V4 swap through BondRoute.
     * @param params Swap output token, exact net output amount, and pool configuration.
     *
     * @dev BONDROUTE EXECUTION:
     *      - Callable only through a valid BondRoute bond.
     *      - Input token and maximum input amount come from the bond fundings, not from `params`.
     *      - SafeSwap grosses up the pool output so the user receives `amount_out` after protocol fee.
     *
     * @dev POOL COMPATIBILITY:
     *      - Inherits Uniswap V4 PoolManager token compatibility; SafeSwap adds BondRoute gating, not custom token accounting.
     *      - Dynamic-fee pools are not supported.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if called outside BondRoute.
     *      - `SlippageExceeded(uint256 amount_received, uint256 minimum_required)` if required input exceeds the committed maximum.
     *      - `UnsupportedFeeTier(uint24 fee)` if the target pool uses dynamic fees.
     */
    function swap_exact_output( ExactOutputSwapParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.ExactOutputSwap)), abi.encode( context, params ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Create a new NFT-backed Uniswap V4 position through BondRoute.
     * @param params Pool configuration, tick range, initial liquidity, initial pool price, and minimum actual deposited amounts.
     *
     * @dev Mints one SafeSwap LP NFT to the BondRoute user. The minted `token_id` is used as the V4 position salt.
     */
    function create_position( CreatePositionParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )  =  _prepare_create_position( context, params );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.ModifyLiquidity)), abi.encode( context, executable_params, position_info ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Add liquidity to an existing NFT-backed Uniswap V4 position through BondRoute.
     * @param params LP NFT id, liquidity amount, and minimum actual deposited amounts.
     */
    function add_liquidity( AddPositionLiquidityParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )  =  _prepare_add_liquidity( context, params );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.ModifyLiquidity)), abi.encode( context, executable_params, position_info ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Remove liquidity from an existing NFT-backed Uniswap V4 position through BondRoute.
     * @param params LP NFT id, liquidity amount, and minimum actual received amounts.
     */
    function remove_liquidity( RemovePositionLiquidityParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )  =  _prepare_remove_liquidity( context, params );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.ModifyLiquidity)), abi.encode( context, executable_params, position_info ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Collect fees from an existing NFT-backed Uniswap V4 position through BondRoute.
     * @param params LP NFT id and minimum actual received fee amounts.
     */
    function collect_fees( CollectFeesParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )  =  _prepare_collect_fees( context, params );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.ModifyLiquidity)), abi.encode( context, executable_params, position_info ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Donate tokens to a Uniswap V4 pool through BondRoute.
     * @param params Pool configuration.
     *
     * @dev BONDROUTE EXECUTION:
     *      - Callable only through a valid BondRoute bond.
     *      - Token0, token1, and donation amounts come from the two bond fundings, not from `params`.
     *      - Stake is quoted as `LIQUIDITY_STAKE_PERCENTAGE` of total normalized value, denominated in token0.
     *
     * @dev POOL COMPATIBILITY:
     *      - Inherits Uniswap V4 PoolManager token compatibility; SafeSwap adds BondRoute gating, not custom token accounting.
     *      - Dynamic-fee pools are not supported.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if called outside BondRoute.
     *      - `UnsupportedFeeTier(uint24 fee)` if the target pool uses dynamic fees.
     */
    function donate( DonateParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.Donate)), abi.encode( context, params ) );
        PoolManager.unlock( data );
    }


    // ━━━━  POSITION GETTERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Compute the Uniswap V4 pool id for a SafeSwap pool.
     * @param token_a First pool token.
     * @param token_b Second pool token.
     * @param pool_info Pool fee and tick spacing.
     * @return pool_id Uniswap V4 pool identifier for this hook.
     *
     * @dev Standard V4 pool id with `hooks = address(this)`.
     */
    function __OFF_CHAIN__get_pool_id( IERC20 token_a, IERC20 token_b, PoolInfo calldata pool_info )
    external  view returns ( PoolId pool_id )
    {
        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key(
            token_a,
            token_b,
            pool_info.fee,
            pool_info.tick_spacing,
            address(this)
        );

        pool_id  =  pool_key.toId( );
    }

    /**
     * @notice Read a user's SafeSwap LP position state directly from the PoolManager.
     * @param pool_id Uniswap V4 pool identifier.
     * @param token_id SafeSwap LP NFT id.
     * @param tick_lower Lower tick of the position.
     * @param tick_upper Upper tick of the position.
     * @return liquidity Current position liquidity.
     * @return fee_growth_inside_0_last_x128 Last recorded token0 fee growth inside the tick range.
     * @return fee_growth_inside_1_last_x128 Last recorded token1 fee growth inside the tick range.
     *
     * @dev On-chain integrators: call `PoolManager.getPositionInfo` with `owner = address(this)`, `salt = bytes32(token_id)`.
     */
    function __OFF_CHAIN__get_position_info( PoolId pool_id, uint256 token_id, int24 tick_lower, int24 tick_upper )
    external  view returns ( uint128 liquidity, uint256 fee_growth_inside_0_last_x128, uint256 fee_growth_inside_1_last_x128 )
    {
        ( liquidity, fee_growth_inside_0_last_x128, fee_growth_inside_1_last_x128 )  =  PoolManager.getPositionInfo(
            pool_id,
            address(this),
            tick_lower,
            tick_upper,
            bytes32(token_id)
        );
    }


    // ━━━━  INTERNAL HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _prepare_create_position( BondContext memory context, CreatePositionParams memory params )
    internal returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        if(  params.liquidity == 0  ||  context.fundings.length != 2  )
        {
            revert InvalidLiquidityModification({ token_id: 0, liquidity_delta: _bounded_liquidity_for_error( params.liquidity ), funding_count: context.fundings.length });
        }

        ( IERC20 token0, , IERC20 token1, )  =  SafeSwapCommon.sort_token_amount_pair( context.fundings[ 0 ], context.fundings[ 1 ] );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( token0, token1, params.pool_info.fee, params.pool_info.tick_spacing, address(this) );
        PoolId pool_id           =  pool_key.toId( );

        ( uint160 current_sqrt_price_x96, , , )  =  PoolManager.getSlot0( pool_id );
        if(  current_sqrt_price_x96 == 0  )
        {
            // *SECURITY*  -  Permissionless V4 initialization would let anyone set the first price for this hooked pool.
            _allow_pool_initialization( pool_key, params.sqrt_price_x96 );
            PoolManager.initialize( pool_key, params.sqrt_price_x96 );
            _clear_pool_initialization_allowance( );
        }
        else if(  current_sqrt_price_x96 != params.sqrt_price_x96  )
        {
            revert PoolInitializationPriceMismatch({ pool_id: pool_id, current_sqrt_price_x96: current_sqrt_price_x96, expected_sqrt_price_x96: params.sqrt_price_x96 });
        }

        SafeSwapPositionInfo memory new_position_info  =  SafeSwapPositionInfo({
            pool_id:      pool_id,
            token0:       token0,
            token1:       token1,
            pool_info:    params.pool_info,
            tick_lower:   params.tick_lower,
            tick_upper:   params.tick_upper
        });

        uint256 token_id  =  PositionNft.mint_position( context.user, new_position_info );

        executable_params  =  ModifyLiquidityParams({
            token_id:           token_id,
            pool_info:          params.pool_info,
            tick_lower:         params.tick_lower,
            tick_upper:         params.tick_upper,
            liquidity_delta:    _positive_liquidity_delta( token_id, params.liquidity ),
            minimum_amount_a:   params.minimum_deposited_a,
            minimum_amount_b:   params.minimum_deposited_b
        });

        position_info  =  PositionNft.get_lp_position( token_id );
    }

    function _prepare_add_liquidity( BondContext memory context, AddPositionLiquidityParams memory params )
    internal view returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        _require_lp_position_authority( params.token_id, context.user );
        position_info  =  PositionNft.get_lp_position( params.token_id );

        executable_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          position_info.pool_info,
            tick_lower:         position_info.tick_lower,
            tick_upper:         position_info.tick_upper,
            liquidity_delta:    _positive_liquidity_delta( params.token_id, params.liquidity ),
            minimum_amount_a:   params.minimum_deposited_a,
            minimum_amount_b:   params.minimum_deposited_b
        });
    }

    function _prepare_remove_liquidity( BondContext memory context, RemovePositionLiquidityParams memory params )
    internal view returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        _require_lp_position_authority( params.token_id, context.user );
        position_info  =  PositionNft.get_lp_position( params.token_id );

        executable_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          position_info.pool_info,
            tick_lower:         position_info.tick_lower,
            tick_upper:         position_info.tick_upper,
            liquidity_delta:    -_positive_liquidity_delta( params.token_id, params.liquidity ),
            minimum_amount_a:   params.minimum_received_a,
            minimum_amount_b:   params.minimum_received_b
        });
    }

    function _prepare_collect_fees( BondContext memory context, CollectFeesParams memory params )
    internal view returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        _require_lp_position_authority( params.token_id, context.user );
        position_info  =  PositionNft.get_lp_position( params.token_id );

        executable_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          position_info.pool_info,
            tick_lower:         position_info.tick_lower,
            tick_upper:         position_info.tick_upper,
            liquidity_delta:    0,
            minimum_amount_a:   params.minimum_received_a,
            minimum_amount_b:   params.minimum_received_b
        });
    }

    function _require_lp_position_authority( uint256 token_id, address caller ) internal view
    {
        address owner       =  PositionNft.ownerOf( token_id );
        address approved    =  PositionNft.getApproved( token_id );
        bool operator       =  PositionNft.isApprovedForAll( owner, caller );
        bool is_authorized  =  caller == owner  ||  caller == approved  ||  operator;

        if(  is_authorized == false  )  revert PositionUnauthorized({ token_id: token_id, caller: caller, owner: owner });
    }

    function _positive_liquidity_delta( uint256 token_id, uint128 liquidity ) private pure returns ( int128 liquidity_delta )
    {
        if(  liquidity == 0  ||  liquidity > uint128(type(int128).max)  )
        {
            revert InvalidLiquidityModification({ token_id: token_id, liquidity_delta: _bounded_liquidity_for_error( liquidity ), funding_count: 0 });
        }

        liquidity_delta  =  int128(liquidity);
    }

    function _bounded_liquidity_for_error( uint128 liquidity ) private pure returns ( int128 liquidity_delta )
    {
        liquidity_delta  =  liquidity > uint128(type(int128).max)  ?  type(int128).max  :  int128(liquidity);
    }
}

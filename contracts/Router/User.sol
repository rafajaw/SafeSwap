// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwapRouter/Orchestrator.sol";
import "@SafeSwapRouter/HookRegistry.sol";
import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapNft/ISafeSwapNft.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";

using StateLibrary for IPoolManager;
using PoolIdLibrary for PoolKey;


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error PositionUnauthorized( uint256 token_id, address caller, address owner );
error PoolInitializationPriceMismatch( PoolId pool_id, uint160 current_sqrt_price_x96, uint160 expected_sqrt_price_x96 );


/**
 * @title User
 * @notice User-facing SafeSwap operations and position helper functions, executed by the canonical router.
 */
abstract contract User is Orchestrator, HookRegistry, BondRouteProtected {

    ISafeSwapNft internal immutable SafeSwapNft;

    constructor( )
    Orchestrator( )
    BondRouteProtected( SAFESWAP_PROTOCOL_NAME, SAFESWAP_PROTOCOL_DESCRIPTION )
    {
        address safeswap_nft  =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_NFT_KEY );
        if(  safeswap_nft.code.length == 0  )  revert( "SafeSwap: Invalid position" );

        SafeSwapNft  =  ISafeSwapNft(safeswap_nft);
    }

    // ━━━━  USER FUNCTIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Execute an exact-input Uniswap V4 swap through BondRoute.
     * @param params Swap output token, minimum net output, and pool configuration (base fee, rebate profile, tick spacing).
     *
     * @dev BONDROUTE EXECUTION:
     *      - Callable only through a valid BondRoute bond.
     *      - Input token and input amount come from the bond fundings, not from `params`.
     *      - Stake is quoted as `SWAP_STAKE_PERCENTAGE` of the committed input amount.
     *
     * @dev The pool's LP repricing rebate is measured from the swap's real tick movement and donated to LPs; the user's
     *      net output is reduced by the protocol fee and the rebate, and checked against `minimum_output_amount`.
     */
    function swap_exact_input( ExactInputSwapParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        address hook  =  _resolve_hook( params.pool_info.rebate_profile );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.ExactInputSwap)), abi.encode( context, params, hook ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Execute an exact-output Uniswap V4 swap through BondRoute.
     * @param params Swap output token, exact net output amount, and pool configuration.
     *
     * @dev BONDROUTE EXECUTION:
     *      - Callable only through a valid BondRoute bond.
     *      - Input token and maximum input amount come from the bond fundings, not from `params`.
     *      - SafeSwap grosses up the pool output so the user receives `exact_output_amount` after protocol fee.
     *
     * @dev Because the output is fixed, the LP repricing rebate is charged on the input side and counts against the
     *      committed maximum input.
     */
    function swap_exact_output( ExactOutputSwapParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        address hook  =  _resolve_hook( params.pool_info.rebate_profile );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.ExactOutputSwap)), abi.encode( context, params, hook ) );
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
     * @notice Donate tokens to a SafeSwap Uniswap V4 pool through BondRoute.
     * @param params Pool configuration.
     *
     * @dev Token0, token1, and donation amounts come from the two bond fundings, not from `params`. A direct donation
     *      carries no repricing rebate.
     */
    function donate( DonateParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        address hook  =  _resolve_hook( params.pool_info.rebate_profile );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.Donate)), abi.encode( context, params, hook ) );
        PoolManager.unlock( data );
    }


    // ━━━━  OFF-CHAIN GETTERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Compute the Uniswap V4 pool id for a SafeSwap pool.
     * @param token_a First pool token.
     * @param token_b Second pool token.
     * @param pool_info Base fee, rebate profile, and tick spacing.
     * @return pool_id Uniswap V4 pool identifier for this configuration's hook.
     */
    function __OFF_CHAIN__get_pool_id( IERC20 token_a, IERC20 token_b, PoolInfo calldata pool_info )
    external  view returns ( PoolId pool_id )
    {
        address hook  =  _resolve_hook( pool_info.rebate_profile );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key(
            token_a,
            token_b,
            SafeSwapCommon.base_fee_units( pool_info.base_fee_bps ),
            pool_info.tick_spacing,
            hook
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

    /**
     * @notice Preview the LP repricing rebate for a hypothetical swap, given the tick movement an integrator simulated.
     * @param rebate_profile Pool's LP repricing rebate profile.
     * @param charged_amount Amount the rebate is charged against (output for exact-input, input for exact-output).
     * @param tick_before Pool tick before the swap.
     * @param tick_after Pool tick after the swap (from an off-chain swap simulation).
     * @return rebate_amount Amount that would be donated to LPs.
     * @return movement_bps Approximate price movement in basis points.
     *
     * @dev Execution uses the swap's real measured movement; integrators obtain `tick_after` from a V4 swap quote.
     */
    function __OFF_CHAIN__preview_repricing_rebate( uint8 rebate_profile, uint256 charged_amount, int24 tick_before, int24 tick_after )
    external  pure returns ( uint256 rebate_amount, uint256 movement_bps )
    {
        ( rebate_amount, movement_bps )  =  SafeSwapCommon.compute_repricing_rebate( tick_before, tick_after, rebate_profile, charged_amount );
    }


    // ━━━━  INTERNAL HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _prepare_create_position( BondContext memory context, CreatePositionParams memory params )
    internal returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        if(  params.liquidity == 0  ||  context.fundings.length != 2  )
        {
            revert InvalidLiquidityModification({ token_id: 0, liquidity_delta: _bounded_liquidity_for_error( params.liquidity ), funding_count: context.fundings.length });
        }

        ( IERC20 token0, , IERC20 token1, )  =  SafeSwapCommon.sort_token_amount_pair( context.fundings[ 0 ], context.fundings[ 1 ] );

        address hook       =  _resolve_hook( params.pool_info.rebate_profile );
        uint24 fee_units   =  SafeSwapCommon.base_fee_units( params.pool_info.base_fee_bps );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( token0, token1, fee_units, params.pool_info.tick_spacing, hook );
        PoolId pool_id           =  pool_key.toId( );

        ( uint160 current_sqrt_price_x96, , , )  =  PoolManager.getSlot0( pool_id );
        if(  current_sqrt_price_x96 == 0  )
        {
            // *SECURITY*  -  Permissionless V4 initialization would let anyone set the first price for this hooked pool, but
            //                the SafeSwap hook rejects any initialization whose sender is not this router, so this is the only path.
            _initialize_pool( pool_key, params.sqrt_price_x96 );
        }
        else if(  current_sqrt_price_x96 != params.sqrt_price_x96  )
        {
            revert PoolInitializationPriceMismatch({ pool_id: pool_id, current_sqrt_price_x96: current_sqrt_price_x96, expected_sqrt_price_x96: params.sqrt_price_x96 });
        }

        SafeSwapPositionInfo memory new_position_info  =  SafeSwapPositionInfo({
            hook:           hook,
            token0:         token0,
            token1:         token1,
            base_fee_bps:   params.pool_info.base_fee_bps,
            rebate_profile: params.pool_info.rebate_profile,
            tick_spacing:   params.pool_info.tick_spacing,
            tick_lower:     params.tick_lower,
            tick_upper:     params.tick_upper
        });

        uint256 token_id  =  SafeSwapNft.mint_position( context.user, new_position_info );

        executable_params  =  ModifyLiquidityParams({
            token_id:           token_id,
            pool_info:          params.pool_info,
            tick_lower:         params.tick_lower,
            tick_upper:         params.tick_upper,
            liquidity_delta:    _positive_liquidity_delta( token_id, params.liquidity ),
            minimum_amount_a:   params.minimum_deposited_a,
            minimum_amount_b:   params.minimum_deposited_b
        });

        position_info  =  SafeSwapNft.get_lp_position( token_id );
    }

    function _prepare_add_liquidity( BondContext memory context, AddPositionLiquidityParams memory params )
    internal view returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        _require_lp_position_authority( params.token_id, context.user );
        position_info  =  SafeSwapNft.get_lp_position( params.token_id );

        executable_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          _pool_info_from_position( position_info ),
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
        position_info  =  SafeSwapNft.get_lp_position( params.token_id );

        executable_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          _pool_info_from_position( position_info ),
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
        position_info  =  SafeSwapNft.get_lp_position( params.token_id );

        executable_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          _pool_info_from_position( position_info ),
            tick_lower:         position_info.tick_lower,
            tick_upper:         position_info.tick_upper,
            liquidity_delta:    0,
            minimum_amount_a:   params.minimum_received_a,
            minimum_amount_b:   params.minimum_received_b
        });
    }

    function _pool_info_from_position( SafeSwapPositionInfo memory position_info ) internal pure returns ( PoolInfo memory )
    {
        return PoolInfo({
            base_fee_bps:   position_info.base_fee_bps,
            rebate_profile: position_info.rebate_profile,
            tick_spacing:   position_info.tick_spacing
        });
    }

    function _require_lp_position_authority( uint256 token_id, address caller ) internal view
    {
        address owner       =  SafeSwapNft.ownerOf( token_id );
        address approved    =  SafeSwapNft.getApproved( token_id );
        bool operator       =  SafeSwapNft.isApprovedForAll( owner, caller );
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

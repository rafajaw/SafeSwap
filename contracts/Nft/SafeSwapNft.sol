// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*

        ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
        ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
        ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
        ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
        ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
        ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
        ━━━━━━━━━━━━━━━━━━  SafeSwap LP position manager  ━━━━━━━━━━━━━━━━━

*/

import "@SafeSwapNft/ISafeSwapNft.sol";
import { ISafeSwapPositionDescriptor } from "@SafeSwapNft/ISafeSwapPositionDescriptor.sol";
import "@SafeSwapCommon/PoolManagerIntegration.sol";
import "@SafeSwapCommon/SafeSwapCommon.sol";
import "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";
import "@BondRouteProtected/BondRouteProtected.sol";
import {
    CONFIG_SIGNER,
    SAFESWAP_ROUTER_KEY,
    SAFESWAP_POSITION_DESCRIPTOR_KEY,
    SAFESWAP_POSITIONS_NAME,
    SAFESWAP_POSITIONS_DESCRIPTION
} from "@SafeSwapCommon/Definitions.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { ERC721 } from "@OpenZeppelin/token/ERC721/ERC721.sol";
import { IUnlockCallback } from "@UniswapV4Core/interfaces/callback/IUnlockCallback.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";

using StateLibrary for IPoolManager;
using PoolIdLibrary for PoolKey;


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error PositionUnauthorized( uint256 token_id, address caller, address owner );
error PoolInitializationPriceMismatch( PoolId pool_id, uint160 current_sqrt_price_x96, uint160 expected_sqrt_price_x96 );


// ━━━━  ROUTER VIEW  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface ISafeSwapRouterHooks {
    function get_hook( uint16 base_fee_bps, uint8 rebate_percent ) external view returns ( address hook );
}


/**
 * @title SafeSwapNft
 * @notice Shared ERC721 position manager for SafeSwap LP positions. It owns the Uniswap V4 positions it represents (it is
 *         the `modifyLiquidity` caller; the V4 salt is the NFT token id), and exposes the BondRoute-protected position
 *         lifecycle: create, add, remove, collect. Swaps live in the separate SwapRouter; this contract is its own BondRoute
 *         protocol surface.
 *
 * @dev Pools are dynamic-fee (the hook applies the LP fee), so every PoolKey uses `DYNAMIC_FEE_FLAG`. The config hook for a
 *      new position is resolved from the canonical router's registry (`router.get_hook`); follow-up actions read the hook
 *      from the position's stored metadata.
 */
contract SafeSwapNft is ERC721, ISafeSwapNft, PoolManagerIntegration, BondRouteProtected, IUnlockCallback {

    address public immutable SafeSwapRouter;
    address public immutable PositionDescriptor;    // external on-chain metadata renderer (keeps this contract under EIP-170).

    uint256 private _next_token_id;

    mapping( uint256 => SafeSwapPositionInfo ) private _position_infos;

    constructor( )
    ERC721( "SafeSwap LP Positions", "SSWAP-LP" )
    PoolManagerIntegration( )
    BondRouteProtected( SAFESWAP_POSITIONS_NAME, SAFESWAP_POSITIONS_DESCRIPTION )
    {
        address router  =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_ROUTER_KEY );
        if(  router.code.length == 0  )  revert( "SafeSwapNft: Invalid router" );

        address descriptor  =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_POSITION_DESCRIPTOR_KEY );
        if(  descriptor.code.length == 0  )  revert( "SafeSwapNft: Invalid descriptor" );

        SafeSwapRouter      =  router;
        PositionDescriptor  =  descriptor;
        _next_token_id      =  1;
    }


    // ━━━━  METADATA  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice ERC721 token metadata as an on-chain `data:application/json;base64,...` URI. Delegates rendering to the
     *         external `PositionDescriptor` so this contract stays under the EIP-170 size limit.
     */
    function tokenURI( uint256 token_id )
    public  view override returns ( string memory )
    {
        _requireOwned( token_id );

        return ISafeSwapPositionDescriptor(PositionDescriptor).build_token_uri( this, token_id );
    }

    /**
     * @notice OpenSea collection-level metadata as an on-chain `data:application/json;base64,...` URI.
     */
    function contractURI( )
    external  view returns ( string memory )
    {
        return ISafeSwapPositionDescriptor(PositionDescriptor).build_contract_uri( );
    }


    // ━━━━  USER FUNCTIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Create a new NFT-backed Uniswap V4 position through BondRoute. Mints one LP NFT to the bonded user; the minted
     *         token id is the V4 position salt. Initializes the pool at the signed price if it does not exist yet.
     */
    function create_position( CreatePositionParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )  =  _prepare_create_position( context, params );

        PoolManager.unlock( abi.encode( context, executable_params, position_info ) );
    }

    /**
     * @notice Add liquidity to an existing NFT-backed position through BondRoute.
     */
    function add_liquidity( AddPositionLiquidityParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )  =  _prepare_add_liquidity( context, params );

        PoolManager.unlock( abi.encode( context, executable_params, position_info ) );
    }

    /**
     * @notice Remove liquidity from an existing NFT-backed position through BondRoute.
     */
    function remove_liquidity( RemovePositionLiquidityParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )  =  _prepare_remove_liquidity( context, params );

        PoolManager.unlock( abi.encode( context, executable_params, position_info ) );
    }

    /**
     * @notice Collect fees from an existing NFT-backed position through BondRoute.
     */
    function collect_fees( CollectFeesParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )  =  _prepare_collect_fees( context, params );

        PoolManager.unlock( abi.encode( context, executable_params, position_info ) );
    }

    // ━━━━  BONDROUTE INTERFACE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function BondRoute_get_protected_selectors( )
    public  pure override returns ( bytes4[] memory selectors )
    {
        selectors       =  new bytes4[]( 4 );
        selectors[ 0 ]  =  this.create_position.selector;
        selectors[ 1 ]  =  this.add_liquidity.selector;
        selectors[ 2 ]  =  this.remove_liquidity.selector;
        selectors[ 3 ]  =  this.collect_fees.selector;
    }

    function BondRoute_quote_call( bytes calldata call, IERC20 preferred_stake_token, TokenAmount[] memory preferred_fundings )
    public  view override returns ( BondConstraints memory constraints )
    {
        if(  call.length < 4  )  revert UnsupportedCall( );

        bytes4 selector  =  bytes4(call);

        if(  selector == this.create_position.selector  )
        {
            CreatePositionParams memory params  =  abi.decode( call[ 4: ], (CreatePositionParams) );
            return ModifyLiquidityLib.get_create_position_constraints( params, preferred_stake_token, preferred_fundings );
        }
        else if(  selector == this.add_liquidity.selector  )
        {
            AddPositionLiquidityParams memory params    =  abi.decode( call[ 4: ], (AddPositionLiquidityParams) );
            SafeSwapPositionInfo memory position_info   =  get_lp_position( params.token_id );
            ModifyLiquidityParams memory modify_params  =  _add_liquidity_modify_params( params, position_info );
            return ModifyLiquidityLib.get_constraints( modify_params, preferred_stake_token, preferred_fundings, PoolManager, position_info );
        }
        else if(  selector == this.remove_liquidity.selector  )
        {
            RemovePositionLiquidityParams memory params  =  abi.decode( call[ 4: ], (RemovePositionLiquidityParams) );
            SafeSwapPositionInfo memory position_info    =  get_lp_position( params.token_id );
            ModifyLiquidityParams memory modify_params   =  _remove_liquidity_modify_params( params, position_info );
            return ModifyLiquidityLib.get_constraints( modify_params, preferred_stake_token, preferred_fundings, PoolManager, position_info );
        }
        else if(  selector == this.collect_fees.selector  )
        {
            CollectFeesParams memory params             =  abi.decode( call[ 4: ], (CollectFeesParams) );
            SafeSwapPositionInfo memory position_info   =  get_lp_position( params.token_id );
            ModifyLiquidityParams memory modify_params  =  _collect_fees_modify_params( params, position_info );
            return ModifyLiquidityLib.get_constraints( modify_params, preferred_stake_token, preferred_fundings, PoolManager, position_info );
        }
        else
        {
            revert UnsupportedCall( );
        }
    }

    function BondRoute_get_signing_info( bytes calldata call )
    external  pure override returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        if(  call.length < 4  )  revert UnsupportedCall( );

        bytes4 selector  =  bytes4(call);

        if(  selector == this.create_position.selector  )
        {
            CreatePositionParams memory params  =  abi.decode( call[ 4: ], (CreatePositionParams) );
            return ModifyLiquidityLib.get_create_position_signing_info( params );
        }
        else if(  selector == this.add_liquidity.selector  )
        {
            AddPositionLiquidityParams memory params  =  abi.decode( call[ 4: ], (AddPositionLiquidityParams) );
            return ModifyLiquidityLib.get_add_liquidity_signing_info( params );
        }
        else if(  selector == this.remove_liquidity.selector  )
        {
            RemovePositionLiquidityParams memory params  =  abi.decode( call[ 4: ], (RemovePositionLiquidityParams) );
            return ModifyLiquidityLib.get_remove_liquidity_signing_info( params );
        }
        else if(  selector == this.collect_fees.selector  )
        {
            CollectFeesParams memory params  =  abi.decode( call[ 4: ], (CollectFeesParams) );
            return ModifyLiquidityLib.get_collect_fees_signing_info( params );
        }
        else
        {
            revert UnsupportedCall( );
        }
    }


    // ━━━━  UNLOCK CALLBACK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Execute the prepared liquidity modification. The PoolManager only invokes `unlockCallback` on the address that
     *         opened the lock, so this runs solely with data built by this contract's own protected functions.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not PoolManager.
     */
    function unlockCallback( bytes calldata data )
    external  override returns ( bytes memory )
    {
        if(  msg.sender != address(PoolManager)  )  revert Unauthorized({ caller: msg.sender, expected: address(PoolManager) });

        ( BondContext memory context, ModifyLiquidityParams memory params, SafeSwapPositionInfo memory position_info )  =  abi.decode( data, (BondContext, ModifyLiquidityParams, SafeSwapPositionInfo) );

        ModifyLiquidityLib.execute( context, params, PoolManager, position_info );

        return "";
    }


    // ━━━━  POSITION GETTERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Read immutable metadata for an NFT-backed SafeSwap LP position.
     */
    function get_lp_position( uint256 token_id )
    public  view returns ( SafeSwapPositionInfo memory position_info )
    {
        _requireOwned( token_id );

        position_info  =  _position_infos[ token_id ];
    }

    /**
     * @notice Read a position's live V4 state directly from the PoolManager (owner = this NFT, salt = token id).
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


    // ━━━━  INTERNAL HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _prepare_create_position( BondContext memory context, CreatePositionParams memory params )
    internal returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        if(  params.liquidity == 0  ||  context.fundings.length != 2  )
        {
            revert InvalidLiquidityModification({ token_id: 0, liquidity_delta: _bounded_liquidity_for_error( params.liquidity ), funding_count: context.fundings.length });
        }

        ( IERC20 token0, , IERC20 token1, )  =  SafeSwapCommon.sort_token_amount_pair( context.fundings[ 0 ], context.fundings[ 1 ] );

        address hook  =  ISafeSwapRouterHooks(SafeSwapRouter).get_hook( params.pool_info.base_fee_bps, params.pool_info.rebate_percent );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( token0, token1, LPFeeLibrary.DYNAMIC_FEE_FLAG, params.pool_info.tick_spacing, hook );
        PoolId pool_id           =  pool_key.toId( );

        ( uint160 current_sqrt_price_x96, , , )  =  PoolManager.getSlot0( pool_id );
        if(  current_sqrt_price_x96 == 0  )
        {
            // *SECURITY*  -  The SafeSwap hook rejects any initialization whose sender is not this NFT, so this is the only
            //                path that can set a SafeSwap pool's first price, and it uses the BondRoute-signed price.
            PoolManager.initialize( pool_key, params.sqrt_price_x96 );
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
            rebate_percent: params.pool_info.rebate_percent,
            tick_spacing:   params.pool_info.tick_spacing,
            tick_lower:     params.tick_lower,
            tick_upper:     params.tick_upper
        });

        uint256 token_id  =  _next_token_id;
        _next_token_id    =  _next_token_id + 1;

        _position_infos[ token_id ]  =  new_position_info;
        _mint( context.user, token_id );

        executable_params  =  ModifyLiquidityParams({
            token_id:           token_id,
            pool_info:          params.pool_info,
            tick_lower:         params.tick_lower,
            tick_upper:         params.tick_upper,
            liquidity_delta:    _positive_liquidity_delta( token_id, params.liquidity ),
            minimum_amount_a:   params.minimum_deposited_a,
            minimum_amount_b:   params.minimum_deposited_b
        });

        position_info  =  new_position_info;
    }

    function _prepare_add_liquidity( BondContext memory context, AddPositionLiquidityParams memory params )
    internal view returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        _require_lp_position_authority( params.token_id, context.user );
        position_info  =  get_lp_position( params.token_id );

        executable_params  =  _add_liquidity_modify_params( params, position_info );
    }

    function _prepare_remove_liquidity( BondContext memory context, RemovePositionLiquidityParams memory params )
    internal view returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        _require_lp_position_authority( params.token_id, context.user );
        position_info  =  get_lp_position( params.token_id );

        executable_params  =  _remove_liquidity_modify_params( params, position_info );
    }

    function _prepare_collect_fees( BondContext memory context, CollectFeesParams memory params )
    internal view returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        _require_lp_position_authority( params.token_id, context.user );
        position_info  =  get_lp_position( params.token_id );

        executable_params  =  _collect_fees_modify_params( params, position_info );
    }

    function _add_liquidity_modify_params( AddPositionLiquidityParams memory params, SafeSwapPositionInfo memory position_info )
    private pure returns ( ModifyLiquidityParams memory modify_params )
    {
        modify_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          _pool_info_from_position( position_info ),
            tick_lower:         position_info.tick_lower,
            tick_upper:         position_info.tick_upper,
            liquidity_delta:    _positive_liquidity_delta( params.token_id, params.liquidity ),
            minimum_amount_a:   params.minimum_deposited_a,
            minimum_amount_b:   params.minimum_deposited_b
        });
    }

    function _remove_liquidity_modify_params( RemovePositionLiquidityParams memory params, SafeSwapPositionInfo memory position_info )
    private pure returns ( ModifyLiquidityParams memory modify_params )
    {
        modify_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          _pool_info_from_position( position_info ),
            tick_lower:         position_info.tick_lower,
            tick_upper:         position_info.tick_upper,
            liquidity_delta:    -_positive_liquidity_delta( params.token_id, params.liquidity ),
            minimum_amount_a:   params.minimum_received_a,
            minimum_amount_b:   params.minimum_received_b
        });
    }

    function _collect_fees_modify_params( CollectFeesParams memory params, SafeSwapPositionInfo memory position_info )
    private pure returns ( ModifyLiquidityParams memory modify_params )
    {
        modify_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          _pool_info_from_position( position_info ),
            tick_lower:         position_info.tick_lower,
            tick_upper:         position_info.tick_upper,
            liquidity_delta:    0,
            minimum_amount_a:   params.minimum_received_a,
            minimum_amount_b:   params.minimum_received_b
        });
    }

    function _pool_info_from_position( SafeSwapPositionInfo memory position_info ) private pure returns ( PoolInfo memory )
    {
        return PoolInfo({
            base_fee_bps:   position_info.base_fee_bps,
            rebate_percent: position_info.rebate_percent,
            tick_spacing:   position_info.tick_spacing
        });
    }

    function _require_lp_position_authority( uint256 token_id, address caller ) private view
    {
        address owner       =  ownerOf( token_id );
        address approved    =  getApproved( token_id );
        bool operator       =  isApprovedForAll( owner, caller );
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

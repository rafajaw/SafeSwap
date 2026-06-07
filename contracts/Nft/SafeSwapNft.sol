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
import { ISafeSwapSigningDescriptor } from "@SafeSwapCommon/ISafeSwapSigningDescriptor.sol";
import "@SafeSwapCommon/PoolManagerIntegration.sol";
import "@SafeSwapCommon/SafeSwapCommon.sol";
import "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";
import "@BondRouteProtected/BondRouteProtected.sol";
import {
    CONFIG_SIGNER,
    SAFESWAP_ROUTER_KEY,
    SAFESWAP_POSITION_DESCRIPTOR_KEY,
    SAFESWAP_SIGNING_DESCRIPTOR_KEY,
    SAFESWAP_POSITIONS_NAME,
    SAFESWAP_POSITIONS_SYMBOL,
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
import { FullMath } from "@UniswapV4Core/libraries/FullMath.sol";
import { FixedPoint128 } from "@UniswapV4Core/libraries/FixedPoint128.sol";

using StateLibrary for IPoolManager;
using PoolIdLibrary for PoolKey;


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error PositionUnauthorized( uint256 token_id, address caller, address owner );
error PoolInitializationPriceMismatch( PoolId pool_id, uint160 current_sqrt_price_x96, uint160 expected_sqrt_price_x96 );
error FeeTotalOverflow( uint256 token_id, uint256 earned0, uint256 earned1 );


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

    struct FeeTotals {
        uint128 earned0;
        uint128 earned1;
    }

    address public immutable SafeSwapRouter;
    address public immutable PositionDescriptor;    // external on-chain metadata builder.
    address public immutable SigningDescriptor;     // external on-chain EIP-712 signing-info builder.

    // Token ids are derived (not sequential): each mint bumps this counter and hashes it with the chain id and this
    // contract address, keeping the low 8 bytes (see `_compute_next_token_id`). The counter itself is never a token id.
    uint96 private _token_counter;

    mapping( uint256 => SafeSwapPositionInfo ) private _position_infos;
    mapping( uint256 => FeeTotals ) private _fee_totals;

    constructor( )
    ERC721( SAFESWAP_POSITIONS_NAME, SAFESWAP_POSITIONS_SYMBOL )
    PoolManagerIntegration( )
    BondRouteProtected( SAFESWAP_POSITIONS_NAME, SAFESWAP_POSITIONS_DESCRIPTION )
    {
        address safe_swap_router  =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_ROUTER_KEY );
        if(  safe_swap_router.code.length == 0  )  revert( "SafeSwapNft: Invalid router" );

        address position_descriptor  =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_POSITION_DESCRIPTOR_KEY );
        if(  position_descriptor.code.length == 0  )  revert( "SafeSwapNft: Invalid descriptor" );

        address signing_descriptor  =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_SIGNING_DESCRIPTOR_KEY );
        if(  signing_descriptor.code.length == 0  )  revert( "SafeSwapNft: Invalid signing_descriptor" );

        SafeSwapRouter      =  safe_swap_router;
        PositionDescriptor  =  position_descriptor;
        SigningDescriptor   =  signing_descriptor;
    }


    // ━━━━  METADATA  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice ERC721 token metadata as an on-chain `data:application/json;base64,...` URI. Delegates rendering to the
     *         external `PositionDescriptor`.
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
            return ModifyLiquidityLib.get_create_position_constraints( params, preferred_stake_token );
        }
        else if(  selector == this.add_liquidity.selector  )
        {
            AddPositionLiquidityParams memory params    =  abi.decode( call[ 4: ], (AddPositionLiquidityParams) );
            SafeSwapPositionInfo memory position_info   =  get_lp_position( params.token_id );
            ModifyLiquidityParams memory modify_params  =  _add_liquidity_modify_params( params, position_info );
            TokenAmount[] memory declared_fundings      =  new TokenAmount[](2);
            declared_fundings[0]                        =  params.maximum_deposit_a;
            declared_fundings[1]                        =  params.maximum_deposit_b;
            return ModifyLiquidityLib.get_constraints( modify_params, preferred_stake_token, declared_fundings, PoolManager, position_info );
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
    external  view override returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        return ISafeSwapSigningDescriptor(SigningDescriptor).build_nft_signing_info({
            safe_swap_nft: this,
            protected_call: call
        });
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

        _record_earned_fees( params, position_info );

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

    /**
     * @notice Lifetime fees checkpointed into SafeSwap accounting before prior position touches.
     */
    function get_lp_fee_totals( uint256 token_id )
    external  view returns ( uint256 earned0, uint256 earned1 )
    {
        _requireOwned( token_id );

        FeeTotals storage totals  =  _fee_totals[ token_id ];
        earned0                   =  totals.earned0;
        earned1                   =  totals.earned1;
    }


    // ━━━━  INTERNAL HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _prepare_create_position( BondContext memory context, CreatePositionParams memory params ) internal returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        if(  params.liquidity == 0  )
        {
            revert InvalidLiquidityModification({ token_id: 0, liquidity_delta: _bounded_liquidity_for_error( params.liquidity ), funding_count: context.fundings.length });
        }

        ModifyLiquidityLib.validate_create_fundings( params, context.fundings );
        ( IERC20 token0, , IERC20 token1, )  =  SafeSwapCommon.sort_token_amount_pair( params.maximum_deposit_a, params.maximum_deposit_b );

        // *SOURCE OF TRUTH*  -  The user signs human Range / Price, not raw ticks. Derive the position ticks from the signed
        //                      sqrt-price bounds (snapped to tick spacing); see SIGNING_UX_REFERENCE_2.md / ModifyLiquidityLib.
        // *NOTE*             -  Benchmarked at ~4.7k-4.9k gas: ~1% of first-pool execution or ~2% when the pool already
        //                      exists. This one-time mint cost is accepted so wallets can display and sign human bounds.
        ( int24 tick_lower, int24 tick_upper )  =  ModifyLiquidityLib.derive_ticks_from_price_bounds( params.sqrt_price_lower_x96, params.sqrt_price_upper_x96, params.pool_info.tick_spacing );

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
            opened_at:      uint40(block.timestamp),
            hook:           hook,
            token0:         token0,
            token1:         token1,
            base_fee_bps:   params.pool_info.base_fee_bps,
            rebate_percent: params.pool_info.rebate_percent,
            tick_spacing:   params.pool_info.tick_spacing,
            tick_lower:     tick_lower,
            tick_upper:     tick_upper
        });

        uint256 token_id  =  _compute_next_token_id( );

        _position_infos[ token_id ]  =  new_position_info;
        _mint( context.user, token_id );

        executable_params  =  ModifyLiquidityParams({
            token_id:           token_id,
            pool_info:          params.pool_info,
            tick_lower:         tick_lower,
            tick_upper:         tick_upper,
            liquidity_delta:    _positive_liquidity_delta( token_id, params.liquidity ),
            minimum_amount_a:   TokenAmount({ token: params.maximum_deposit_a.token, amount: params.minimum_deposit_a }),
            minimum_amount_b:   TokenAmount({ token: params.maximum_deposit_b.token, amount: params.minimum_deposit_b })
        });

        position_info  =  new_position_info;
    }

    function _prepare_add_liquidity( BondContext memory context, AddPositionLiquidityParams memory params ) internal view returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        _require_lp_position_authority( params.token_id, context.user );
        ModifyLiquidityLib.validate_add_fundings( params, context.fundings );
        position_info  =  get_lp_position( params.token_id );

        executable_params  =  _add_liquidity_modify_params( params, position_info );
    }

    function _prepare_remove_liquidity( BondContext memory context, RemovePositionLiquidityParams memory params ) internal view returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        _require_lp_position_authority( params.token_id, context.user );
        position_info  =  get_lp_position( params.token_id );

        executable_params  =  _remove_liquidity_modify_params( params, position_info );
    }

    function _prepare_collect_fees( BondContext memory context, CollectFeesParams memory params ) internal view returns ( ModifyLiquidityParams memory executable_params, SafeSwapPositionInfo memory position_info )
    {
        _require_lp_position_authority( params.token_id, context.user );
        position_info  =  get_lp_position( params.token_id );

        executable_params  =  _collect_fees_modify_params( params, position_info );
    }

    function _add_liquidity_modify_params( AddPositionLiquidityParams memory params, SafeSwapPositionInfo memory position_info ) private pure returns ( ModifyLiquidityParams memory modify_params )
    {
        modify_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          _pool_info_from_position( position_info ),
            tick_lower:         position_info.tick_lower,
            tick_upper:         position_info.tick_upper,
            liquidity_delta:    _positive_liquidity_delta( params.token_id, params.liquidity ),
            minimum_amount_a:   TokenAmount({ token: params.maximum_deposit_a.token, amount: params.minimum_deposit_a }),
            minimum_amount_b:   TokenAmount({ token: params.maximum_deposit_b.token, amount: params.minimum_deposit_b })
        });
    }

    function _remove_liquidity_modify_params( RemovePositionLiquidityParams memory params, SafeSwapPositionInfo memory position_info ) private pure returns ( ModifyLiquidityParams memory modify_params )
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

    function _collect_fees_modify_params( CollectFeesParams memory params, SafeSwapPositionInfo memory position_info ) private pure returns ( ModifyLiquidityParams memory modify_params )
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

    /**
     * @notice Derive the next token id: bump the counter, then keep the low 8 bytes of
     *         `keccak256( chain id, this address, counter )` so ids read as opaque hex instead of 1, 2, 3 — and the
     *         same Nth position differs across chains / deployments. The collision loop is defensive: truncating the
     *         hash makes a clash unlikely at realistic mint counts (8 bytes = 2^64) but not impossible, and `_mint`
     *         reverts on a duplicate id, so we re-roll until the id is unused (and non-zero). It executes once in practice.
     */
    function _compute_next_token_id( ) private returns ( uint256 token_id )
    {
        while(  true  )
        {
            _token_counter  =  _token_counter + 1;

            uint96 token_counter  =  _token_counter;
            assembly ("memory-safe")
            {
                // Hash preimage in scratch:
                // 0x00..0x1f  [ chainid()                                               ] 32 bytes
                // 0x20..0x3f  [ address(this) 20 bytes ][   token_counter 12 bytes      ] 32 bytes
                mstore( 0x00, chainid() )
                mstore( 0x20, or( shl( 96, address() ), token_counter ) )
                token_id  :=  and( keccak256( 0x00, 64 ), sub( shl( 64, 1 ), 1 ) )
            }

            if(  token_id != 0  &&  _ownerOf( token_id ) == address(0)  )  break;
        }
    }

    function _require_lp_position_authority( uint256 token_id, address caller ) private view
    {
        address owner       =  ownerOf( token_id );
        address approved    =  getApproved( token_id );
        bool operator       =  isApprovedForAll( owner, caller );
        bool is_authorized  =  caller == owner  ||  caller == approved  ||  operator;

        if(  is_authorized == false  )  revert PositionUnauthorized({ token_id: token_id, caller: caller, owner: owner });
    }

    function _record_earned_fees( ModifyLiquidityParams memory params, SafeSwapPositionInfo memory position_info ) private
    {
        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key(
            position_info.token0,
            position_info.token1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            position_info.tick_spacing,
            position_info.hook
        );
        PoolId pool_id  =  pool_key.toId( );

        ( uint128 liquidity, uint256 fee_growth_0_last, uint256 fee_growth_1_last )  =  PoolManager.getPositionInfo(
            pool_id,
            address(this),
            params.tick_lower,
            params.tick_upper,
            bytes32(params.token_id)
        );

        if(  liquidity == 0  )  return;

        ( uint256 fee_growth_0_inside, uint256 fee_growth_1_inside )  =  PoolManager.getFeeGrowthInside( pool_id, params.tick_lower, params.tick_upper );

        uint256 fee_growth_delta0;
        uint256 fee_growth_delta1;
        unchecked
        {
            fee_growth_delta0  =  fee_growth_0_inside - fee_growth_0_last;
            fee_growth_delta1  =  fee_growth_1_inside - fee_growth_1_last;
        }

        uint256 earned0  =  FullMath.mulDiv( fee_growth_delta0, liquidity, FixedPoint128.Q128 );
        uint256 earned1  =  FullMath.mulDiv( fee_growth_delta1, liquidity, FixedPoint128.Q128 );

        FeeTotals storage totals  =  _fee_totals[ params.token_id ];
        uint256 next_earned0      =  uint256(totals.earned0) + earned0;
        uint256 next_earned1      =  uint256(totals.earned1) + earned1;

        if(  next_earned0 > type(uint128).max  ||  next_earned1 > type(uint128).max  )
        {
            revert FeeTotalOverflow({ token_id: params.token_id, earned0: next_earned0, earned1: next_earned1 });
        }

        // *NOTE*  -  These totals are lifetime earned fees checkpointed before a position touch. They are not limited to
        //            explicit collect calls, and they intentionally exclude remove-liquidity principal.
        totals.earned0  =  uint128(next_earned0);
        totals.earned1  =  uint128(next_earned1);
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

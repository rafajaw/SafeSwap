// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/User.sol";
import "@SafeSwapNft/ISafeSwapNft.sol";


/**
 * @title BondRouteIntegration
 * @notice BondRoute selector, quote, validation, and signing-info integration for SafeSwap.
 */
abstract contract BondRouteIntegration is User {

    constructor( )
    User( ) { }


    // ━━━━  BONDROUTE INTERFACE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Return the SafeSwap selectors that require BondRoute execution.
     * @return selectors Protected function selectors exposed by this contract.
     */
    function BondRoute_get_protected_selectors( )
    public  pure override returns ( bytes4[] memory selectors )
    {
        selectors       =  new bytes4[]( 7 );
        selectors[ 0 ]  =  this.swap_exact_input.selector;
        selectors[ 1 ]  =  this.swap_exact_output.selector;
        selectors[ 2 ]  =  this.create_position.selector;
        selectors[ 3 ]  =  this.add_liquidity.selector;
        selectors[ 4 ]  =  this.remove_liquidity.selector;
        selectors[ 5 ]  =  this.collect_fees.selector;
        selectors[ 6 ]  =  this.donate.selector;
    }

    /**
     * @notice Quote BondRoute constraints for a SafeSwap action.
     * @param call Encoded SafeSwap function call.
     * @param preferred_fundings Funding tokens and amounts the user intends to authorize.
     * @return constraints Required stake, fundings, and timing constraints for the call.
     *
     * @dev The preferred stake token argument is intentionally unused. SafeSwap derives stake token from action economics:
     *      swap stake is in the input token; liquidity and donation stake is denominated in token0.
     *
     * @dev ERROR CODES:
     *      - `UnsupportedCall()` if `call` does not target a protected SafeSwap action.
     *      - `Error(string)` if the funding count is invalid or token pair is invalid.
     *      - `UnsupportedFeeTier(uint24 fee)` if the target pool uses dynamic fees.
     */
    function BondRoute_quote_call( bytes calldata call, IERC20 preferred_stake_token, TokenAmount[] memory preferred_fundings )
    public  view override returns ( BondConstraints memory constraints )
    {
        if(  call.length < 4  )  revert UnsupportedCall( );

        bytes4 selector  =  bytes4(call);

        if(  selector == this.swap_exact_input.selector  )
        {
            ExactInputSwapParams memory params  =  abi.decode( call[ 4: ], (ExactInputSwapParams) );
            return ExactInputSwapLib.get_constraints( params, preferred_fundings );
        }
        else if(  selector == this.swap_exact_output.selector  )
        {
            ExactOutputSwapParams memory params  =  abi.decode( call[ 4: ], (ExactOutputSwapParams) );
            return ExactOutputSwapLib.get_constraints( params, preferred_fundings );
        }
        else if(  selector == this.create_position.selector  )
        {
            CreatePositionParams memory params  =  abi.decode( call[ 4: ], (CreatePositionParams) );
            return ModifyLiquidityLib.get_create_position_constraints( params, preferred_stake_token, preferred_fundings );
        }
        else if(  selector == this.add_liquidity.selector  )
        {
            AddPositionLiquidityParams memory params          =  abi.decode( call[ 4: ], (AddPositionLiquidityParams) );
            SafeSwapPositionInfo memory position_info         =  SafeSwapNft.get_lp_position( params.token_id );
            ModifyLiquidityParams memory modify_params        =  _add_liquidity_modify_params( params, position_info );
            return ModifyLiquidityLib.get_constraints( modify_params, preferred_stake_token, preferred_fundings, PoolManager, address(this), position_info );
        }
        else if(  selector == this.remove_liquidity.selector  )
        {
            RemovePositionLiquidityParams memory params       =  abi.decode( call[ 4: ], (RemovePositionLiquidityParams) );
            SafeSwapPositionInfo memory position_info         =  SafeSwapNft.get_lp_position( params.token_id );
            ModifyLiquidityParams memory modify_params        =  _remove_liquidity_modify_params( params, position_info );
            return ModifyLiquidityLib.get_constraints( modify_params, preferred_stake_token, preferred_fundings, PoolManager, address(this), position_info );
        }
        else if(  selector == this.collect_fees.selector  )
        {
            CollectFeesParams memory params                   =  abi.decode( call[ 4: ], (CollectFeesParams) );
            SafeSwapPositionInfo memory position_info         =  SafeSwapNft.get_lp_position( params.token_id );
            ModifyLiquidityParams memory modify_params        =  _collect_fees_modify_params( params, position_info );
            return ModifyLiquidityLib.get_constraints( modify_params, preferred_stake_token, preferred_fundings, PoolManager, address(this), position_info );
        }
        else if(  selector == this.donate.selector  )
        {
            DonateParams memory params  =  abi.decode( call[ 4: ], (DonateParams) );
            return DonateLib.get_constraints( params, preferred_stake_token, preferred_fundings, PoolManager, address(this) );
        }
        else
        {
            revert UnsupportedCall( );
        }
    }

    /**
     * @notice Return SafeSwap-specific EIP-712 signing information for a protected call.
     * @param call Encoded SafeSwap function call.
     * @return typed_string Complete EIP-712 type string for wallet display.
     * @return struct_hash Hash of the typed SafeSwap call struct.
     * @return token_amount_offset Byte offset used by BondRoute wallet tooling for TokenAmount display.
     *
     * @dev Unsupported calls revert so wallets do not present unsupported SafeSwap actions for signing.
     */
    function BondRoute_get_signing_info( bytes calldata call )
    external  pure override returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        if(  call.length < 4  )  revert UnsupportedCall( );

        bytes4 selector  =  bytes4(call);

        if(  selector == this.swap_exact_input.selector  )
        {
            ExactInputSwapParams memory params  =  abi.decode( call[ 4: ], (ExactInputSwapParams) );
            return ExactInputSwapLib.get_signing_info( params );
        }
        else if(  selector == this.swap_exact_output.selector  )
        {
            ExactOutputSwapParams memory params  =  abi.decode( call[ 4: ], (ExactOutputSwapParams) );
            return ExactOutputSwapLib.get_signing_info( params );
        }
        else if(  selector == this.create_position.selector  )
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
        else if(  selector == this.donate.selector  )
        {
            DonateParams memory params  =  abi.decode( call[ 4: ], (DonateParams) );
            return DonateLib.get_signing_info( params );
        }
        else
        {
            revert UnsupportedCall( );
        }
    }

    function _add_liquidity_modify_params( AddPositionLiquidityParams memory params, SafeSwapPositionInfo memory position_info )
    private pure returns ( ModifyLiquidityParams memory modify_params )
    {
        modify_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          PoolInfo({ fee: position_info.fee, tick_spacing: position_info.tick_spacing }),
            tick_lower:         position_info.tick_lower,
            tick_upper:         position_info.tick_upper,
            liquidity_delta:    _quote_positive_liquidity_delta( params.token_id, params.liquidity ),
            minimum_amount_a:   params.minimum_deposited_a,
            minimum_amount_b:   params.minimum_deposited_b
        });
    }

    function _remove_liquidity_modify_params( RemovePositionLiquidityParams memory params, SafeSwapPositionInfo memory position_info )
    private pure returns ( ModifyLiquidityParams memory modify_params )
    {
        modify_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          PoolInfo({ fee: position_info.fee, tick_spacing: position_info.tick_spacing }),
            tick_lower:         position_info.tick_lower,
            tick_upper:         position_info.tick_upper,
            liquidity_delta:    -_quote_positive_liquidity_delta( params.token_id, params.liquidity ),
            minimum_amount_a:   params.minimum_received_a,
            minimum_amount_b:   params.minimum_received_b
        });
    }

    function _collect_fees_modify_params( CollectFeesParams memory params, SafeSwapPositionInfo memory position_info )
    private pure returns ( ModifyLiquidityParams memory modify_params )
    {
        modify_params  =  ModifyLiquidityParams({
            token_id:           params.token_id,
            pool_info:          PoolInfo({ fee: position_info.fee, tick_spacing: position_info.tick_spacing }),
            tick_lower:         position_info.tick_lower,
            tick_upper:         position_info.tick_upper,
            liquidity_delta:    0,
            minimum_amount_a:   params.minimum_received_a,
            minimum_amount_b:   params.minimum_received_b
        });
    }

    function _quote_positive_liquidity_delta( uint256 token_id, uint128 liquidity ) private pure returns ( int128 liquidity_delta )
    {
        if(  liquidity == 0  ||  liquidity > uint128(type(int128).max)  )
        {
            int128 bounded_liquidity  =  liquidity > uint128(type(int128).max)  ?  type(int128).max  :  int128(liquidity);
            revert InvalidLiquidityModification({ token_id: token_id, liquidity_delta: bounded_liquidity, funding_count: 0 });
        }

        liquidity_delta  =  int128(liquidity);
    }
}

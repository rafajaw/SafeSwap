// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ISafeSwapRouterHooks } from "@SafeSwapNft/SafeSwapNft.sol";
import { ERC6909_INTERFACE_ID } from "@SafeSwapCommon/PoolManagerIntegration.sol";
import { IERC20, TokenAmount, BondContext, NATIVE_TOKEN } from "@BondRouteProtected/BondRouteProtected.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IProtocolFees } from "@UniswapV4Core/interfaces/IProtocolFees.sol";
import { IUnlockCallback } from "@UniswapV4Core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta, toBalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";


contract MockSafeSwapNftRouter is ISafeSwapRouterHooks {

    bool internal _should_revert;

    address public hook;
    uint16 public last_base_fee_bps;
    uint8 public last_rebate_percent;

    constructor( address initial_hook )
    {
        hook  =  initial_hook;
    }

    function set_hook( address value )
    external
    {
        hook  =  value;
    }

    function set_should_revert( bool value )
    external
    {
        _should_revert  =  value;
    }

    function get_hook( uint16 base_fee_bps, uint8 rebate_percent )
    external  view returns ( address )
    {
        if(  _should_revert  )  revert( "hook resolution failed" );

        base_fee_bps;
        rebate_percent;

        return hook;
    }

    function record_hook_request( uint16 base_fee_bps, uint8 rebate_percent )
    external
    {
        last_base_fee_bps    =  base_fee_bps;
        last_rebate_percent  =  rebate_percent;
    }
}


contract MockSafeSwapNftPoolManager {
    using PoolIdLibrary for PoolKey;

    mapping( bytes32 => bytes32 ) internal _slots;

    bool public initialize_called;
    PoolKey public last_initialize_key;
    uint160 public last_initialize_sqrt_price_x96;

    bool public modify_liquidity_called;
    PoolKey public last_modify_liquidity_key;
    IPoolManager.ModifyLiquidityParams public last_modify_liquidity_params;
    BalanceDelta public next_modify_liquidity_delta;

    uint256 public sync_call_count;
    uint256 public settle_call_count;
    uint256 public settle_value_received;
    uint256 public take_call_count;
    Currency public last_take_currency;
    address public last_take_to;
    uint256 public last_take_amount;

    receive( ) external payable { }

    function set_slot( bytes32 slot, bytes32 value )
    external
    {
        _slots[ slot ]  =  value;
    }

    function set_next_modify_liquidity_delta( int128 amount0, int128 amount1 )
    external
    {
        next_modify_liquidity_delta  =  toBalanceDelta( amount0, amount1 );
    }

    function protocolFeeController( )
    external pure returns ( address )
    {
        return address(0xC0FFEE);
    }

    function supportsInterface( bytes4 interface_id )
    external pure returns ( bool )
    {
        return interface_id == ERC6909_INTERFACE_ID;
    }

    function extsload( bytes32 slot )
    external  view returns ( bytes32 )
    {
        return _slots[ slot ];
    }

    function extsload( bytes32 start_slot, uint256 count )
    external  view returns ( bytes32[] memory values )
    {
        values  =  new bytes32[](count);

        for(  uint256 i = 0  ;  i < count  ;  i = i + 1  )
        {
            values[ i ]  =  _slots[ bytes32(uint256(start_slot) + i) ];
        }
    }

    function extsload( bytes32[] calldata slots )
    external  view returns ( bytes32[] memory values )
    {
        values  =  new bytes32[](slots.length);

        for(  uint256 i = 0  ;  i < slots.length  ;  i = i + 1  )
        {
            values[ i ]  =  _slots[ slots[ i ] ];
        }
    }

    function initialize( PoolKey memory key, uint160 sqrt_price_x96 )
    external returns ( int24 tick )
    {
        initialize_called              =  true;
        last_initialize_key            =  key;
        last_initialize_sqrt_price_x96 =  sqrt_price_x96;
        _slots[ _pool_state_slot( key.toId( ) ) ]  =  bytes32(uint256(sqrt_price_x96));

        tick  =  0;
    }

    function unlock( bytes calldata data )
    external returns ( bytes memory )
    {
        return IUnlockCallback(msg.sender).unlockCallback( data );
    }

    function modifyLiquidity( PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, bytes calldata )
    external returns ( BalanceDelta callerDelta, BalanceDelta feesAccrued )
    {
        modify_liquidity_called  =  true;
        last_modify_liquidity_key =  key;
        last_modify_liquidity_params =  params;

        callerDelta  =  next_modify_liquidity_delta;
        feesAccrued  =  toBalanceDelta( 0, 0 );
    }

    function sync( Currency )
    external
    {
        sync_call_count  =  sync_call_count + 1;
    }

    function settle( )
    external payable returns ( uint256 )
    {
        settle_call_count      =  settle_call_count + 1;
        settle_value_received  =  settle_value_received + msg.value;
        return msg.value;
    }

    function take( Currency currency, address to, uint256 amount )
    external
    {
        take_call_count    =  take_call_count + 1;
        last_take_currency =  currency;
        last_take_to       =  to;
        last_take_amount   =  amount;
    }

    function last_initialize_fee( ) external view returns ( uint24 )
    {
        return last_initialize_key.fee;
    }

    function last_modify_liquidity_salt( ) external view returns ( bytes32 )
    {
        return last_modify_liquidity_params.salt;
    }

    function last_modify_liquidity_delta( ) external view returns ( int256 )
    {
        return last_modify_liquidity_params.liquidityDelta;
    }

    function last_modify_liquidity_hook( ) external view returns ( address )
    {
        return address(last_modify_liquidity_key.hooks);
    }

    function last_modify_liquidity_tick_spacing( ) external view returns ( int24 )
    {
        return last_modify_liquidity_key.tickSpacing;
    }

    function _pool_state_slot( PoolId pool_id ) private pure returns ( bytes32 state_slot )
    {
        assembly ("memory-safe")
        {
            mstore( 0x00, pool_id )
            mstore( 0x20, 6 )
            state_slot  :=  keccak256( 0x00, 0x40 )
        }
    }
}


contract MockBondRouteForNft {

    receive( ) external payable { }

    function announce_protocol( string calldata, string calldata )
    external payable
    {
    }

    // *FIDELITY*  -  Mirrors real BondRoute: fundings live in the bond owner's wallet and are pulled via
    //                transferFrom(context.user, ...). BondRoute never holds the funding tokens. (Etched at
    //                BONDROUTE_ADDRESS, so msg.sender for the transferFrom is BONDROUTE_ADDRESS — the user approves it.)
    function transfer_funding( address to, IERC20 token, uint256 amount, BondContext memory context )
    external returns ( uint256 updated_index, uint256 new_available_amount )
    {
        for(  uint256 i = 0  ;  i < context.fundings.length  ;  i = i + 1  )
        {
            if(  context.fundings[ i ].token == token  )
            {
                if(  token == NATIVE_TOKEN  )
                {
                    ( bool success, )  =  to.call{ value: amount }( "" );
                    require( success, "native funding transfer failed" );
                }
                else
                {
                    require( token.transferFrom( context.user, to, amount ), "funding transferFrom failed" );
                }

                return ( i, context.fundings[ i ].amount - amount );
            }
        }

        revert( "funding not found" );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/integrations/BondRouteProtected.sol";
import "@SafeSwap/libraries/SafeSwapCommon.sol";
import "@SafeSwap/libraries/ExactInputSwapLib.sol";
import "@SafeSwap/libraries/ExactOutputSwapLib.sol";
import "@SafeSwap/libraries/AddLiquidityLib.sol";
import "@SafeSwap/libraries/RemoveLiquidityLib.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { IUnlockCallback } from "@UniswapV4Core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@UniswapV4Core/types/BeforeSwapDelta.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { IOpenRegistry } from "@SafeSwap/integrations/IOpenRegistry.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error NotProtectedContext( );
error PoolManagerNotSet( );


/**
 * @title UniswapHook
 * @notice Uniswap V4 interface + BondRoute base - PoolManager, callbacks, protected context
 */
abstract contract UniswapHook is IUnlockCallback {
    using FundingsLib for BondContext;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable PoolManager;

    bool transient _is_protected_context;

    address constant OPEN_REGISTRY      =   address(bytes20(bytes12("OpenRegistry")));  // ***TODO*** Set after deployment.
    bytes32 constant UNISWAP_NAMESPACE  =   bytes32("uniswap");
    bytes32 constant POOL_MANAGER_KEY   =   bytes32("v4.pool_manager.address");

    enum Action { ExactInputSwap, ExactOutputSwap, AddLiquidity, RemoveLiquidity }

    constructor( )
    {
        address pool_manager  =  address(uint160(uint256(IOpenRegistry(OPEN_REGISTRY).read_key( UNISWAP_NAMESPACE, POOL_MANAGER_KEY ))));

        if(  pool_manager == address(0)  )  revert PoolManagerNotSet( );

        PoolManager  =  IPoolManager(pool_manager);
    }


    // ━━━━  PROTECTED CONTEXT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _set_protected_context( bool is_protected ) internal
    {
        _is_protected_context  =  is_protected;
    }

    function _is_within_protected_context( ) internal view returns ( bool )
    {
        return _is_protected_context;
    }


    // ━━━━  UNLOCK CALLBACK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function unlockCallback( bytes calldata data )
    external override returns ( bytes memory )
    {
        if(  msg.sender != address(PoolManager)  )  revert Unauthorized({ caller: msg.sender, expected: address(PoolManager) });

        Action action           =  Action( uint8( data[ data.length - 1 ] ) );
        bytes calldata payload  =  data[ :data.length - 1 ];

        if(  action == Action.ExactInputSwap  )
        {
            ( BondContext memory context, ExactInputSwapParams memory params )  =  abi.decode(  payload,  ( BondContext, ExactInputSwapParams )  );
            ExactInputSwapLib.execute( context, params, PoolManager, address(this) );
        }
        else if(  action == Action.ExactOutputSwap  )
        {
            ( BondContext memory context, ExactOutputSwapParams memory params )  =  abi.decode(  payload,  ( BondContext, ExactOutputSwapParams )  );
            ExactOutputSwapLib.execute( context, params, PoolManager, address(this) );
        }
        else if(  action == Action.AddLiquidity  )
        {
            ( BondContext memory context, AddLiquidityParams memory params )  =  abi.decode(  payload,  ( BondContext, AddLiquidityParams )  );
            AddLiquidityLib.execute( context, params, PoolManager, address(this) );
        }
        else if(  action == Action.RemoveLiquidity  )
        {
            ( BondContext memory context, RemoveLiquidityParams memory params )  =  abi.decode(  payload,  ( BondContext, RemoveLiquidityParams )  );
            RemoveLiquidityLib.execute( context, params, PoolManager, address(this) );
        }

        return "";
    }


    // ━━━━  HOOK CALLBACKS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function beforeSwap( address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata )
    external view returns ( bytes4, BeforeSwapDelta, uint24 )
    {
        if(  msg.sender != address(PoolManager)  )          revert Unauthorized({ caller: msg.sender, expected: address(PoolManager) });
        if(  _is_within_protected_context( ) == false  )    revert NotProtectedContext( );

        return ( IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0 );
    }

    function beforeAddLiquidity( address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata )
    external view returns ( bytes4 )
    {
        if(  msg.sender != address(PoolManager)  )          revert Unauthorized({ caller: msg.sender, expected: address(PoolManager) });
        if(  _is_within_protected_context( ) == false  )    revert NotProtectedContext( );

        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity( address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata )
    external view returns ( bytes4 )
    {
        if(  msg.sender != address(PoolManager)  )          revert Unauthorized({ caller: msg.sender, expected: address(PoolManager) });
        if(  _is_within_protected_context( ) == false  )    revert NotProtectedContext( );

        return IHooks.beforeRemoveLiquidity.selector;
    }
}

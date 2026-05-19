// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/integrations/BondRouteProtected.sol";
import "@SafeSwap/libraries/SafeSwapCommon.sol";
import "@SafeSwap/libraries/ExactInputSwapLib.sol";
import "@SafeSwap/libraries/ExactOutputSwapLib.sol";
import "@SafeSwap/libraries/AddLiquidityLib.sol";
import "@SafeSwap/libraries/RemoveLiquidityLib.sol";
import "@SafeSwap/libraries/DonateLib.sol";
import "@SafeSwap/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IProtocolFees } from "@UniswapV4Core/interfaces/IProtocolFees.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { Hooks } from "@UniswapV4Core/libraries/Hooks.sol";
import { IUnlockCallback } from "@UniswapV4Core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@UniswapV4Core/types/BeforeSwapDelta.sol";
import { ChainConfig } from "@SafeSwap/integrations/IChainConfig.sol";
import { IERC165 } from "@OpenZeppelin/utils/introspection/IERC165.sol";

interface IExtsloadSparse {
    /**
     * @notice Read arbitrary storage slots from a Uniswap V4 PoolManager-compatible contract.
     * @param slots Storage slots to read.
     * @return values Values loaded from the requested slots.
     */
    function extsload( bytes32[] calldata slots ) external view returns ( bytes32[] memory values );
}


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error BondRouteRequired( address caller, address bondroute );


// ━━━━  UNISWAP V4 CONFIG  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

bytes4 constant ERC6909_INTERFACE_ID  =  0x0f632fb3;


/**
 * @title UniswapHook
 * @notice Uniswap V4 PoolManager integration, hook callbacks, and SafeSwap protected callback context.
 */
abstract contract UniswapHook is IUnlockCallback {
    using FundingsLib for BondContext;

    IPoolManager internal immutable PoolManager;

    bool transient _is_hook_callback_allowed;

    enum Action { ExactInputSwap, ExactOutputSwap, AddLiquidity, RemoveLiquidity, Donate }

    /**
     * @notice Initialize PoolManager configuration and validate hook deployment flags.
     * @dev Reverts with string errors for human-facing deployment failures.
     */
    constructor( )
    {
        // *NOTE*  -  Only declared-true flags are set; the other 10 fields stay zero-initialized → false.
        Hooks.Permissions memory permissions;
        permissions.beforeAddLiquidity     =  true;
        permissions.beforeRemoveLiquidity  =  true;
        permissions.beforeSwap             =  true;
        permissions.beforeDonate           =  true;

        Hooks.validateHookPermissions( IHooks(address(this)), permissions );

        address pool_manager  =  ChainConfig.read_address( CONFIG_SIGNER, POOL_MANAGER_KEY );
        if(  _is_valid_pool_manager( pool_manager ) == false  )  revert( "SafeSwap: Invalid pool_manager" );

        PoolManager  =  IPoolManager(pool_manager);
    }

    /**
     * @dev Authoritative source of the PoolManager address is the ChainConfig signer; this shape check defends
     *      against trivial misconfiguration (EOA, empty bytecode, accidental address swap), not against a
     *      malicious signer publishing a look-alike contract.
     */
    function _is_valid_pool_manager( address pool_manager ) internal view returns ( bool )
    {
        if(  pool_manager.code.length == 0  )  return false;

        ( bool ok_controller, bytes memory controller_data )  =  pool_manager.staticcall( abi.encodeCall( IProtocolFees.protocolFeeController, () ) );
        if(  ok_controller == false || controller_data.length != 32  )  return false;

        bytes32[] memory slots  =  new bytes32[](0);
        ( bool ok_extsload, bytes memory extsload_data )  =  pool_manager.staticcall( abi.encodeCall( IExtsloadSparse.extsload, (slots) ) );
        // Empty dynamic array return ABI is 64 bytes: first word offset, second word length.
        if(  ok_extsload == false || extsload_data.length != 64  )  return false;

        bytes32[] memory loaded_slots  =  abi.decode( extsload_data, (bytes32[]) );
        if(  loaded_slots.length != 0  )  return false;

        ( bool ok_erc6909, bytes memory erc6909_data )  =  pool_manager.staticcall( abi.encodeCall( IERC165.supportsInterface, (ERC6909_INTERFACE_ID) ) );
        if(  ok_erc6909 == false || erc6909_data.length != 32 || abi.decode( erc6909_data, (bool) ) == false  )  return false;

        return true;
    }

    // ━━━━  UNLOCK CALLBACK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Dispatch a PoolManager unlock callback to the SafeSwap action encoded in `data`.
     * @param data First byte identifies the SafeSwap action; remaining bytes are ABI-encoded `(BondContext, action params)`.
     * @return Empty bytes after successful action execution.
     *
     * @dev SECURITY MODEL:
     *      - Only the configured PoolManager may call this function.
     *      - The hook callback allowance is enabled only while deferring into the PoolManager action.
     *      - The allowance is defensively revoked after dispatch even though the real hook callback should already consume it.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not PoolManager.
     */
    function unlockCallback( bytes calldata data )
    external  override  returns ( bytes memory )
    {
        if(  msg.sender != address(PoolManager)  )  revert Unauthorized({ caller: msg.sender, expected: address(PoolManager) });

        Action action           =  Action(uint8(data[ 0 ]));
        bytes calldata payload  =  data[ 1: ];

        _is_hook_callback_allowed  =  true;

        if(  action == Action.ExactInputSwap  )
        {
            ( BondContext memory context, ExactInputSwapParams memory params )  =  abi.decode( payload, (BondContext, ExactInputSwapParams) );
            ExactInputSwapLib.execute( context, params, PoolManager, address(this) );
        }
        else if(  action == Action.ExactOutputSwap  )
        {
            ( BondContext memory context, ExactOutputSwapParams memory params )  =  abi.decode( payload, (BondContext, ExactOutputSwapParams) );
            ExactOutputSwapLib.execute( context, params, PoolManager, address(this) );
        }
        else if(  action == Action.AddLiquidity  )
        {
            ( BondContext memory context, AddLiquidityParams memory params )  =  abi.decode( payload, (BondContext, AddLiquidityParams) );
            AddLiquidityLib.execute( context, params, PoolManager, address(this) );
        }
        else if(  action == Action.RemoveLiquidity  )
        {
            ( BondContext memory context, RemoveLiquidityParams memory params )  =  abi.decode( payload, (BondContext, RemoveLiquidityParams) );
            RemoveLiquidityLib.execute( context, params, PoolManager, address(this) );
        }
        else if(  action == Action.Donate  )
        {
            ( BondContext memory context, DonateParams memory params )  =  abi.decode( payload, (BondContext, DonateParams) );
            DonateLib.execute( context, params, PoolManager, address(this) );
        }

        _is_hook_callback_allowed  =  false;  // *SECURITY*  -  Likely already cleared at actual hook callback, yet cheap defensive good practice.

        return "";
    }


    // ━━━━  HOOK CALLBACKS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _consume_hook_callback_allowance( ) private
    {
        if(  msg.sender != address(PoolManager)  )  revert Unauthorized({ caller: msg.sender, expected: address(PoolManager) });
        if(  _is_hook_callback_allowed == false  )  revert BondRouteRequired({ caller: msg.sender, bondroute: address(BondRoute) });

        _is_hook_callback_allowed  =  false;  // *SECURITY*  -  Defense against a malicious token re-entering the uniswap's pool_manager directly.
    }

    modifier consumeHookAllowance( )
    {
        _consume_hook_callback_allowance( );
        _;
    }

    /**
     * @notice Authorize a BondRoute-protected Uniswap V4 swap callback.
     * @return Hook selector, zero before-swap delta, and zero LP fee override.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not PoolManager.
     *      - `BondRouteRequired(address caller, address bondroute)` if no SafeSwap action allowed this callback.
     */
    function beforeSwap( address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata )
    external  consumeHookAllowance  returns ( bytes4, BeforeSwapDelta, uint24 )
    {
        return ( IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0 );
    }

    /**
     * @notice Authorize a BondRoute-protected Uniswap V4 add-liquidity callback.
     * @return Hook selector.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not PoolManager.
     *      - `BondRouteRequired(address caller, address bondroute)` if no SafeSwap action allowed this callback.
     */
    function beforeAddLiquidity( address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata )
    external  consumeHookAllowance  returns ( bytes4 )
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    /**
     * @notice Authorize a BondRoute-protected Uniswap V4 remove-liquidity callback.
     * @return Hook selector.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not PoolManager.
     *      - `BondRouteRequired(address caller, address bondroute)` if no SafeSwap action allowed this callback.
     */
    function beforeRemoveLiquidity( address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata )
    external  consumeHookAllowance  returns ( bytes4 )
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Authorize a BondRoute-protected Uniswap V4 donation callback.
     * @return Hook selector.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not PoolManager.
     *      - `BondRouteRequired(address caller, address bondroute)` if no SafeSwap action allowed this callback.
     */
    function beforeDonate( address, PoolKey calldata, uint256, uint256, bytes calldata )
    external  consumeHookAllowance  returns ( bytes4 )
    {
        return IHooks.beforeDonate.selector;
    }
}

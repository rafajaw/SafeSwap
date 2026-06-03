// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapRouter/libraries/SafeSwapCommon.sol";
import "@SafeSwapRouter/libraries/ExactInputSwapLib.sol";
import "@SafeSwapRouter/libraries/ExactOutputSwapLib.sol";
import "@SafeSwapRouter/libraries/ModifyLiquidityLib.sol";
import "@SafeSwapRouter/libraries/DonateLib.sol";
import "@SafeSwapRouter/Definitions.sol";
import "@SafeSwapNft/ISafeSwapNft.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IProtocolFees } from "@UniswapV4Core/interfaces/IProtocolFees.sol";
import { IUnlockCallback } from "@UniswapV4Core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { IERC165 } from "@OpenZeppelin/utils/introspection/IERC165.sol";


interface IExtsloadSparse {
    /**
     * @notice Read arbitrary storage slots from a Uniswap V4 PoolManager-compatible contract.
     * @param slots Storage slots to read.
     * @return values Values loaded from the requested slots.
     */
    function extsload( bytes32[] calldata slots ) external view returns ( bytes32[] memory values );
}


// ━━━━  UNISWAP V4 CONFIG  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

bytes4 constant ERC6909_INTERFACE_ID  =  0x0f632fb3;


/**
 * @title Orchestrator
 * @notice Router-side Uniswap V4 PoolManager integration: pool initialization and the unlock-callback dispatch into the
 *         SafeSwap action libraries. The Uniswap V4 hook callbacks live on the standalone SafeSwapHook config instances.
 *
 * @dev The router is the only contract that calls `PoolManager.unlock`, so `unlockCallback` is only ever reached with
 *      router-constructed action data: the PoolManager calls back exactly the contract that opened the lock.
 */
abstract contract Orchestrator is IUnlockCallback {

    IPoolManager internal immutable PoolManager;

    enum Action { ExactInputSwap, ExactOutputSwap, Donate, ModifyLiquidity }

    /**
     * @notice Initialize PoolManager configuration from ChainConfig.
     * @dev Reverts with string errors for human-facing deployment failures.
     */
    constructor( )
    {
        address pool_manager  =  ChainConfig.read_address( CONFIG_SIGNER, POOL_MANAGER_KEY );
        if(  _is_valid_pool_manager( pool_manager ) == false  )  revert( "SafeSwap: Invalid pool_manager" );

        PoolManager  =  IPoolManager(pool_manager);
    }


    // ━━━━  UNLOCK CALLBACK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Dispatch a PoolManager unlock callback to the SafeSwap action encoded in `data`.
     * @param data First byte identifies the SafeSwap action; remaining bytes are the ABI-encoded action payload.
     * @return Empty bytes after successful action execution.
     *
     * @dev SECURITY MODEL:
     *      - Only the configured PoolManager may call this function.
     *      - The PoolManager only invokes `unlockCallback` on the address that called `unlock`, so this runs solely with
     *        action data built by the router's own BondRoute-protected functions.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not PoolManager.
     */
    function unlockCallback( bytes calldata data )
    external  override returns ( bytes memory )
    {
        if(  msg.sender != address(PoolManager)  )  revert Unauthorized({ caller: msg.sender, expected: address(PoolManager) });

        Action action           =  Action(uint8(data[ 0 ]));
        bytes calldata payload  =  data[ 1: ];

        if(  action == Action.ExactInputSwap  )
        {
            ( BondContext memory context, ExactInputSwapParams memory params, address hook )  =  abi.decode( payload, (BondContext, ExactInputSwapParams, address) );
            ExactInputSwapLib.execute( context, params, PoolManager, hook, address(this) );
        }
        else if(  action == Action.ExactOutputSwap  )
        {
            ( BondContext memory context, ExactOutputSwapParams memory params, address hook )  =  abi.decode( payload, (BondContext, ExactOutputSwapParams, address) );
            ExactOutputSwapLib.execute( context, params, PoolManager, hook, address(this) );
        }
        else if(  action == Action.Donate  )
        {
            ( BondContext memory context, DonateParams memory params, address hook )  =  abi.decode( payload, (BondContext, DonateParams, address) );
            DonateLib.execute( context, params, PoolManager, hook );
        }
        else if(  action == Action.ModifyLiquidity  )
        {
            ( BondContext memory context, ModifyLiquidityParams memory params, SafeSwapPositionInfo memory position_info )  =  abi.decode( payload, (BondContext, ModifyLiquidityParams, SafeSwapPositionInfo) );
            ModifyLiquidityLib.execute( context, params, PoolManager, position_info );
        }

        return "";
    }


    // ━━━━  POOL INITIALIZATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Initialize a SafeSwap pool at the user-signed price.
     * @dev The SafeSwap config hook's `beforeInitialize` rejects any initialization whose `sender` is not this router, so
     *      only the router can set a SafeSwap pool's first price, and it only does so at the BondRoute-signed price.
     */
    function _initialize_pool( PoolKey memory pool_key, uint160 sqrt_price_x96 ) internal
    {
        PoolManager.initialize( pool_key, sqrt_price_x96 );
    }


    // ━━━━  INTERNAL HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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
}

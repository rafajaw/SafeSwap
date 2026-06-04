// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapCommon/PoolManagerIntegration.sol";
import "@SafeSwapRouter/libraries/ExactInputSwapLib.sol";
import "@SafeSwapRouter/libraries/ExactOutputSwapLib.sol";
import { IUnlockCallback } from "@UniswapV4Core/interfaces/callback/IUnlockCallback.sol";


/**
 * @title Orchestrator
 * @notice SwapRouter-side Uniswap V4 integration: the unlock-callback dispatch into the swap action libraries.
 *
 * @dev The PoolManager only invokes `unlockCallback` on the address that opened the lock, so this runs solely with swap
 *      data built by the router's own BondRoute-protected swap functions.
 */
abstract contract Orchestrator is PoolManagerIntegration, IUnlockCallback {

    enum SwapAction { ExactInput, ExactOutput }

    /**
     * @notice Dispatch a PoolManager unlock callback to the swap encoded in `data`.
     * @param data First byte identifies the swap mode; remaining bytes are ABI-encoded `(BondContext, params, hook)`.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if caller is not PoolManager.
     */
    function unlockCallback( bytes calldata data )
    external  override returns ( bytes memory )
    {
        if(  msg.sender != address(PoolManager)  )  revert Unauthorized({ caller: msg.sender, expected: address(PoolManager) });

        SwapAction action       =  SwapAction(uint8(data[ 0 ]));
        bytes calldata payload  =  data[ 1: ];

        if(  action == SwapAction.ExactInput  )
        {
            ( BondContext memory context, ExactInputSwapParams memory params, address hook )  =  abi.decode( payload, (BondContext, ExactInputSwapParams, address) );
            ExactInputSwapLib.execute( context, params, PoolManager, hook, address(this) );
        }
        else
        {
            ( BondContext memory context, ExactOutputSwapParams memory params, address hook )  =  abi.decode( payload, (BondContext, ExactOutputSwapParams, address) );
            ExactOutputSwapLib.execute( context, params, PoolManager, hook, address(this) );
        }

        return "";
    }
}

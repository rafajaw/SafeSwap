// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*

        ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
        ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
        ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
        ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
        ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
        ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
        ━━━━━━━  MEV-protected pools. Repricing revenue for LPs.  ━━━━━━━

*/

import "@SafeSwapRouter/BondRouteIntegration.sol";
import "@SafeSwapRouter/Treasury.sol";


/**
 * @title SafeSwapRouter
 * @notice Canonical, BondRoute-protected SwapRouter for SafeSwap: swaps, the swap quoter, the hook config registry, and the
 *         protocol treasury. LP positions live in the separate PositionManager NFT.
 * @dev SafeSwap pools are dynamic-fee Uniswap V4 pools whose hook is a permissionlessly-deployed clone (one per
 *      `(base fee, capture)` config). The router is the only address allowed to route swaps through those pools; the hook
 *      charges `base + repricing` as the LP fee on each swap, accruing path-fairly to the LPs the swap crosses.
 *
 * Inheritance Chain (base → derived):
 *   PoolManagerIntegration → Orchestrator, HookRegistry, BondRouteProtected → User → BondRouteIntegration → SafeSwapRouter
 *   Treasury → SafeSwapRouter
 *
 *   PoolManagerIntegration - resolves + shape-validates the PoolManager
 *   Orchestrator           - swap unlock-callback dispatch
 *   HookRegistry           - permissionless hook registration + config resolution (codehash + address-bit auth)
 *   BondRouteProtected     - commit-reveal bond mechanism
 *   User                   - swap functions + off-chain quote/getters
 *   BondRouteIntegration   - BondRoute selectors, quote, signing-info dispatch (swaps)
 *   Treasury               - protocol-fee withdrawal + treasury role transfer
 *   SafeSwapRouter         - final composition + receive()
 */
contract SafeSwapRouter is BondRouteIntegration, Treasury {

    /**
     * @notice Deploy the SafeSwap router and initialize PoolManager, BondRoute, and treasury configuration from ChainConfig.
     * @dev Reverts with string errors for human-facing deployment failures.
     */
    constructor( )
    BondRouteIntegration( )
    Treasury( ) { }

    /**
     * @notice Receive native token from PoolManager (protocol fees on native swaps) or BondRoute (native funding pulls).
     * @dev Reverts on any other sender — the router has no donation surface.
     */
    receive( )
    external  payable  override
    {
        if(  msg.sender != address(PoolManager)  &&  msg.sender != BONDROUTE_ADDRESS  )  revert( "Direct transfers not allowed" );
    }
}

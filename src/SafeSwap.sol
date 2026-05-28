// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*

        ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
        ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
        ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
        ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
        ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
        ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
        ━━━━━━━━━━━━  Trustless MEV-protected Uniswap pools  ━━━━━━━━━━━━━

*/

import "@SafeSwap/BondRouteIntegration.sol";
import "@SafeSwap/Collector.sol";


/**
 * @title SafeSwap
 * @notice MEV-protected Uniswap V4 hook powered by BondRoute.
 * @dev Pools using this hook require swaps, liquidity operations, and donations to execute through BondRoute protection.
 *
 * Inheritance Chain (base → derived):
 *   BondRouteProtected, UniswapHook → User → BondRouteIntegration → SafeSwap
 *   Collector → SafeSwap
 *
 *   BondRouteProtected - commit-reveal bond mechanism
 *   UniswapHook        - PoolManager + V4 callbacks + protected context
 *   User               - user functions (swap, liquidity) + off-chain getters
 *   BondRouteIntegration - BondRoute selectors, quote, validation, signing-info dispatch
 *   Collector          - fee withdrawal + role transfer
 *   SafeSwap           - final composition + receive()
 */
contract SafeSwap is BondRouteIntegration, Collector {

    /**
     * @notice Deploy SafeSwap and initialize PoolManager, BondRoute, and collector configuration.
     * @dev Constructor reads deployment configuration from ChainConfig and reverts with string errors for human-facing deployment failures.
     */
    constructor( )
    BondRouteIntegration( )
    Collector( ) { }

    /**
     * @notice Receive native token from PoolManager (protocol fees on native swaps) or BondRoute (native funding pulls).
     * @dev Reverts on any other sender — SafeSwap has no donation surface.
     */
    receive( )
    external  payable
    {
        if(  msg.sender != address(PoolManager)  &&  msg.sender != BONDROUTE_ADDRESS  )  revert( "Direct transfers not allowed" );
    }
}

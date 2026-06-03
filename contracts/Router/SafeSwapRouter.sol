// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*

        ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
        ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
        ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
        ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
        ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
        ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
        ━━━━━━  MEV-protected Uniswap pools with LP repricing rebates  ━━━━━━

*/

import "@SafeSwapRouter/BondRouteIntegration.sol";
import "@SafeSwapRouter/Treasury.sol";


/**
 * @title SafeSwapRouter
 * @notice Canonical, BondRoute-protected user entrypoint for SafeSwap: swaps, NFT-backed liquidity, donations, the
 *         repricing-rebate engine, the hook config registry, and the protocol treasury.
 * @dev SafeSwap pools are static-fee Uniswap V4 pools whose hook is a permissionlessly-deployed SafeSwapHook config
 *      instance (one per LP repricing rebate profile). The router is the only contract that may route actions through
 *      those pools; every swap that moves the pool price pays LPs a rebate proportional to the real tick movement.
 *
 * Inheritance Chain (base → derived):
 *   Orchestrator, HookRegistry, BondRouteProtected → User → BondRouteIntegration → SafeSwapRouter
 *   Treasury → SafeSwapRouter
 *
 *   Orchestrator         - PoolManager integration: pool init + unlock-callback dispatch
 *   HookRegistry         - permissionless hook registration + config resolution (codehash + address-bit auth)
 *   BondRouteProtected   - commit-reveal bond mechanism
 *   User                 - user functions (swap, NFT-backed liquidity, donate) + off-chain getters
 *   BondRouteIntegration - BondRoute selectors, quote, validation, signing-info dispatch
 *   Treasury             - protocol-fee withdrawal + treasury role transfer
 *   SafeSwapRouter       - final composition + receive()
 */
contract SafeSwapRouter is BondRouteIntegration, Treasury {

    /**
     * @notice Deploy the SafeSwap router and initialize PoolManager, BondRoute, position NFT, and treasury configuration.
     * @dev Constructor reads deployment configuration from ChainConfig and reverts with string errors for human-facing deployment failures.
     */
    constructor( )
    BondRouteIntegration( )
    Treasury( ) { }

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

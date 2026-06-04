// SPDX-License-Identifier: MIT

/// @dev This file exists solely to compile Uniswap V4's `=0.8.26` contracts (PoolManager + the test routers) in their own
///      compilation unit, so the rest of the test suite (pinned `^0.8.30`, sharing a closure with ChainConfig's `=0.8.35`)
///      can deploy them via `deployCode("ForceCompileV4.sol:<Deployer>")` and reference them only through interfaces.
///      Importing the concrete contracts into the `^0.8.30` closure is impossible (no single solc satisfies `=0.8.26` and
///      `^0.8.30`).

pragma solidity =0.8.26;

import { PoolManager } from "@UniswapV4Core/PoolManager.sol";
import { PoolSwapTest } from "@UniswapV4Core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "@UniswapV4Core/test/PoolModifyLiquidityTest.sol";
import { PoolDonateTest } from "@UniswapV4Core/test/PoolDonateTest.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";

contract PoolManagerDeployer {
    function deploy( address controller ) external returns ( address )
    {
        return address( new PoolManager( controller ) );
    }
}

contract V4TestRouterDeployer {
    function deploy_swap_router( address manager ) external returns ( address )
    {
        return address( new PoolSwapTest( IPoolManager(manager) ) );
    }

    function deploy_modify_liquidity_router( address manager ) external returns ( address )
    {
        return address( new PoolModifyLiquidityTest( IPoolManager(manager) ) );
    }

    function deploy_donate_router( address manager ) external returns ( address )
    {
        return address( new PoolDonateTest( IPoolManager(manager) ) );
    }
}

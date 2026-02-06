// SPDX-License-Identifier: MIT

/// @dev  This file exists solely to deploy Uniswap V4's PoolManager.sol (which uses `pragma solidity =0.8.26`)
///       from a separate compilation unit.  RealPoolIntegration.t.sol deploys PoolManagerDeployer
///       via `deployCode`, then calls `deploy()` to get the real PoolManager.

pragma solidity =0.8.26;

import { PoolManager } from "@UniswapV4Core/PoolManager.sol";

contract PoolManagerDeployer {
    function deploy( address controller ) external returns ( address )
    {
        return address(new PoolManager( controller ));
    }
}

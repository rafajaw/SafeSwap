// SPDX-License-Identifier: MIT

/// @dev This file exists solely to compile Uniswap V4's PoolManager.sol (which pins `pragma solidity =0.8.26`) in its own
///      compilation unit, so the rest of the test suite (pinned `^0.8.30`, and sharing a closure with ChainConfig's
///      `=0.8.35`) can deploy a real PoolManager via `deployCode("ForceCompileV4.sol:PoolManagerDeployer")` and reference
///      it only through `IPoolManager`. Importing the concrete PoolManager into the `^0.8.30` closure is impossible (no
///      single solc satisfies `=0.8.26` and `^0.8.30`).

pragma solidity =0.8.26;

import { PoolManager } from "@UniswapV4Core/PoolManager.sol";

contract PoolManagerDeployer {
    function deploy( address controller ) external returns ( address )
    {
        return address( new PoolManager( controller ) );
    }
}

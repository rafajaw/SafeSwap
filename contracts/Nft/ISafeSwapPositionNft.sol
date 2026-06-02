// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/libraries/SafeSwapCommon.sol";
import { IERC721 } from "@OpenZeppelin/token/ERC721/IERC721.sol";
import { PoolId } from "@UniswapV4Core/types/PoolId.sol";
import { IERC20 } from "@BondRouteProtected/BondRouteProtected.sol";


// ━━━━  DATA STRUCTURES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice Immutable metadata for a SafeSwap NFT-backed Uniswap V4 position.
 * @param pool_id Uniswap V4 pool id for the stored pool key.
 * @param token0 Pool currency0.
 * @param token1 Pool currency1.
 * @param pool_info Pool fee and tick spacing.
 * @param tick_lower Lower tick of the position.
 * @param tick_upper Upper tick of the position.
 */
struct SafeSwapPositionInfo {
    PoolId pool_id;
    IERC20 token0;
    IERC20 token1;
    PoolInfo pool_info;
    int24 tick_lower;
    int24 tick_upper;
}


interface ISafeSwapPositionNft is IERC721 {
    function mint_position( address owner, SafeSwapPositionInfo calldata position_info ) external returns ( uint256 token_id );
    function get_lp_position( uint256 token_id ) external view returns ( SafeSwapPositionInfo memory position_info );
}

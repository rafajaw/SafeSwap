// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC721 } from "@OpenZeppelin/token/ERC721/IERC721.sol";
import { IERC20 } from "@BondRouteProtected/BondRouteProtected.sol";


// ━━━━  DATA STRUCTURES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice Immutable metadata for a SafeSwap NFT-backed Uniswap V4 position.
 * @param hook SafeSwap config hook that identifies the pool's repricing rebate profile.
 * @param token0 Pool currency0.
 * @param token1 Pool currency1.
 * @param base_fee_bps Base LP fee in basis points (1 bps = 0.01%). Derivable from `hook`, stored for cheap rendering and verification.
 * @param rebate_profile LP repricing rebate profile. Derivable from `hook`, stored for cheap rendering and verification.
 * @param tick_spacing Pool tick spacing.
 * @param tick_lower Lower tick of the position.
 * @param tick_upper Upper tick of the position.
 */
struct SafeSwapPositionInfo {
    address hook;
    IERC20 token0;
    IERC20 token1;
    uint8 base_fee_bps;
    uint8 rebate_profile;
    int24 tick_spacing;
    int24 tick_lower;
    int24 tick_upper;
}


interface ISafeSwapNft is IERC721 {
    function mint_position( address owner, SafeSwapPositionInfo calldata position_info ) external returns ( uint256 token_id );
    function get_lp_position( uint256 token_id ) external view returns ( SafeSwapPositionInfo memory position_info );
}

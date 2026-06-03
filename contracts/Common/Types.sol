// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@BondRouteProtected/BondRouteProtected.sol";


// ━━━━  DATA STRUCTURES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice SafeSwap pool configuration shared by all SafeSwap actions.
 * @param base_fee_bps Base LP fee in basis points (1 bps = 0.01%), 0..999. Selects the config hook (encoded in its address).
 * @param rebate_percent LP capture share in percent (0..90, in 10% steps). Selects the config hook and the repricing fee share.
 * @param tick_spacing Pool tick spacing.
 */
struct PoolInfo {
    uint16 base_fee_bps;
    uint8 rebate_percent;
    int24 tick_spacing;
}

/**
 * @notice Immutable metadata for a SafeSwap NFT-backed Uniswap V4 position.
 * @param hook SafeSwap config hook (clone) that identifies the pool's base fee and capture share.
 * @param token0 Pool currency0.
 * @param token1 Pool currency1.
 * @param base_fee_bps Base LP fee in basis points. Derivable from `hook`, stored for cheap rendering and verification.
 * @param rebate_percent LP capture share in percent. Derivable from `hook`, stored for cheap rendering and verification.
 * @param tick_spacing Pool tick spacing.
 * @param tick_lower Lower tick of the position.
 * @param tick_upper Upper tick of the position.
 */
struct SafeSwapPositionInfo {
    address hook;
    IERC20 token0;
    IERC20 token1;
    uint16 base_fee_bps;
    uint8 rebate_percent;
    int24 tick_spacing;
    int24 tick_lower;
    int24 tick_upper;
}

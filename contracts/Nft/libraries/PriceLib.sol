// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { FullMath } from "@UniswapV4Core/libraries/FullMath.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";


/**
 * @title PriceLib
 * @notice Human-readable price math for the SafeSwap LP NFT card. Converts a Uniswap V4 `sqrtPriceX96` (and the
 *         position's tick bounds) into a token1-per-token0 price, decimal-adjusted for both tokens and scaled to
 *         18 fixed-point decimals so `StringHelperLib.format_price` can render it.
 *
 *         price(token1 per token0) = (sqrtPriceX96 / 2^96)^2 * 10^decimals0 / 10^decimals1
 *
 *         Returned value is that price multiplied by 1e18.
 */
library PriceLib {

    uint256 internal constant PRICE_SCALE   =  1e18;                          // output fixed-point scale
    uint256 internal constant Q96           =  0x1000000000000000000000000;   // 2**96
    uint8   internal constant MAX_DECIMALS  =  36;                            // clamp to keep the mulDiv result in range

    /**
     * @notice Price of one whole token0 expressed in token1, scaled by 1e18 and adjusted for token decimals.
     * @dev Two-step FullMath keeps the 512-bit intermediate in range: `ratio = sqrtP^2 / 2^96`, then
     *      `price*1e18 = ratio * 10^(decimals0+18) / (2^96 * 10^decimals1)`.
     */
    function price1_per_0_scaled( uint160 sqrt_price_x96, uint8 decimals0, uint8 decimals1 )
    internal pure returns ( uint256 )
    {
        if(  sqrt_price_x96 == 0  )  return 0;

        uint256 d0  =  decimals0 > MAX_DECIMALS  ?  MAX_DECIMALS  :  decimals0;
        uint256 d1  =  decimals1 > MAX_DECIMALS  ?  MAX_DECIMALS  :  decimals1;

        uint256 ratio        =  FullMath.mulDiv( sqrt_price_x96, sqrt_price_x96, Q96 );   // sqrtP^2 / 2^96
        uint256 numerator    =  10 ** ( d0 + 18 );
        uint256 denominator  =  Q96 * ( 10 ** d1 );

        return FullMath.mulDiv( ratio, numerator, denominator );
    }

    /**
     * @notice token1-per-token0 price (scaled by 1e18) at a tick boundary — used for the range bar's low/high ends.
     */
    function price_at_tick_scaled( int24 tick, uint8 decimals0, uint8 decimals1 )
    internal pure returns ( uint256 )
    {
        return price1_per_0_scaled( TickMath.getSqrtPriceAtTick( tick ), decimals0, decimals1 );
    }

    /**
     * @notice Where the current price sits within [low, high], as a 0..width fill for the range-bar marker.
     *         Clamps to the ends when the price is out of range (price below low → 0, above high → width).
     * @dev Linear in PRICE, not tick — the card shows a price axis, so the marker spacing should track price
     *      (callers pass the scaled prices, not ticks). A tick-linear scale would misplace the thumb vs the labels.
     */
    function fill_width( uint256 current, uint256 low, uint256 high, uint256 width )
    internal pure returns ( uint256 )
    {
        if(  high <= low  ||  current <= low  )  return 0;
        if(  current >= high  )                  return width;

        return FullMath.mulDiv( current - low, width, high - low );
    }
}

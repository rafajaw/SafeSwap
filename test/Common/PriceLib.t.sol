// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { PriceLib } from "@SafeSwapCommon/PriceLib.sol";
import { StringHelperLib } from "@SafeSwapCommon/StringHelperLib.sol";


contract PriceLibTest is Test {

    uint160 internal constant Q96  =  0x1000000000000000000000000;   // 2**96  ->  raw price 1.0

    // ━━━━  sqrtPriceX96 -> scaled price  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_price_one_equal_decimals( ) external pure
    {
        assertEq( PriceLib.price1_per_0_scaled( Q96, 18, 18 ), 1e18, "raw 1:1 with equal decimals is price 1.0" );
    }

    function test_price_one_more_token1_decimals( ) external pure
    {
        // 1 wei token0 == 1 wei token1, token0 18dp / token1 6dp  ->  1 token0 buys 1e12 token1
        assertEq( PriceLib.price1_per_0_scaled( Q96, 18, 6 ), 1e12 * 1e18, "decimal gap scales the human price up" );
    }

    function test_price_one_more_token0_decimals( ) external pure
    {
        assertEq( PriceLib.price1_per_0_scaled( Q96, 6, 18 ), 1e6, "inverse decimal gap scales the human price down" );
    }

    function test_zero_sqrt_price_is_zero( ) external pure
    {
        assertEq( PriceLib.price1_per_0_scaled( 0, 18, 18 ), 0, "uninitialized sqrtPrice yields 0 (defensive guard)" );
    }

    function test_tick_zero_matches_q96( ) external pure
    {
        assertEq( PriceLib.price_at_tick_scaled( 0, 18, 18 ), 1e18, "tick 0 is sqrtPrice 2^96 is price 1.0" );
    }

    function test_price_is_monotonic_in_tick( ) external pure
    {
        uint256 low   =  PriceLib.price_at_tick_scaled( -120, 18, 18 );
        uint256 high  =  PriceLib.price_at_tick_scaled(  120, 18, 18 );

        assertLt( low, 1e18, "price below tick 0 is < 1.0" );
        assertGt( high, 1e18, "price above tick 0 is > 1.0" );
        assertLt( low, high, "price increases with tick" );
    }

    function test_eth_usdc_price_approx_3000( ) external pure
    {
        // ETH (token0, 18dp) / USDC (token1, 6dp); tick ~ ln(3e-9)/ln(1.0001) ~ -196256 -> ~3000 USDC per ETH.
        uint256 price  =  PriceLib.price_at_tick_scaled( -196256, 18, 6 );
        assertApproxEqRel( price, 3000e18, 0.01e18, "decimal-adjusted ETH/USDC price lands near 3000" );
    }

    // ━━━━  range-bar fill  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_fill_midpoint( ) external pure
    {
        assertEq( PriceLib.fill_width( 3000e18, 2850e18, 3150e18, 85 ), 42, "price ~mid-range fills ~half the bar" );
    }

    function test_fill_clamps_below_and_above( ) external pure
    {
        assertEq( PriceLib.fill_width( 2000e18, 2850e18, 3150e18, 85 ), 0,  "price below range pins fill to 0" );
        assertEq( PriceLib.fill_width( 4000e18, 2850e18, 3150e18, 85 ), 85, "price above range pins fill to width" );
    }

    function test_fill_degenerate_range( ) external pure
    {
        assertEq( PriceLib.fill_width( 100, 100, 100, 85 ), 0, "zero-width range cannot divide-by-zero" );
    }

    // ━━━━  price formatting  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_format_zero( ) external pure
    {
        assertEq( StringHelperLib.format_price( 0 ), "0" );
    }

    function test_format_thousands( ) external pure
    {
        assertEq( StringHelperLib.format_price( 3002e18 ), "3,002" );
        assertEq( StringHelperLib.format_price( 1234567e18 ), "1,234,567" );
        assertEq( StringHelperLib.format_price( 2850e18 ), "2,850" );
    }

    function test_format_units_two_decimals( ) external pure
    {
        assertEq( StringHelperLib.format_price( 1e18 ), "1" );
        assertEq( StringHelperLib.format_price( 15 * 1e17 ), "1.5" );
        assertEq( StringHelperLib.format_price( 142 * 1e16 ), "1.42" );
    }

    function test_format_sub_one_four_decimals( ) external pure
    {
        assertEq( StringHelperLib.format_price( 5 * 1e16 ), "0.05" );
        assertEq( StringHelperLib.format_price( 1e15 ), "0.001" );
        assertEq( StringHelperLib.format_price( 5 * 1e17 ), "0.5" );
    }

    function test_format_tiny_plain_decimal_no_exponent( ) external pure
    {
        assertEq( StringHelperLib.format_price( 13300000000000 ), "0.0000133" );    // 1.33e13 -> 0.0000133
        assertEq( StringHelperLib.format_price( 7120000000000 ), "0.00000712" );    // 7.12e12 -> 0.00000712
    }

    function test_format_token_amount_groups_thousands( ) external pure
    {
        assertEq( StringHelperLib.format_token_amount( 12450000 * 1e18, 18, StringHelperLib.FULL_PRECISION ), "12,450,000" );
        assertEq( StringHelperLib.format_token_amount( 8900000000 * 1e6, 6, StringHelperLib.FULL_PRECISION ), "8,900,000,000" );
    }
}

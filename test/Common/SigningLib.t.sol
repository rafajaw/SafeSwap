// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ISigningLibTests } from "@test/Common/TestManifest.sol";

import { SigningLib } from "@SafeSwapCommon/SigningLib.sol";
import { PoolInfo } from "@SafeSwapCommon/Types.sol";
import { StringHelperLib } from "@SafeSwapCommon/StringHelperLib.sol";
import { PriceLib } from "@SafeSwapCommon/PriceLib.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";


/**
 * @title SigningLibTest
 * @notice Pins the locked SIGNING_UX_REFERENCE_2 symbolic notation produced by `SigningLib`: every token amount carries an
 *         operator (`=` / `<=` / `>=`), pairs render token1-first with a `+` separator, the pool line uses `|` separators,
 *         prices are token0-per-token1, and the EIP-712 type string assembles around the `)TokenAmount(...)` anchor.
 */
contract SigningLibTest is ISigningLibTests, Test {

    uint160 internal constant _SQRT_PRICE_1_1  =  79228162514264337593543950336;   // 2^96, the 1:1 pool sqrt price.


    // ━━━━  SYMBOLIC VALUE NOTATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_render_pool_value_matches_reference_layout( )
    external
    {
        string memory pool  =  SigningLib.render_pool_value( PoolInfo({ base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 }) );

        assertEq( pool, "0.3% base fee | 50% rebate | tick spacing 60", "pool line must match the locked `|`-separated layout." );
    }

    function test_warning_value_is_the_locked_ascii_prose( )
    external
    {
        assertEq( SigningLib.WARNING_VALUE, ">>  Check protocol and token addresses  <<", "warning must be the locked ASCII prose." );
    }

    function test_render_single_amount_value_carries_the_exact_operator( )
    external
    {
        // 1.25 WETH (18 decimals).
        assertEq( SigningLib.render_single_amount_value( SigningLib.OPERATOR_EXACT, 1.25 ether, 18, "WETH" ), "= 1.25 WETH", "exact input must read `= 1.25 WETH`." );
    }

    function test_render_single_amount_value_carries_the_floor_operator( )
    external
    {
        // 4,218.5 USDC (6 decimals).
        assertEq( SigningLib.render_single_amount_value( SigningLib.OPERATOR_AT_LEAST, 4_218_500_000, 6, "USDC" ), ">= 4,218.5 USDC", "minimum output must read `>= 4,218.5 USDC`." );
    }

    function test_render_single_amount_value_carries_the_cap_operator( )
    external
    {
        // 1.2 WETH (18 decimals).
        assertEq( SigningLib.render_single_amount_value( SigningLib.OPERATOR_AT_MOST, 1.2 ether, 18, "WETH" ), "<= 1.2 WETH", "maximum input must read `<= 1.2 WETH`." );
    }

    function test_render_pair_amount_value_orders_token1_first_with_plus_separator( )
    external
    {
        // Deposit: <= 1.25 WETH + 4,200 USDC, with WETH = token1 (18 dec) shown first and USDC = token0 (6 dec) second.
        string memory deposit  =  SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_MOST, 1.25 ether, 18, "WETH", 4_200_000_000, 6, "USDC" );

        assertEq( deposit, "<= 1.25 WETH + 4,200 USDC", "pair must render token1 first, then ` + ` then token0." );
    }

    function test_render_position_value_renders_lp_hash( )
    external
    {
        assertEq( SigningLib.render_position_value( 9166523579416187058 ), "LP #9166523579416187058", "position must read `LP #<id>`." );
    }

    function test_render_burn_value_appends_liquidity_word( )
    external
    {
        assertEq( SigningLib.render_burn_value( 600000000000000000 ), "600000000000000000 liquidity", "burn must read `<liquidity> liquidity`." );
    }


    // ━━━━  PRICES (TOKEN0-PER-TOKEN1)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_format_price_full_keeps_fraction_above_one_thousand( )
    external
    {
        // The cosmetic card formatter drops the fraction at >= 1,000; the signed formatter keeps it (the locked sample).
        assertEq( StringHelperLib.format_price_full( 3002.5e18 ), "3,002.5", "signed price must keep the .5 above one thousand." );
        assertEq( StringHelperLib.format_price_full( 2850e18 ), "2,850", "whole-number price renders grouped, no fraction." );
        assertEq( StringHelperLib.format_price_full( 3150e18 ), "3,150", "whole-number price renders grouped, no fraction." );
    }

    function test_price0_per_1_is_the_inverse_orientation( )
    external
    {
        // price1_per_0 * price0_per_1 == 1 (scaled by 1e36), modulo rounding far below display precision.
        uint256 price1_per_0  =  PriceLib.price1_per_0_scaled( _SQRT_PRICE_1_1, 6, 18 );
        uint256 price0_per_1  =  PriceLib.price0_per_1_scaled( _SQRT_PRICE_1_1, 6, 18 );

        uint256 product  =  price1_per_0 * price0_per_1;
        assertApproxEqRel( product, 1e36, 1e12, "token0-per-token1 must be the inverse of token1-per-token0." );
    }

    function test_render_range_value_renders_low_to_high_token0_per_token1( )
    external
    {
        // Equal decimals, 1:1-ish pool: the two tick bounds straddle parity, rendered low-to-high with the token0/token1 suffix.
        string memory range  =  SigningLib.render_range_value( TickMath.getSqrtPriceAtTick( -120 ), TickMath.getSqrtPriceAtTick( 120 ), 18, 18, "USDC", "WETH" );

        assertTrue( _contains( range, " ~ " ), "range must join the two bounds with ` ~ `." );
        assertTrue( _ends_with( range, " USDC/WETH" ), "range must quote token0 per token1 (`USDC/WETH`)." );
    }

    function test_render_price_value_renders_token0_per_token1( )
    external
    {
        // 1:1 pool, equal decimals → price 1, quoted as token0/token1.
        assertEq( SigningLib.render_price_value( _SQRT_PRICE_1_1, 18, 18, "USDC", "WETH" ), "1 USDC/WETH", "init price must read `1 USDC/WETH` for a 1:1 equal-decimal pool." );
    }


    // ━━━━  TYPE STRING ASSEMBLY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_build_typed_string_starts_with_envelope_and_ends_with_token_amount( )
    external
    {
        string memory inner_definition  =  "ExactInputSwap(string Pay,string Receive,string Pool,string Warning,address USDC)";
        ( string memory typed_string, )  =  SigningLib.build_typed_string( "ExactInputSwap sS__SWAP__Ss", inner_definition );

        assertTrue(
            _starts_with( typed_string, "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactInputSwap sS__SWAP__Ss)" ),
            "typed string must start with the BondRoute envelope and the action field."
        );
        assertTrue( _ends_with( typed_string, "TokenAmount(address token,uint256 amount)" ), "typed string must end with the TokenAmount definition." );
    }

    function test_build_typed_string_offset_points_at_token_amount_definition( )
    external
    {
        string memory inner_definition  =  "RemoveLiquidity(string Position,string Burn,string Receive,string Pool,string Warning,address WETH,address USDC)";
        ( string memory typed_string, uint256 token_amount_offset )  =  SigningLib.build_typed_string( "RemoveLiquidity sS__REMOVE_LIQUIDITY__Ss", inner_definition );

        bytes memory raw  =  bytes(typed_string);
        assertEq( raw[ token_amount_offset - 1 ], bytes1(")"), "the byte before the offset must be the `)` BondRoute validates." );
        assertEq( _slice( raw, token_amount_offset, 12 ), "TokenAmount(", "the offset must point at the start of the TokenAmount definition." );
    }


    // ━━━━  STRING HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _starts_with( string memory value, string memory prefix ) internal pure returns ( bool )
    {
        bytes memory v  =  bytes(value);
        bytes memory p  =  bytes(prefix);
        if(  v.length < p.length  )  return false;

        for(  uint256 i = 0  ;  i < p.length  ;  i = i + 1  )
        {
            if(  v[ i ] != p[ i ]  )  return false;
        }
        return true;
    }

    function _ends_with( string memory value, string memory suffix ) internal pure returns ( bool )
    {
        bytes memory v  =  bytes(value);
        bytes memory s  =  bytes(suffix);
        if(  v.length < s.length  )  return false;

        uint256 offset  =  v.length - s.length;
        for(  uint256 i = 0  ;  i < s.length  ;  i = i + 1  )
        {
            if(  v[ offset + i ] != s[ i ]  )  return false;
        }
        return true;
    }

    function _contains( string memory value, string memory needle ) internal pure returns ( bool )
    {
        bytes memory v  =  bytes(value);
        bytes memory n  =  bytes(needle);
        if(  n.length == 0  ||  v.length < n.length  )  return false;

        for(  uint256 i = 0  ;  i <= v.length - n.length  ;  i = i + 1  )
        {
            bool matched  =  true;
            for(  uint256 j = 0  ;  j < n.length  ;  j = j + 1  )
            {
                if(  v[ i + j ] != n[ j ]  )  {  matched  =  false;  break;  }
            }
            if(  matched  )  return true;
        }
        return false;
    }

    function _slice( bytes memory data, uint256 offset, uint256 length ) internal pure returns ( string memory )
    {
        bytes memory out  =  new bytes( length );
        for(  uint256 i = 0  ;  i < length  ;  i = i + 1  )
        {
            out[ i ]  =  data[ offset + i ];
        }
        return string(out);
    }
}

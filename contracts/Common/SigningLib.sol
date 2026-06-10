// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapCommon/Types.sol";
import { StringHelperLib } from "@SafeSwapCommon/StringHelperLib.sol";
import { PriceLib } from "@SafeSwapCommon/PriceLib.sol";
import { EfficientHashLib } from "@Solady/utils/EfficientHashLib.sol";
import { LibString } from "@Solady/utils/LibString.sol";
import { SqrtPriceMath } from "@UniswapV4Core/libraries/SqrtPriceMath.sol";


/**
 * @title SigningLib
 * @notice Builds the SafeSwap BondRoute signing receipt in the locked `SIGNING_UX_REFERENCE_2.md` layout: terse symbolic
 *         display values (`= 1.25 WETH`, `<= 1.25 WETH + 4,200 USDC`, `2,850 ~ 3,150 USDC/WETH`, `|`-separated pool line),
 *         role-named single-word EIP-712 fields, each token symbol once per role, amounts at `FULL_PRECISION`, and the
 *         critical token addresses kept as raw typed anchors whose field name is the (sanitized) symbol.
 *
 * @dev Every display value is hashed as `keccak256(bytes(value))` inside the action struct, so the signed string is a
 *      canonical commitment. The token symbol is read defensively and sanitized (it lands inside the on-chain-generated
 *      EIP-712 type string, where an unsanitized `symbol()` could corrupt the type), reusing the NFT descriptor sanitizer.
 *      Token amounts are rendered at `StringHelperLib.FULL_PRECISION` — never the cosmetic card cap.
 */
library SigningLib {

    // ━━━━  ENVELOPE / FIXED TEXT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // BondRoute requires the typed string to start with this exact envelope and to contain the TokenAmount definition.
    string internal constant ENVELOPE_HEAD              =  "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,";
    string internal constant TOKEN_AMOUNT_DEFINITION    =  "TokenAmount(address token,uint256 amount)";
    uint256 internal constant ENVELOPE_HEAD_LENGTH      =  85;

    // The only prose field — a nudge, not the control. The real check is `protocol` + token addresses against ChainConfig.
    string internal constant WARNING_VALUE          =  ">>  Check protocol and token addresses  <<";
    bytes32 internal constant WARNING_VALUE_HASH    =  keccak256( bytes(WARNING_VALUE) );

    // Every token amount carries an operator: `=` exact, `<=` cap (max), `>=` floor (min). Trailing space joins the amount.
    string internal constant OPERATOR_EXACT     =  "= ";
    string internal constant OPERATOR_AT_MOST   =  "<= ";
    string internal constant OPERATOR_AT_LEAST  =  ">= ";


    // ━━━━  DISPLAY VALUES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // "= 1.25 WETH"
    function render_single_amount_value( string memory operator, uint256 amount, uint8 decimals, string memory symbol )
    internal pure returns ( string memory )
    {
        return string.concat( operator, StringHelperLib.format_symbol_amount( amount, decimals, StringHelperLib.FULL_PRECISION, symbol ) );
    }

    // "<= 1.25 WETH + 4,200 USDC" — token1 first, token0 second (the locked receipt orientation).
    function render_pair_amount_value(
        string memory operator,
        uint256 amount1, uint8 decimals1, string memory symbol1,
        uint256 amount0, uint8 decimals0, string memory symbol0
    ) internal pure returns ( string memory )
    {
        return string.concat(
            operator,
            StringHelperLib.format_symbol_amount( amount1, decimals1, StringHelperLib.FULL_PRECISION, symbol1 ),
            " + ",
            StringHelperLib.format_symbol_amount( amount0, decimals0, StringHelperLib.FULL_PRECISION, symbol0 )
        );
    }

    // "0.3% base fee | 50% rebate | tick spacing 60"
    function render_pool_value( PoolInfo memory pool_info ) internal pure returns ( string memory )
    {
        return string.concat(
            StringHelperLib.format_bps_as_percent( pool_info.base_fee_bps ), "% base fee | ",
            LibString.toString( uint256(pool_info.rebate_percent) ), "% rebate | tick spacing ",
            LibString.toString( int256(pool_info.tick_spacing) )
        );
    }

    // "LP #9166523579416187058"
    function render_position_value( uint256 token_id ) internal pure returns ( string memory )
    {
        return string.concat( "LP #", LibString.toString( token_id ) );
    }

    // "600000000000000000 liquidity"
    function render_burn_value( uint128 liquidity ) internal pure returns ( string memory )
    {
        return string.concat( LibString.toString( uint256(liquidity) ), " liquidity" );
    }

    // "2,850 ~ 3,150 USDC/WETH" — the two bound prices as token0-per-token1, rendered low-to-high.
    function render_range_value(
        uint160 sqrt_price_a_x96, uint160 sqrt_price_b_x96,
        uint8 decimals0, uint8 decimals1, string memory symbol0, string memory symbol1
    ) internal pure returns ( string memory )
    {
        uint256 price_a  =  PriceLib.price0_per_1_scaled( sqrt_price_a_x96, decimals0, decimals1 );
        uint256 price_b  =  PriceLib.price0_per_1_scaled( sqrt_price_b_x96, decimals0, decimals1 );

        ( uint256 low, uint256 high )  =  price_a <= price_b  ?  ( price_a, price_b )  :  ( price_b, price_a );

        return string.concat(
            StringHelperLib.format_price_full( low ), " ~ ", StringHelperLib.format_price_full( high ), " ", symbol0, "/", symbol1
        );
    }

    // "3,002.5 USDC/WETH" — the init price as token0-per-token1.
    function render_price_value(
        uint160 sqrt_price_x96, uint8 decimals0, uint8 decimals1, string memory symbol0, string memory symbol1
    ) internal pure returns ( string memory )
    {
        return string.concat(
            StringHelperLib.format_price_full( PriceLib.price0_per_1_scaled( sqrt_price_x96, decimals0, decimals1 ) ),
            " ", symbol0, "/", symbol1
        );
    }


    // ━━━━  LIQUIDITY → DEPOSIT AMOUNTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice The token0 / token1 amounts a position of `liquidity` over `[sqrt_price_a_x96, sqrt_price_b_x96]` requires at the
     *         given price. Used to render the `Deposit` line from the committed liquidity and range (no separate funding field
     *         is signed — the deposit is fully determined by liquidity + range + price). Pure V4 math (`SqrtPriceMath`).
     */
    function calculate_amounts_for_liquidity( uint160 sqrt_price_x96, uint160 sqrt_price_a_x96, uint160 sqrt_price_b_x96, uint128 liquidity )
    internal pure returns ( uint256 amount0, uint256 amount1 )
    {
        if(  sqrt_price_a_x96 > sqrt_price_b_x96  )  ( sqrt_price_a_x96, sqrt_price_b_x96 )  =  ( sqrt_price_b_x96, sqrt_price_a_x96 );

        if(  sqrt_price_x96 <= sqrt_price_a_x96  )
        {
            amount0  =  SqrtPriceMath.getAmount0Delta( sqrt_price_a_x96, sqrt_price_b_x96, liquidity, false );
        }
        else if(  sqrt_price_x96 < sqrt_price_b_x96  )
        {
            amount0  =  SqrtPriceMath.getAmount0Delta( sqrt_price_x96, sqrt_price_b_x96, liquidity, false );
            amount1  =  SqrtPriceMath.getAmount1Delta( sqrt_price_a_x96, sqrt_price_x96, liquidity, false );
        }
        else
        {
            amount1  =  SqrtPriceMath.getAmount1Delta( sqrt_price_a_x96, sqrt_price_b_x96, liquidity, false );
        }
    }


    // ━━━━  TYPE STRING ASSEMBLY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Assemble the full EIP-712 `typed_string` and the `token_amount_offset` BondRoute validates.
     * @param field_declaration The action field inside the envelope, e.g. `"ExactInputSwap sS__SWAP__Ss"`.
     * @param inner_definition The action struct definition, e.g. `"ExactInputSwap(string Pay,...,address USDC)"`.
     * @dev The closing `)` of the envelope field sits between `field_declaration` and `inner_definition`; `inner_definition`
     *      itself ends with `)`, so the byte right before `TokenAmount(` is the required `)` BondRoute checks at offset - 1.
     */
    function build_typed_string( string memory field_declaration, string memory inner_definition )
    internal pure returns ( string memory typed_string, uint256 token_amount_offset )
    {
        token_amount_offset  =  ENVELOPE_HEAD_LENGTH + bytes(field_declaration).length + 1 + bytes(inner_definition).length;
        typed_string         =  string.concat( ENVELOPE_HEAD, field_declaration, ")", inner_definition, TOKEN_AMOUNT_DEFINITION );
    }

    function hash_string( string memory value ) internal pure returns ( bytes32 value_hash )
    {
        return EfficientHashLib.hash( bytes(value) );
    }

    function encode_address_word( address value ) internal pure returns ( bytes32 )
    {
        return bytes32( uint256( uint160( value ) ) );
    }

    function hash_words( bytes32 v0, bytes32 v1, bytes32 v2, bytes32 v3, bytes32 v4, bytes32 v5 )
    internal pure returns ( bytes32 )
    {
        return EfficientHashLib.hash( v0, v1, v2, v3, v4, v5 );
    }

    function hash_words( bytes32 v0, bytes32 v1, bytes32 v2, bytes32 v3, bytes32 v4, bytes32 v5, bytes32 v6 )
    internal pure returns ( bytes32 )
    {
        return EfficientHashLib.hash( v0, v1, v2, v3, v4, v5, v6 );
    }

    function hash_words( bytes32 v0, bytes32 v1, bytes32 v2, bytes32 v3, bytes32 v4, bytes32 v5, bytes32 v6, bytes32 v7 )
    internal pure returns ( bytes32 )
    {
        return EfficientHashLib.hash( v0, v1, v2, v3, v4, v5, v6, v7 );
    }

    function hash_words( bytes32 v0, bytes32 v1, bytes32 v2, bytes32 v3, bytes32 v4, bytes32 v5, bytes32 v6, bytes32 v7, bytes32 v8 )
    internal pure returns ( bytes32 )
    {
        return EfficientHashLib.hash( v0, v1, v2, v3, v4, v5, v6, v7, v8 );
    }

    function hash_words( bytes32 v0, bytes32 v1, bytes32 v2, bytes32 v3, bytes32 v4, bytes32 v5, bytes32 v6, bytes32 v7, bytes32 v8, bytes32 v9 )
    internal pure returns ( bytes32 )
    {
        return EfficientHashLib.hash( v0, v1, v2, v3, v4, v5, v6, v7, v8, v9 );
    }
}

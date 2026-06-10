// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@BondRouteProtected/BondRouteProtected.sol";
import { IERC20Metadata } from "@OpenZeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import { DateTimeLib } from "@Solady/utils/DateTimeLib.sol";
import { LibString } from "@Solady/utils/LibString.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { CONFIG_SIGNER, NATIVE_TOKEN_SYMBOL_KEY, NATIVE_TOKEN_DECIMALS_KEY } from "@SafeSwapCommon/Definitions.sol";


/**
 * @title StringHelperLib
 * @notice String formatting and sanitization helpers for SafeSwap NFT metadata rendering.
 */
library StringHelperLib {

    uint256 internal constant MAX_SYMBOL_LENGTH  =  12;

    /// @notice Pass as `max_decimals_to_render` to render every fractional digit the token carries — a lossless,
    ///         canonical rendering in which distinct raw amounts always map to distinct strings. Use this
    ///         for signed display strings (canonical commitments); use a small cap only for cosmetic display.
    /// @dev    Resolves to `token_decimals` via the `>= token_decimals` clamp in `format_token_amount`.
    uint8 internal constant FULL_PRECISION  =  type(uint8).max;

    function attribute( string memory trait, string memory value ) internal pure returns ( string memory )
    {
        return string.concat( '{"trait_type":"', trait, '","value":"', value, '"}' );
    }

    function format_bps_as_percent( uint16 base_fee_bps ) internal pure returns ( string memory )
    {
        uint256 whole       =  uint256(base_fee_bps) / 100;
        uint256 fractional  =  uint256(base_fee_bps) % 100;

        if(  fractional == 0  )  return LibString.toString( whole );

        return string.concat( LibString.toString( whole ), ".", trimmed_fraction( fractional, 2 ) );
    }

    function format_bps_as_percent_string( uint256 value_bps ) internal pure returns ( string memory )
    {
        uint256 whole       =  value_bps / 100;
        uint256 fractional  =  value_bps % 100;

        if(  fractional == 0  )  return string.concat( LibString.toString( whole ), "%" );

        return string.concat( LibString.toString( whole ), ".", trimmed_fraction( fractional, 2 ), "%" );
    }

    function format_age( uint40 opened_at ) internal view returns ( string memory )
    {
        uint256 age_days  =  ( block.timestamp - opened_at ) / 1 days;
        return string.concat( LibString.toString( age_days ), "d" );
    }

    function format_symbol_amount( uint256 token_amount, uint8 decimals, uint8 max_decimals_to_render, string memory symbol ) internal pure returns ( string memory )
    {
        return string.concat( format_token_amount( token_amount, decimals, max_decimals_to_render ), " ", symbol );
    }

    /// @param max_decimals_to_render  Maximum fractional digits to render; 0 renders the integer part only. A
    ///                      small cap (e.g. 4) keeps cosmetic displays readable but is LOSSY — distinct amounts can
    ///                      collapse to the same string, so it must never anchor a signed commitment. Pass
    ///                      `FULL_PRECISION` for a lossless rendering.
    function format_token_amount( uint256 token_amount, uint8 decimals, uint8 max_decimals_to_render ) internal pure returns ( string memory )
    {
        if(  token_amount == 0  )  return "0";

        if(  decimals == 0  )  return LibString.toString( token_amount );

        // No real token reports 78+ decimals (10^78 overflows uint256). Invariant, not a real-usage failure, so
        // assert keeps it out of the ABI (see CODING_STYLE.md).
        assert(  decimals <= 77  );

        uint256 scale       =  pow10( decimals );
        uint256 whole       =  token_amount / scale;
        uint256 remainder   =  token_amount % scale;
        uint8 display       =  max_decimals_to_render >= decimals  ?  decimals  :  max_decimals_to_render;
        uint256 divisor     =  pow10( decimals - display );
        uint256 fractional  =  remainder / divisor;

        if(  fractional == 0  )
        {
            if(  whole == 0  &&  display == 0  )  return "<1";
            if(  whole == 0  )  return string.concat( "<0.", fractional_floor( display ) );
            return group_thousands( LibString.toString( whole ) );
        }

        return string.concat( group_thousands( LibString.toString( whole ) ), ".", format_fractional( fractional, display ) );
    }

    // Render a token1-per-token0 price scaled by 1e18 (see PriceLib) as a human decimal string:
    //   >= 1000        -> integer with thousands separators ("3,002")
    //   1 .. 1000      -> up to 2 decimals ("1.5")
    //   0.001 .. 1     -> up to 4 decimals ("0.05")
    //   < 0.001        -> ~3 significant figures, plain decimal, no exponent ("0.0000133")
    function format_price( uint256 scaled ) internal pure returns ( string memory )
    {
        if(  scaled == 0  )  return "0";

        uint256 whole  =  scaled / 1e18;

        if(  whole >= 1000  )  return group_thousands( LibString.toString( whole ) );

        if(  whole >= 1  )
        {
            uint256 frac_digits  =  ( scaled % 1e18 ) / 1e16;    // first 2 decimals
            if(  frac_digits == 0  )  return LibString.toString( whole );
            return string.concat( LibString.toString( whole ), ".", trimmed_fraction( frac_digits, 2 ) );
        }

        if(  scaled >= 1e15 )    // >= 0.001
        {
            uint256 frac_digits  =  scaled / 1e14;               // first 4 decimals
            return string.concat( "0.", trimmed_fraction( frac_digits, 4 ) );
        }

        // sub-0.001: count leading zeros, then keep ~3 significant figures.
        uint256 lead  =  0;
        uint256 v     =  scaled;
        while(  v < 1e17  )  {  v = v * 10;  lead = lead + 1;  }

        uint256 places  =  lead + 3;
        if(  places > 18  )  places = 18;

        uint256 sig  =  scaled / ( 10 ** ( 18 - places ) );
        if(  sig == 0  )  return "0";

        return string.concat( "0.", trimmed_fraction( sig, places ) );
    }

    // Render a token1-per-token0 (or token0-per-token1) price scaled by 1e18 for the SIGNED Create receipt. Unlike the
    // cosmetic `format_price` (which drops the fraction entirely once the whole part reaches 1,000 to keep the card tidy),
    // this keeps up to 4 trailing-zero-trimmed fractional digits at every magnitude, so "3,002.5 USDC/WETH" survives.
    // Sub-1 prices reuse `format_price`'s significant-figure tiers (already lossless enough at that magnitude).
    function format_price_full( uint256 scaled ) internal pure returns ( string memory )
    {
        if(  scaled == 0  )  return "0";

        uint256 whole  =  scaled / 1e18;
        if(  whole == 0  )  return format_price( scaled );

        uint256 frac_digits  =  ( scaled % 1e18 ) / 1e14;    // first 4 decimals
        if(  frac_digits == 0  )  return group_thousands( LibString.toString( whole ) );

        return string.concat( group_thousands( LibString.toString( whole ) ), ".", trimmed_fraction( frac_digits, 4 ) );
    }

    // Zero-pad `value` to `width` digits, then drop trailing zeros (e.g. value=500,width=4 -> "05").
    function trimmed_fraction( uint256 value, uint256 width ) internal pure returns ( string memory )
    {
        bytes memory buffer  =  new bytes( width );

        for(  uint256 i = width  ;  i > 0  ;  i = i - 1  )
        {
            buffer[ i - 1 ]  =  bytes1( uint8( 48 + ( value % 10 ) ) );
            value            =  value / 10;
        }

        uint256 length  =  width;
        while(  length > 0  &&  buffer[ length - 1 ] == 0x30  )
        {
            length  =  length - 1;
        }

        assembly { mstore( buffer, length ) }

        return string(buffer);
    }

    // Render a Unix timestamp (seconds, UTC) as "YYYY-MM-DD HH:MM UTC". Used as the snapshot "as of" stamp so a
    // marketplace-cached card visibly carries the time its live data was rendered.
    function format_utc_datetime( uint256 timestamp ) internal pure returns ( string memory )
    {
        ( uint256 year, uint256 month, uint256 day, uint256 hour, uint256 minute, )  =  DateTimeLib.timestampToDateTime( timestamp );

        return string.concat(
            LibString.toString( year ), "-", two_digits( month ), "-", two_digits( day ),
            " ", two_digits( hour ), ":", two_digits( minute ), " UTC"
        );
    }

    function two_digits( uint256 value ) internal pure returns ( string memory )
    {
        return value < 10  ?  string.concat( "0", LibString.toString( value ) )  :  LibString.toString( value );
    }

    // Insert thousands separators into a non-negative integer string: "1234567" -> "1,234,567".
    function group_thousands( string memory input ) internal pure returns ( string memory )
    {
        bytes memory raw  =  bytes(input);
        uint256 len       =  raw.length;
        if(  len <= 3  )  return input;

        uint256 commas    =  ( len - 1 ) / 3;
        bytes memory out  =  new bytes( len + commas );
        uint256 oi        =  out.length;
        uint256 count     =  0;

        for(  uint256 i = len  ;  i > 0  ;  i = i - 1  )
        {
            oi          =  oi - 1;
            out[ oi ]   =  raw[ i - 1 ];
            count       =  count + 1;

            if(  count % 3 == 0  &&  i > 1  )
            {
                oi         =  oi - 1;
                out[ oi ]  =  ",";
            }
        }

        return string(out);
    }

    function format_fractional( uint256 fractional, uint8 width ) internal pure returns ( string memory )
    {
        bytes memory buffer  =  new bytes( width );

        for(  uint256 i = width  ;  i > 0  ;  i = i - 1  )
        {
            buffer[ i - 1 ]  =  bytes1( uint8( 48 + ( fractional % 10 ) ) );
            fractional       =  fractional / 10;
        }

        uint256 length  =  width;
        while(  length > 0  &&  buffer[ length - 1 ] == 0x30  )
        {
            length  =  length - 1;
        }

        assembly { mstore( buffer, length ) }

        return string(buffer);
    }

    function fractional_floor( uint8 width ) internal pure returns ( string memory )
    {
        bytes memory buffer  =  new bytes( width );

        for(  uint256 i = 0  ;  i < width - 1  ;  i = i + 1  )
        {
            buffer[ i ]  =  0x30;
        }

        buffer[ width - 1 ]  =  0x31;

        return string(buffer);
    }

    function pow10( uint8 exponent ) internal pure returns ( uint256 value )
    {
        value  =  1;

        for(  uint256 i = 0  ;  i < exponent  ;  i = i + 1  )
        {
            value  =  value * 10;
        }
    }

    // Safe display symbol for embedding in JSON, SVG, and the signed receipt: the native token (`address(0)`) renders the
    // chain-configured native symbol; a non-conforming `symbol()` (missing, reverting, or non-string) falls back to the short
    // address; the result is filtered to an alphanumeric subset so it can never break out of the surrounding XML/JSON/type string.
    function get_sanitized_token_symbol( IERC20 token ) internal view returns ( string memory )
    {
        if(  address(token) == address(0)  )  return get_native_token_symbol( );

        try IERC20Metadata( address(token) ).symbol( ) returns ( string memory symbol )
        {
            return sanitize( symbol );
        }
        catch
        {
            return sanitize( LibString.toHexString( address(token) ) );
        }
    }

    // The native token (`address(0)`) renders the chain-configured native decimals; a token whose `decimals()` is missing or
    // reverts falls back to the universal 18-decimal ERC20 default.
    function get_token_decimals( IERC20 token ) internal view returns ( uint8 )
    {
        if(  address(token) == address(0)  )  return get_native_token_decimals( );

        try IERC20Metadata( address(token) ).decimals( ) returns ( uint8 decimals )
        {
            return decimals;
        }
        catch
        {
            return 18;
        }
    }

    // The native token (`address(0)`) display name and decimals are chain-scoped, read live from ChainConfig so a chain rename
    // (e.g. ETH -> ETC) is reflected by republishing the key with no redeploy. These are the source of truth the signing
    // receipt and the NFT card both render; an unset key reverts `KeyNotSet`, and the size-bound descriptors touch-read both
    // in their constructors so a misconfigured deploy fails fast rather than at first render. Sanitized like any other symbol.
    function get_native_token_symbol( ) internal view returns ( string memory )
    {
        return sanitize( LibString.fromSmallString( ChainConfig.read_bytes32( CONFIG_SIGNER, NATIVE_TOKEN_SYMBOL_KEY ) ) );
    }

    function get_native_token_decimals( ) internal view returns ( uint8 )
    {
        return uint8( ChainConfig.read_uint( CONFIG_SIGNER, NATIVE_TOKEN_DECIMALS_KEY ) );
    }

    // Deploy-time guard for the size-bound descriptors: require the native-token display keys before first render so a
    // misconfigured deploy fails fast rather than at the first signing receipt or card. An unset key reverts `KeyNotSet`.
    function validate_native_token_config( ) internal view
    {
        if(  bytes( get_native_token_symbol() ).length == 0  )  revert( "SafeSwap: native_token_symbol not set" );
        if(  get_native_token_decimals() == 0  )                revert( "SafeSwap: native_token_decimals not set" );
    }

    // Keep only [0-9A-Za-z], '.', '-' and cap the length. Drops quotes, angle brackets, backslashes, and control bytes, so a
    // hostile token symbol cannot inject markup or JSON punctuation.
    function sanitize( string memory input ) internal pure returns ( string memory )
    {
        bytes memory raw    =  bytes(input);
        uint256 limit       =  raw.length < MAX_SYMBOL_LENGTH  ?  raw.length  :  MAX_SYMBOL_LENGTH;
        bytes memory clean  =  new bytes( limit );
        uint256 count       =  0;

        for(  uint256 i = 0  ;  i < limit  ;  i = i + 1  )
        {
            bytes1 c  =  raw[ i ];

            bool is_allowed  =  ( c >= 0x30 && c <= 0x39 )       // 0-9
                                ||  ( c >= 0x41 && c <= 0x5A )   // A-Z
                                ||  ( c >= 0x61 && c <= 0x7A )   // a-z
                                ||  c == 0x2E                    // .
                                ||  c == 0x2D;                   // -

            if(  is_allowed  )
            {
                clean[ count ]  =  c;
                count           =  count + 1;
            }
        }

        if(  count == 0  )  return "TOKEN";

        assembly { mstore( clean, count ) }    // Truncate to the kept bytes.

        return string(clean);
    }
}

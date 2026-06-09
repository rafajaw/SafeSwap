import { formatUnits, parseUnits, type Address } from "viem";

/** Format a raw token amount for display: thousands-separated, with a sensible fraction cap by magnitude. */
export function format_amount( raw: bigint, decimals: number, max_fraction: number = 6 ): string
{
    const value  =  Number( formatUnits( raw, decimals ) );
    return format_number( value, max_fraction );
}

export function format_number( value: number, max_fraction: number = 6 ): string
{
    if(  Number.isFinite( value ) === false  )  return "0";

    const abs  =  Math.abs( value );
    const fraction  =  abs >= 1000 ? 2 : abs >= 1 ? 4 : max_fraction;
    return value.toLocaleString( "en-US", { maximumFractionDigits: fraction } );
}

/** Parse a human decimal string into a raw token amount. Empty / invalid → 0n. */
export function parse_amount( display: string, decimals: number ): bigint
{
    const trimmed  =  display.trim();
    if(  trimmed === "" || Number.isNaN( Number( trimmed ) )  )  return 0n;

    try
    {
        return parseUnits( trimmed, decimals );
    }
    catch
    {
        return 0n;
    }
}

export function format_percent( fraction: number, max_fraction: number = 2 ): string
{
    return `${ ( fraction * 100 ).toLocaleString( "en-US", { maximumFractionDigits: max_fraction } ) }%`;
}

/** Uniswap V4 pips → percent string (1,000,000 pips = 100%). */
export function pips_to_percent( pips: number ): string
{
    return format_percent( pips / 1_000_000 );
}

/** Base fee bps → percent string (1 bps = 0.01%). */
export function bps_to_percent( bps: number ): string
{
    return format_percent( bps / 10_000 );
}

export function short_address( address: Address | string ): string
{
    return `${ address.slice( 0, 6 ) }…${ address.slice( -4 ) }`;
}

/** The compact secondary "capture" technical tag (e.g. C50). Demoted per the terminology decision; "Repricing rebate" leads. */
export function capture_tag( rebate_percent: number ): string
{
    return `C${ String( rebate_percent ).padStart( 2, "0" ) }`;
}

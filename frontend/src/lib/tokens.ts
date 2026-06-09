import { formatUnits, isAddress, parseAbi, type Address, type PublicClient } from "viem";

/** The native gas token sentinel (Uniswap V4 / BondRoute address-zero convention). */
export const NATIVE_ADDRESS  =  "0x0000000000000000000000000000000000000000" as const;

/** Volatility class drives the demo MEV-loss benchmark (handoff §4 — benchmark by pair type). */
export type TokenClass  =  "stable" | "bluechip" | "longtail";

export type TokenInfo = {
    address:  Address;
    symbol:   string;
    decimals: number;
    class:    TokenClass;
    native?:  boolean;
};

/**
 * Curated token list, crossed with discovered profiles to surface candidate pools (handoff §13: there is no on-chain pool
 * directory, so candidate pairs come from a curated list and each displayed field is then an on-chain fact). DEMO FIXTURE —
 * addresses must be set per network before these are real. Keyed by chain id. The app also accepts any pasted token address.
 */
export const CURATED_TOKENS: Record<number, TokenInfo[]>  =  {
    // Unichain (130) — the demo relayer chain. ***TODO*** fill real token addresses before launch.
    130: [
        { address: NATIVE_ADDRESS, symbol: "ETH", decimals: 18, class: "bluechip", native: true },
    ],
};

const ERC20_METADATA_ABI  =  parseAbi([
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
]);

const metadata_cache  =  new Map<string, Promise<TokenInfo>>();

export function is_native( token: Address ): boolean
{
    return token.toLowerCase() === NATIVE_ADDRESS.toLowerCase();
}

export function curated_tokens( chain_id: number | null ): TokenInfo[]
{
    if(  chain_id === null  )  return [];
    return CURATED_TOKENS[ chain_id ] ?? [ { address: NATIVE_ADDRESS, symbol: "ETH", decimals: 18, class: "bluechip", native: true } ];
}

/** Classify a pair for the MEV benchmark: both stable → stable; any blue-chip → bluechip; otherwise long-tail. */
export function pair_class( a: TokenClass, b: TokenClass ): TokenClass
{
    if(  a === "stable" && b === "stable"  )  return "stable";
    if(  a === "bluechip" || b === "bluechip"  )  return "bluechip";
    return "longtail";
}

/** Resolve token symbol/decimals — from the curated list when known, else read on-chain (cached). */
export async function get_token_metadata( public_client: PublicClient, chain_id: number | null, token: Address ): Promise<TokenInfo>
{
    const curated  =  curated_tokens( chain_id ).find(( item ) => item.address.toLowerCase() === token.toLowerCase() );
    if(  curated !== undefined  )  return curated;

    if(  is_native( token )  )
    {
        const native  =  public_client.chain?.nativeCurrency;
        return { address: token, symbol: native?.symbol ?? "ETH", decimals: native?.decimals ?? 18, class: "bluechip", native: true };
    }

    const key     =  `${ chain_id }:${ token.toLowerCase() }`;
    const cached  =  metadata_cache.get( key );
    if(  cached !== undefined  )  return await cached;

    const promise  =  ( async (): Promise<TokenInfo> => {
        const [ decimals, symbol ]  =  await Promise.all([
            public_client.readContract({ address: token, abi: ERC20_METADATA_ABI, functionName: "decimals" }),
            public_client.readContract({ address: token, abi: ERC20_METADATA_ABI, functionName: "symbol" }),
        ]);
        return { address: token, decimals: Number( decimals ), symbol: String( symbol ), class: "longtail" };
    })();
    metadata_cache.set( key, promise );
    return await promise;
}

export function require_address( label: string, value: string ): Address
{
    const address  =  value.trim();
    if(  isAddress( address ) === false  )  throw new Error( `${ label } must be a valid address.` );
    return address as Address;
}

export function format_token_amount( raw: bigint, info: TokenInfo ): string
{
    return `${ Number( formatUnits( raw, info.decimals ) ).toLocaleString( "en-US", { maximumFractionDigits: 6 } ) } ${ info.symbol }`;
}

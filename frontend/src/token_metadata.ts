import { formatUnits, isAddress, parseAbi, parseUnits, type Address, type PublicClient } from "viem";
import { NATIVE_TOKEN_METADATA, ZERO_ADDRESS } from "./constants";
import type { TokenMetadata } from "./types";

const ERC20_METADATA_ABI  =  parseAbi([
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
]);

const token_metadata_cache  =  new Map<string, Promise<TokenMetadata>>();

export function require_address( label: string, value: string ): Address
{
    const address  =  value.trim();
    if(  isAddress( address ) == false  )  throw new Error( `${ label } must be a valid address.` );
    return address as Address;
}

export async function get_token_metadata( public_client: PublicClient, token: Address ): Promise<TokenMetadata>
{
    if(  token.toLowerCase() === ZERO_ADDRESS.toLowerCase()  )
    {
        return { address: token, ...NATIVE_TOKEN_METADATA };
    }

    const key     =  token.toLowerCase();
    const cached  =  token_metadata_cache.get( key );
    if(  cached !== undefined  )  return await cached;

    const promise  =  fetch_token_metadata( public_client, token );
    token_metadata_cache.set( key, promise );
    return await promise;
}

export async function parse_token_amount( public_client: PublicClient, token: Address, display_amount: string ): Promise<bigint>
{
    const trimmed_amount  =  display_amount.trim();
    if(  trimmed_amount === ""  )  throw new Error( "Amount is required." );

    const metadata  =  await get_token_metadata( public_client, token );
    return parseUnits( trimmed_amount, metadata.decimals );
}

export async function render_token_amount( public_client: PublicClient, token: Address, amount: bigint ): Promise<string>
{
    const metadata  =  await get_token_metadata( public_client, token );
    return `${ formatUnits( amount, metadata.decimals ) } ${ metadata.symbol }`;
}

async function fetch_token_metadata( public_client: PublicClient, token: Address ): Promise<TokenMetadata>
{
    const [ decimals, symbol ]  =  await Promise.all([
        public_client.readContract({
            address:      token,
            abi:          ERC20_METADATA_ABI,
            functionName: "decimals",
        }),
        public_client.readContract({
            address:      token,
            abi:          ERC20_METADATA_ABI,
            functionName: "symbol",
        }),
    ]);

    return { address: token, decimals: Number( decimals ), symbol: String( symbol ) };
}

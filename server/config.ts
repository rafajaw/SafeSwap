// SPDX-License-Identifier: MIT
//
// SafeSwap relayer configuration — read once from the environment at boot. The relayer private key is the system's only
// secret and lives server-side by design (see FRONTEND_SPEC_DECISIONS.md "Data-fetching & app architecture").

import { getAddress, type Address, type Hex } from "viem";

const DEFAULT_PORT             =  8080;
const DEFAULT_STATIC_DIR       =  "../frontend/dist";
/** The relayer refuses to sponsor any operation whose estimated total gas exceeds this USD ceiling. */
export const MAX_RELAY_COST_USD  =  1;

// Mined SafeSwap / BondRoute addresses — identical on every chain, so hardcoded (not env) to remove a per-deploy error surface.
const SAFESWAP_ROUTER_ADDRESS            =  "0x5AFe000018090552d2C02d2884B0B567601332B2";
const SAFESWAP_NFT_ADDRESS               =  "0x7210000035EE7a4336516E1a0F2615C55ACFa043";
const SAFESWAP_RELAYER_DELEGATE_ADDRESS  =  "0x77020000a6eF5B111B27d836403EED4Aa3A39620";
const BONDROUTE_ADDRESS                  =  "0xb01d00000000440215e86e0A436f9b59FeB2F14a";

// Blocks/seconds to wait between commit and execute. SafeSwap's reveal floor is 3 blocks / 2 seconds; the defaults add a
// small margin so the post-delay execute never reverts as "not executable yet". Override per chain via the environment.
const DEFAULT_REVEAL_DELAY_BLOCKS   =  4;
const DEFAULT_REVEAL_DELAY_SECONDS  =  4;

/** How many settled bonds per address `/activity` returns under `recent`. */
const DEFAULT_RECENT_LIMIT  =  20;

function require_env( name: string ): string
{
    const value  =  Deno.env.get( name );
    if(  value === undefined || value.trim() === ""  )  throw new Error( `Missing required environment variable: ${ name }.` );
    return value.trim();
}

function optional_env( name: string ): string | undefined
{
    const value  =  Deno.env.get( name );
    return value === undefined || value.trim() === ""  ?  undefined  :  value.trim();
}

export type RelayerConfig = {
    port:                     number;
    static_dir:               string;
    rpc_url:                  string;
    chain_id:                 number;
    relayer_private_key:      Hex;
    router_address:           Address;
    nft_address:              Address;
    relayer_delegate_address: Address;
    bondroute_address:        Address | undefined;
    /** USD price of the chain's native gas token. When set, the relayer enforces the `MAX_RELAY_COST_USD` ceiling. */
    native_usd_price:         number | undefined;
    /** Reveal delay the relayer waits between the commit and execute transactions. */
    reveal_delay_blocks:      number;
    reveal_delay_seconds:     number;
    /** Postgres connection string for the activity store; when unset the relayer uses an in-process memory store. */
    database_url:             string | undefined;
    /** How many settled bonds per address `/activity` returns under `recent`. */
    recent_limit:             number;
};

export function load_config(): RelayerConfig
{
    const native_usd_price_raw  =  optional_env( "RELAYER_NATIVE_USD_PRICE" );

    return {
        port:                     Number( optional_env( "PORT" ) ?? DEFAULT_PORT ),
        static_dir:               optional_env( "STATIC_DIR" ) ?? DEFAULT_STATIC_DIR,
        rpc_url:                  require_env( "RELAYER_RPC_URL" ),
        chain_id:                 Number( require_env( "RELAYER_CHAIN_ID" ) ),
        relayer_private_key:      require_env( "RELAYER_PRIVATE_KEY" ) as Hex,
        router_address:           getAddress( SAFESWAP_ROUTER_ADDRESS ),
        nft_address:              getAddress( SAFESWAP_NFT_ADDRESS ),
        relayer_delegate_address: getAddress( SAFESWAP_RELAYER_DELEGATE_ADDRESS ),
        bondroute_address:        getAddress( BONDROUTE_ADDRESS ),
        native_usd_price:         native_usd_price_raw === undefined ? undefined : Number( native_usd_price_raw ),
        reveal_delay_blocks:      Number( optional_env( "RELAYER_REVEAL_DELAY_BLOCKS" )  ?? DEFAULT_REVEAL_DELAY_BLOCKS ),
        reveal_delay_seconds:     Number( optional_env( "RELAYER_REVEAL_DELAY_SECONDS" ) ?? DEFAULT_REVEAL_DELAY_SECONDS ),
        database_url:             optional_env( "DATABASE_URL" ),
        recent_limit:             Number( optional_env( "RELAYER_RECENT_LIMIT" ) ?? DEFAULT_RECENT_LIMIT ),
    };
}

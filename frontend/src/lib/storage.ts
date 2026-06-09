import type { Address, Hex } from "viem";

/** A completed-action receipt, persisted locally so Portfolio history survives refresh before an indexer exists (handoff §8/§17). */
export type Receipt = {
    id:          string;
    kind:        "swap" | "create_position" | "add_liquidity" | "remove_liquidity" | "collect_fees";
    title:       string;
    lines:       { label: string, value: string, green?: boolean }[];
    status:      "executed" | "protocol_reverted" | "invalid_bond" | "liquidated" | "submitted";
    tx_hash?:    Hex;
    created_at:  number;
};

const RECEIPTS_KEY  =  "safeswap.receipts.v1";
/** Locally-remembered minted token ids, so Portfolio shows freshly-created positions instantly without waiting on log indexing. */
const TOKEN_IDS_KEY =  "safeswap.token_ids.v1";

function user_key( base: string, user: Address ): string
{
    return `${ base }.${ user.toLowerCase() }`;
}

function read_json<T>( key: string, fallback: T ): T
{
    try
    {
        const raw  =  window.localStorage.getItem( key );
        return raw === null ? fallback : JSON.parse( raw ) as T;
    }
    catch
    {
        return fallback;
    }
}

export function load_receipts( user: Address | null ): Receipt[]
{
    if(  user === null  )  return [];
    return read_json<Receipt[]>( user_key( RECEIPTS_KEY, user ), [] );
}

export function save_receipt( user: Address, receipt: Receipt ): Receipt[]
{
    const next  =  [ receipt, ...load_receipts( user ).filter(( item ) => item.id !== receipt.id ) ].slice( 0, 50 );
    window.localStorage.setItem( user_key( RECEIPTS_KEY, user ), JSON.stringify( next ) );
    return next;
}

export function load_remembered_token_ids( user: Address | null ): string[]
{
    if(  user === null  )  return [];
    return read_json<string[]>( user_key( TOKEN_IDS_KEY, user ), [] );
}

export function remember_token_id( user: Address, token_id: bigint ): void
{
    const key      =  user_key( TOKEN_IDS_KEY, user );
    const existing  =  read_json<string[]>( key, [] );
    const next      =  [ ...new Set([ token_id.toString(), ...existing ]) ];
    window.localStorage.setItem( key, JSON.stringify( next ) );
}

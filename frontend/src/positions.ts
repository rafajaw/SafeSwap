import type { Address } from "viem";
import type { PositionRow, TrackedPosition } from "./types";

const STORAGE_KEY  =  "safeswap.tracked_positions.v1";

export function load_tracked_positions( user: Address | null ): TrackedPosition[]
{
    if(  user === null  )  return [];

    const raw  =  window.localStorage.getItem( storage_key_for_user( user ) );
    if(  raw === null  )  return [];

    try
    {
        return JSON.parse( raw ) as TrackedPosition[];
    }
    catch
    {
        return [];
    }
}

export function save_tracked_position( user: Address, position: Omit<TrackedPosition, "id" | "created_at"> ): TrackedPosition[]
{
    const positions  =  load_tracked_positions( user );
    const id         =  make_position_id( position );
    const existing   =  positions.filter(( item ) => item.id !== id );
    const next       =  [ { ...position, id, created_at: Date.now() }, ...existing ];

    window.localStorage.setItem( storage_key_for_user( user ), JSON.stringify( next ) );
    return next;
}

export function remove_tracked_position( user: Address, id: string ): TrackedPosition[]
{
    const next  =  load_tracked_positions( user ).filter(( item ) => item.id !== id );
    window.localStorage.setItem( storage_key_for_user( user ), JSON.stringify( next ) );
    return next;
}

export function empty_position_row( position: TrackedPosition ): PositionRow
{
    return { ...position, liquidity: null, error: null };
}

function storage_key_for_user( user: Address ): string
{
    return `${ STORAGE_KEY }.${ user.toLowerCase() }`;
}

function make_position_id( position: Omit<TrackedPosition, "id" | "created_at"> ): string
{
    return [
        position.token_a.toLowerCase(),
        position.token_b.toLowerCase(),
        String( position.fee ),
        String( position.tick_spacing ),
        String( position.tick_lower ),
        String( position.tick_upper ),
    ].join( ":" );
}

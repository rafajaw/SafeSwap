// SPDX-License-Identifier: MIT
//
// Crash-durable record of bonds the relayer has committed but not yet executed. Because the gasless flow stakes the USER's
// own tokens, a relayer crash between commit and execute would otherwise strand that stake until it expires and is
// liquidated. Persisting each committed bond (and resuming it on restart) keeps that window recoverable: the relayer always
// finishes the execute it started. Backed by a plain JSON file — one relayer process, low volume, no extra infra.

import type { RelayRequest } from "@safeswap/sdk";
import type { Hex } from "viem";

/** A committed bond awaiting its execute, persisted verbatim so a restart can resume it. */
export type PersistedBond = {
    request:        RelayRequest;
    create_tx_hash: Hex;
    committed_at:   number;
};


export class BondStore {

    readonly #path:  string;
    readonly #bonds: Map<string, PersistedBond>;

    constructor( path: string )
    {
        this.#path   =  path;
        this.#bonds  =  BondStore.#load( path );
    }

    /** Record a freshly committed bond (keyed by its commitment hash) and flush to disk before the execute is attempted. */
    put( commitment_hash: Hex, bond: PersistedBond ): void
    {
        this.#bonds.set( commitment_hash.toLowerCase(), bond );
        this.#flush();
    }

    /** Drop a bond once it has settled (executed or otherwise finalized); flush only if something was removed. */
    remove( commitment_hash: Hex ): void
    {
        if(  this.#bonds.delete( commitment_hash.toLowerCase() )  )  this.#flush();
    }

    /** Every committed-but-unsettled bond, oldest first, for the startup resume pass. */
    pending(): PersistedBond[]
    {
        return [ ...this.#bonds.values() ].sort(( a, b ) => a.committed_at - b.committed_at );
    }

    static #load( path: string ): Map<string, PersistedBond>
    {
        try
        {
            const raw     =  Deno.readTextFileSync( path );
            const record  =  JSON.parse( raw ) as Record<string, PersistedBond>;
            return new Map( Object.entries( record ) );
        }
        catch
        {
            return new Map();    // Missing or unreadable file → start empty (first boot, or nothing in flight).
        }
    }

    #flush(): void
    {
        const record  =  Object.fromEntries( this.#bonds );
        Deno.writeTextFileSync( this.#path, JSON.stringify( record, null, 4 ) );
    }
}

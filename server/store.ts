// SPDX-License-Identifier: MIT
//
// Address-keyed activity store for gasless bonds. The relayer is the source of truth for a user's in-flight and recent
// gasless ops: a bond is recorded the moment it is committed (the user's stake is now locked on-chain), then a worker drains
// it to execution. The client just asks `GET /activity/:address`, so closing the tab never loses the op — and a crash never
// strands the stake, because the same records drive resume on restart.
//
// Two implementations, chosen by whether DATABASE_URL is set:
//   • MemoryStore   — in-process, for local dev and tests (no DB needed).
//   • PostgresStore — durable + multi-instance-safe (SKIP LOCKED claim + an advisory-lock leader so only one container
//                     submits at a time, which keeps the single relayer EOA's nonces collision-free across green/blue).

import type { Address, Hex } from "viem";
import type { RelayRequest } from "@safeswap/sdk";

/** Lifecycle of a gasless bond as the relayer drives it. */
export type GaslessBondStatus  =  "received" | "committed" | "executing" | "executed" | "protocol_reverted" | "failed";

/** Human summary the client signs for, stored so activity can show "what / how much" without decoding calldata server-side. */
export type GaslessSummary  =  { kind: string, pay?: string, receive?: string };

/** A tracked gasless bond. `request` (which carries the signature/payload) is kept for the worker but never exposed publicly. */
export type GaslessRecord = {
    id:                   Hex;       // the BondRoute commitment hash — the bond's identity.
    user:                 Address;
    summary:              GaslessSummary;
    status:               GaslessBondStatus;
    request:              RelayRequest;
    create_tx_hash:       Hex;
    execute_tx_hash?:     Hex;
    revert_output?:       Hex;
    committed_at:         number;    // ms epoch.
    settled_at?:          number;    // ms epoch.
    updated_at:           number;    // ms epoch — used to re-claim bonds left "executing" by a crashed worker.
    target_executable_at: number;    // sec epoch — when the reveal delay elapses and execute may run.
};

/** The public projection returned by `/activity` and `/status` — no signature/payload, plus a live ETA. */
export type PublicRecord = {
    id:               Hex;
    summary:          GaslessSummary;
    status:           GaslessBondStatus;
    create_tx_hash:   Hex;
    execute_tx_hash?: Hex;
    revert_output?:   Hex;
    committed_at:     number;
    settled_at?:      number;
    eta_seconds:      number;        // seconds until the bond is expected to execute (0 once due/settled).
};

export type ActivityView  =  { in_progress: PublicRecord[], recent: PublicRecord[] };

/** Patch applied when a bond settles. */
export type SettlePatch  =  { status: GaslessBondStatus, execute_tx_hash?: Hex, revert_output?: Hex };

/** Bonds left "executing" longer than this (ms) are assumed orphaned by a crashed worker and re-claimed. */
const EXECUTING_LEASE_MS  =  90_000;

/** Terminal statuses never re-claimed by the worker. */
const TERMINAL: ReadonlySet<GaslessBondStatus>  =  new Set([ "executed", "protocol_reverted", "failed" ]);


export interface ActivityStore {
    /** Persist a bond. Used both for the pre-commit write-ahead (`status: "received"`) and a freshly committed bond. */
    record_committed( record: GaslessRecord ): Promise<void>;

    /** Promote a pre-commit `received` bond to `committed` once its commit tx has landed. No-op unless still `received`. */
    promote_committed( id: Hex, patch: { create_tx_hash: Hex, target_executable_at: number } ): Promise<void>;

    /** Every bond still in the pre-commit `received` state — the worker reconciles these against the chain. */
    list_received(): Promise<GaslessRecord[]>;

    /**
     * Run `fn` while holding the global single-writer submit lock, so every relayer transaction (commit OR execute, from any
     * process) is serialized — the one relayer EOA never has two in-flight nonces, even across green/blue. In-process mutex
     * for MemoryStore; a blocking postgres advisory lock for PostgresStore.
     */
    with_submit_lock<T>( fn: () => Promise<T> ): Promise<T>;

    /** Atomically claim one due bond (`committed` past its reveal time, or a stale `executing`), marking it `executing`. */
    claim_executable( now_ms: number ): Promise<GaslessRecord | null>;

    /** Finalize a bond after its execute settles. */
    mark_settled( id: Hex, patch: SettlePatch ): Promise<void>;

    /** Return a claimed bond to `committed` (e.g. a transient execute failure) so a later tick retries it. */
    release( id: Hex ): Promise<void>;

    /** A single bond's public view, or null if unknown. */
    get( id: Hex ): Promise<PublicRecord | null>;

    /** A user's in-progress and recent (most-recent-first) bonds. */
    activity( user: Address, recent_limit: number ): Promise<ActivityView>;

    close(): Promise<void>;
}


// ━━━━  PROJECTION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

export function to_public( record: GaslessRecord ): PublicRecord
{
    const due_in  =  record.target_executable_at - Math.floor( Date.now() / 1000 );
    return {
        id:               record.id,
        summary:          record.summary,
        status:           record.status,
        create_tx_hash:   record.create_tx_hash,
        execute_tx_hash:  record.execute_tx_hash,
        revert_output:    record.revert_output,
        committed_at:     record.committed_at,
        settled_at:       record.settled_at,
        eta_seconds:      TERMINAL.has( record.status ) ? 0 : Math.max( 0, due_in ),
    };
}

function is_in_progress( record: GaslessRecord ): boolean
{
    return TERMINAL.has( record.status ) === false;
}


// ━━━━  MEMORY STORE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

export class MemoryStore implements ActivityStore {

    readonly #records  =  new Map<string, GaslessRecord>();
    #submit_chain: Promise<unknown>  =  Promise.resolve();

    record_committed( record: GaslessRecord ): Promise<void>
    {
        this.#records.set( record.id.toLowerCase(), record );
        return Promise.resolve();
    }

    promote_committed( id: Hex, patch: { create_tx_hash: Hex, target_executable_at: number } ): Promise<void>
    {
        const record  =  this.#records.get( id.toLowerCase() );
        if(  record !== undefined && record.status === "received"  )
        {
            record.status                =  "committed";
            record.create_tx_hash        =  patch.create_tx_hash;
            record.target_executable_at  =  patch.target_executable_at;
            record.updated_at            =  Date.now();
        }
        return Promise.resolve();
    }

    list_received(): Promise<GaslessRecord[]>
    {
        return Promise.resolve( [ ...this.#records.values() ].filter(( record ) => record.status === "received" ) );
    }

    with_submit_lock<T>( fn: () => Promise<T> ): Promise<T>
    {
        // Chain submissions so commit and execute never overlap within this process (serial nonces).
        const result   =  this.#submit_chain.then( () => fn() );
        this.#submit_chain  =  result.then( () => undefined, () => undefined );
        return result;
    }

    claim_executable( now_ms: number ): Promise<GaslessRecord | null>
    {
        const now_sec  =  Math.floor( now_ms / 1000 );

        for(  const record of [ ...this.#records.values() ].sort(( a, b ) => a.committed_at - b.committed_at )  )
        {
            const due       =  record.status === "committed" && record.target_executable_at <= now_sec;
            const orphaned  =  record.status === "executing" && now_ms - record.updated_at > EXECUTING_LEASE_MS;
            if(  due || orphaned  )
            {
                record.status      =  "executing";
                record.updated_at  =  now_ms;
                return Promise.resolve( record );
            }
        }
        return Promise.resolve( null );
    }

    mark_settled( id: Hex, patch: SettlePatch ): Promise<void>
    {
        const record  =  this.#records.get( id.toLowerCase() );
        if(  record !== undefined  )
        {
            record.status            =  patch.status;
            record.execute_tx_hash   =  patch.execute_tx_hash ?? record.execute_tx_hash;
            record.revert_output     =  patch.revert_output;
            record.settled_at        =  Date.now();
            record.updated_at        =  Date.now();
        }
        return Promise.resolve();
    }

    release( id: Hex ): Promise<void>
    {
        const record  =  this.#records.get( id.toLowerCase() );
        if(  record !== undefined && record.status === "executing"  )
        {
            record.status      =  "committed";
            record.updated_at  =  Date.now();
        }
        return Promise.resolve();
    }

    get( id: Hex ): Promise<PublicRecord | null>
    {
        const record  =  this.#records.get( id.toLowerCase() );
        return Promise.resolve( record === undefined ? null : to_public( record ) );
    }

    activity( user: Address, recent_limit: number ): Promise<ActivityView>
    {
        const mine  =  [ ...this.#records.values() ]
            .filter(( record ) => record.user.toLowerCase() === user.toLowerCase() )
            .sort(( a, b ) => b.committed_at - a.committed_at );

        return Promise.resolve({
            in_progress: mine.filter( is_in_progress ).map( to_public ),
            recent:      mine.filter(( record ) => is_in_progress( record ) === false ).slice( 0, recent_limit ).map( to_public ),
        });
    }

    close(): Promise<void>
    {
        return Promise.resolve();
    }
}


// ━━━━  POSTGRES STORE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// A fixed 64-bit key for the global single-writer submit lock (any arbitrary constant all processes agree on). A blocking
// `pg_advisory_lock` on it serializes every relayer transaction across containers, so the one EOA never double-spends a nonce.
const SUBMIT_ADVISORY_KEY  =  4_736_021n;

/**
 * Durable, multi-instance-safe store. *UNVERIFIED against a live database* until the Docker/deploy pass — the MemoryStore is
 * the path exercised locally and in tests. Uses `postgres` (postgres.js); the table is auto-created on construction.
 */
export class PostgresStore implements ActivityStore {

    // deno-lint-ignore no-explicit-any
    readonly #sql: any;

    private constructor( sql: unknown )
    {
        this.#sql  =  sql;
    }

    static async init( database_url: string ): Promise<PostgresStore>
    {
        const { default: postgres }  =  await import( "postgres" );
        const sql                    =  postgres( database_url );

        await sql`
            CREATE TABLE IF NOT EXISTS gasless_bond (
                id                   text PRIMARY KEY,
                "user"               text NOT NULL,
                summary              jsonb NOT NULL,
                status               text NOT NULL,
                request              jsonb NOT NULL,
                create_tx_hash       text NOT NULL,
                execute_tx_hash      text,
                revert_output        text,
                committed_at         bigint NOT NULL,
                settled_at           bigint,
                updated_at           bigint NOT NULL,
                target_executable_at bigint NOT NULL
            )
        `;
        await sql`CREATE INDEX IF NOT EXISTS gasless_bond_user_idx ON gasless_bond ( lower("user"), committed_at DESC )`;
        await sql`CREATE INDEX IF NOT EXISTS gasless_bond_claim_idx ON gasless_bond ( status, target_executable_at )`;

        return new PostgresStore( sql );
    }

    async record_committed( record: GaslessRecord ): Promise<void>
    {
        await this.#sql`
            INSERT INTO gasless_bond
                ( id, "user", summary, status, request, create_tx_hash, committed_at, updated_at, target_executable_at )
            VALUES (
                ${ record.id.toLowerCase() }, ${ record.user.toLowerCase() }, ${ this.#sql.json( record.summary ) }, ${ record.status },
                ${ this.#sql.json( record.request ) }, ${ record.create_tx_hash }, ${ record.committed_at }, ${ record.updated_at }, ${ record.target_executable_at }
            )
            ON CONFLICT ( id ) DO NOTHING
        `;
    }

    async promote_committed( id: Hex, patch: { create_tx_hash: Hex, target_executable_at: number } ): Promise<void>
    {
        await this.#sql`
            UPDATE gasless_bond
            SET status = 'committed', create_tx_hash = ${ patch.create_tx_hash }, target_executable_at = ${ patch.target_executable_at }, updated_at = ${ Date.now() }
            WHERE id = ${ id.toLowerCase() } AND status = 'received'
        `;
    }

    async list_received(): Promise<GaslessRecord[]>
    {
        const rows  =  await this.#sql`SELECT * FROM gasless_bond WHERE status = 'received'`;
        return rows.map(( row: unknown ) => this.#from_row( row ) );
    }

    async with_submit_lock<T>( fn: () => Promise<T> ): Promise<T>
    {
        // A dedicated connection holds the blocking advisory lock for the duration — serializing submissions across all
        // containers sharing this database.
        const reserved  =  await this.#sql.reserve();
        try
        {
            await reserved`SELECT pg_advisory_lock( ${ SUBMIT_ADVISORY_KEY } )`;
            try
            {
                return await fn();
            }
            finally
            {
                await reserved`SELECT pg_advisory_unlock( ${ SUBMIT_ADVISORY_KEY } )`;
            }
        }
        finally
        {
            reserved.release();
        }
    }

    async claim_executable( now_ms: number ): Promise<GaslessRecord | null>
    {
        const now_sec       =  Math.floor( now_ms / 1000 );
        const stale_before  =  now_ms - EXECUTING_LEASE_MS;

        const rows  =  await this.#sql`
            UPDATE gasless_bond SET status = 'executing', updated_at = ${ now_ms }
            WHERE id = (
                SELECT id FROM gasless_bond
                WHERE ( status = 'committed' AND target_executable_at <= ${ now_sec } )
                   OR ( status = 'executing' AND updated_at < ${ stale_before } )
                ORDER BY committed_at
                FOR UPDATE SKIP LOCKED
                LIMIT 1
            )
            RETURNING *
        `;
        return rows.length === 0 ? null : this.#from_row( rows[0] );
    }

    async mark_settled( id: Hex, patch: SettlePatch ): Promise<void>
    {
        const now  =  Date.now();
        await this.#sql`
            UPDATE gasless_bond
            SET status = ${ patch.status }, execute_tx_hash = ${ patch.execute_tx_hash ?? null }, revert_output = ${ patch.revert_output ?? null },
                settled_at = ${ now }, updated_at = ${ now }
            WHERE id = ${ id.toLowerCase() }
        `;
    }

    async release( id: Hex ): Promise<void>
    {
        await this.#sql`
            UPDATE gasless_bond SET status = 'committed', updated_at = ${ Date.now() }
            WHERE id = ${ id.toLowerCase() } AND status = 'executing'
        `;
    }

    async get( id: Hex ): Promise<PublicRecord | null>
    {
        const rows  =  await this.#sql`SELECT * FROM gasless_bond WHERE id = ${ id.toLowerCase() }`;
        return rows.length === 0 ? null : to_public( this.#from_row( rows[0] ) );
    }

    async activity( user: Address, recent_limit: number ): Promise<ActivityView>
    {
        const rows  =  await this.#sql`
            SELECT * FROM gasless_bond WHERE lower("user") = ${ user.toLowerCase() } ORDER BY committed_at DESC
        `;
        const records  =  rows.map(( row: unknown ) => this.#from_row( row ) );
        return {
            in_progress: records.filter( is_in_progress ).map( to_public ),
            recent:      records.filter(( record: GaslessRecord ) => is_in_progress( record ) === false ).slice( 0, recent_limit ).map( to_public ),
        };
    }

    async close(): Promise<void>
    {
        await this.#sql.end();
    }

    // deno-lint-ignore no-explicit-any
    #from_row( row: any ): GaslessRecord
    {
        return {
            id:                   row.id,
            user:                 row.user,
            summary:              row.summary,
            status:               row.status,
            request:              row.request,
            create_tx_hash:       row.create_tx_hash,
            execute_tx_hash:      row.execute_tx_hash ?? undefined,
            revert_output:        row.revert_output ?? undefined,
            committed_at:         Number( row.committed_at ),
            settled_at:           row.settled_at === null ? undefined : Number( row.settled_at ),
            updated_at:           Number( row.updated_at ),
            target_executable_at: Number( row.target_executable_at ),
        };
    }
}


// ━━━━  FACTORY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/** Postgres when a `database_url` is configured (prod), otherwise an in-process memory store (local dev / tests). */
export async function create_store( database_url: string | undefined ): Promise<ActivityStore>
{
    if(  database_url === undefined  )  return new MemoryStore();
    return await PostgresStore.init( database_url );
}

// SPDX-License-Identifier: MIT
//
// SafeSwap gasless relayer — the server-side half of the EIP-7702 flow. The user signs only (off-chain): one
// `SafeSwapGaslessBond` intent and a 7702 authorization delegating their EOA to the SafeSwap relayer delegate. This relayer
// validates that signed intent, then submits two sponsored type-0x04 transactions against the user's EOA — first
// `create_bond_from_user_stake` (hidden commit, which stakes the user's OWN tokens and pays this relayer its signed fee),
// then, past BondRoute's reveal delay, `execute_bond_from_user`. The relayer pays only gas; the stake, fundings, and fee all
// come from the user's EOA balance, and all on-chain output flows back to the user.
//
// See FRONTEND_SPEC_DECISIONS.md "Gasless execution via EIP-7702" and contracts/Relayer/Relayer.sol for the binding protocol.

import {
    concatHex,
    createPublicClient,
    createWalletClient,
    encodeAbiParameters,
    http,
    keccak256,
    recoverAddress,
    toHex,
    type Account,
    type Address,
    type Hex,
    type PublicClient,
    type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { BONDROUTE_ADDRESS, type ExecutionData } from "@bondroute/sdk";
import {
    SAFESWAP_RELAYER_DELEGATE_ABI,
    deserialize_execution_data,
    type GaslessActivity,
    type GaslessBondStatus,
    type GaslessCommit,
    type GaslessJob,
    type RelayRequest,
    type SerializedGaslessIntent,
} from "@safeswap/sdk";
import { load_config, MAX_RELAY_COST_USD, type RelayerConfig } from "./config.ts";
import { create_store, type ActivityStore, type GaslessRecord } from "./store.ts";

const BONDROUTE_BOND_INFO_ABI  =  [
    {
        type:            "function",
        name:            "__OFF_CHAIN__get_bond_info",
        stateMutability: "view",
        inputs:  [
            { name: "commitment_hash", type: "bytes32" },
            { name: "stake", type: "tuple", components: [ { name: "token", type: "address" }, { name: "amount", type: "uint256" } ] },
        ],
        outputs: [ {
            name: "bond_info", type: "tuple",
            components: [
                { name: "creation_time", type: "uint256" },
                { name: "creation_block", type: "uint256" },
                { name: "stake_amount_received", type: "uint256" },
                { name: "status", type: "uint8" },
            ],
        } ],
    },
] as const;

// EIP-712 constants mirroring contracts/Relayer/Relayer.sol so the relayer can re-verify the user's signature before
// spending any gas. The delegate's domain is rebuilt with `verifyingContract == the user's EOA` when it runs delegated.
const EIP712_DOMAIN_TYPE_HASH  =  keccak256( toHex( "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)" ) );
const TOKEN_AMOUNT_TYPE_HASH   =  keccak256( toHex( "TokenAmount(address token,uint256 amount)" ) );
const GASLESS_DOMAIN_NAME_HASH     =  keccak256( toHex( "SafeSwap Gasless" ) );
const GASLESS_DOMAIN_VERSION_HASH  =  keccak256( toHex( "1" ) );

// *NOTE*  -  The two phases run the delegate AS the user's EOA via a 7702 authorization, so they cannot be live `estimateGas`-d
//            before the delegation is applied. These conservative static ceilings intentionally overstate real usage so the
//            cost guard never under-counts; the execute leg drives the protocol action through BondRoute + V4, so it is heavier.
const ESTIMATED_CREATE_GAS   =  400_000n;
const ESTIMATED_EXECUTE_GAS  =  600_000n;

/** Safety markup applied to the summed gas estimate before the USD ceiling check. */
const GAS_MARKUP_PERCENT  =  10n;

/** How often the background worker checks for due bonds to execute. */
const WORKER_INTERVAL_MS  =  2_000;

/** A write-ahead `received` bond with no on-chain bond after this long is treated as a commit that never landed → failed. */
const RECEIVED_RECONCILE_GRACE_MS  =  60_000;

/** BondRoute's `BondStatus.ACTIVE` (Definitions.sol relies on it being 0): created, awaiting execution. */
const BOND_STATUS_ACTIVE  =  0;

/** Map BondRoute's settled `BondStatus` (Definitions.sol) to the store's terminal vocabulary. */
const BOND_STATUS: Record<number, GaslessBondStatus>  =  {
    1: "executed",
    2: "failed",             // INVALID_BOND
    3: "protocol_reverted",
    4: "failed",             // LIQUIDATED (expired then claimed by the collector)
};

type GaslessIntent = {
    helper:          Address;
    relayer:         Address;
    relayer_fee:     { token: Address, amount: bigint };
    stake:           { token: Address, amount: bigint };
    create_deadline: bigint;
    commitment_hash: Hex;
};

/** A relay rejection the caller should surface as a 4xx (bad/forbidden request), distinct from an internal failure. */
export class RelayRejected extends Error {
    constructor( message: string )
    {
        super( message );
        this.name  =  "RelayRejected";
    }
}


export class Relayer {

    readonly #config:            RelayerConfig;
    readonly #account:           Account;
    readonly #public_client:     PublicClient;
    readonly #wallet_client:     WalletClient;
    readonly #bondroute_address: Address;
    readonly #allowed_protocols: Set<string>;
    readonly #store:             ActivityStore;

    /** Locally-tracked next nonce for the relayer EOA: resynced robustly from the chain when unset, advanced per confirmed tx,
     *  and reset on any submit error. Only ever touched under the submit lock, so access is serial. */
    #nonce: number | null  =  null;

    private constructor( config: RelayerConfig, account: Account, public_client: PublicClient, wallet_client: WalletClient, store: ActivityStore )
    {
        this.#config             =  config;
        this.#account            =  account;
        this.#public_client      =  public_client;
        this.#wallet_client      =  wallet_client;
        this.#bondroute_address  =  config.bondroute_address ?? BONDROUTE_ADDRESS;
        this.#allowed_protocols  =  new Set([ config.router_address.toLowerCase(), config.nft_address.toLowerCase() ]);
        this.#store              =  store;
    }

    static async init(): Promise<Relayer>
    {
        const config         =  load_config();
        const account        =  privateKeyToAccount( config.relayer_private_key );
        // Spoof a Referer/Origin so a referrer-locked RPC (e.g. QuickNode whitelisted to the site domain) accepts the
        // relayer's server-side requests. Harmless on RPCs that don't gate by referrer. Configurable via RELAYER_RPC_REFERER.
        const referer        =  Deno.env.get( "RELAYER_RPC_REFERER" )?.trim() || "https://safeswap.spot";
        const rpc_transport  =  http( config.rpc_url, { fetchOptions: { headers: { "Referer": referer, "Origin": referer } } } );
        const public_client  =  createPublicClient({ transport: rpc_transport }) as PublicClient;
        const wallet_client  =  createWalletClient({ account, transport: rpc_transport });
        const store          =  await create_store( config.database_url );

        return new Relayer( config, account, public_client, wallet_client, store );
    }

    get config(): RelayerConfig
    {
        return this.#config;
    }

    /**
     * Validate and COMMIT one gasless operation, then return immediately with a job handle. The reveal-delay wait and the
     * execute happen in the background worker — so the HTTP request is short, and once committed the user's op is tracked
     * server-side (durable in postgres), recoverable across crashes, and pollable via `activity`/`status`. Validation runs
     * BEFORE any gas is spent.
     */
    async relay( request: RelayRequest ): Promise<GaslessCommit>
    {
        if(  request.chain_id !== this.#config.chain_id  )  throw new RelayRejected( `Wrong chain ${ request.chain_id }; relayer serves ${ this.#config.chain_id }.` );

        const intent          =  deserialize_intent( request.intent );
        const execution_data  =  deserialize_execution_data( request.execution_data );

        this.#assert_intent_addresses( intent );
        this.#assert_protocol_in_scope( execution_data );
        this.#assert_deadline( intent );
        await this.#assert_valid_signature( request, intent );
        await this.#assert_affordable_gas();

        // ── PERSIST FIRST as "received", then commit (write-ahead) ──
        // Record the bond BEFORE any on-chain action — as `received`, NOT `committed`, because it has not committed yet. If the
        // commit lands but this process then fails (RPC hiccup mid-read, crash), the `received` record is already persisted and
        // the worker reconciles it against the chain and promotes it to `committed` — so it is never orphaned. The stored
        // request carries the signature + execution_data, so recovery never depends on the client re-submitting.
        const now                   =  Date.now();
        let   target_executable_at  =  Math.floor( now / 1000 ) + this.#config.reveal_delay_seconds;   // estimate; refined after commit

        await this.#store.record_committed({
            id:                   intent.commitment_hash,
            user:                 request.user,
            summary:              request.summary ?? { kind: "gasless" },
            status:               "received",
            request,
            create_tx_hash:       "0x0000000000000000000000000000000000000000000000000000000000000000",
            committed_at:         now,
            updated_at:           now,
            target_executable_at,
        });

        // ── Commit: run the delegate as the user's EOA (stakes the user's tokens, pays this relayer its fee), through the
        // global submit lock so it never races the worker's executes on the relayer EOA nonce. ──
        let create_tx_hash: Hex;
        try
        {
            create_tx_hash  =  await this.#store.with_submit_lock( () =>
                this.#submit_via_7702( request, "create_bond_from_user_stake", [ intent, request.gasless_type_hash, request.action_struct_hash, request.signature ], request.authorization )
            );
        }
        catch( commit_error )
        {
            // The commit failed. If no bond exists on-chain it never landed → drop the write-ahead record so the worker does
            // not chase a phantom. If a bond DOES exist (a duplicate submit / earlier attempt), the record is real — keep it.
            if(  await this.#try_bond_info( intent ) === null  )  await this.#store.mark_settled( intent.commitment_hash, { status: "failed" } );
            throw commit_error;
        }

        // ── Promote received → committed: the commit landed, so refine the tx hash + exact execute time from the on-chain bond
        // and flip the bond to `committed`. Best-effort: if the read lags or this process dies, the `received` record stands and
        // the worker reconciles it against the chain. ──
        try
        {
            const info            =  await this.#bond_info( intent );
            target_executable_at  =  Number( info.creation_time ) + this.#config.reveal_delay_seconds;
            await this.#store.promote_committed( intent.commitment_hash, { create_tx_hash, target_executable_at } );
        }
        catch( finalize_error )
        {
            console.error( "Bond %s committed but post-commit promotion failed; the worker will reconcile.", intent.commitment_hash, finalize_error );
        }

        return { id: intent.commitment_hash, create_tx_hash, status: "committed", target_executable_at };
    }

    /** A user's in-progress + recent gasless activity — the address-keyed view the client polls. */
    async activity( user: Address ): Promise<GaslessActivity>
    {
        return await this.#store.activity( user, this.#config.recent_limit );
    }

    /** A single bond's public status, or null if this relayer has no record of it. */
    async status( id: Hex ): Promise<GaslessJob | null>
    {
        return await this.#store.get( id );
    }


    // ━━━━  WORKER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * Start the background loop that drains committed bonds to execution. This is the single mechanism for both fresh execution
     * and crash recovery: a committed bond persisted by *any* process (including one that died mid-flight) is picked up here.
     */
    start_worker(): void
    {
        const loop  =  async () => {
            try        {  await this.#worker_tick();  }
            catch( error )  {  console.error( "SafeSwap relayer worker tick failed:", error );  }
            finally    {  setTimeout( loop, WORKER_INTERVAL_MS );  }
        };
        loop();
    }

    async #worker_tick(): Promise<void>
    {
        // First reconcile write-ahead `received` bonds against the chain (promote committed ones, fail dead ones), so a relay
        // that committed but crashed before promoting still gets picked up and executed.
        await this.#reconcile_received();

        // Claim is multi-instance-safe (SKIP LOCKED); the per-tx submit lock (in `#execute_claimed`) serializes nonces.
        for( ; ; )
        {
            const record  =  await this.#store.claim_executable( Date.now() );
            if(  record === null  )  return;
            await this.#execute_claimed( record );
        }
    }

    /** Reconcile pre-commit `received` bonds against the chain: promote ones whose commit landed to `committed`, and fail ones
     *  that have clearly never committed (no on-chain bond after the grace period). The write-ahead recovery path. */
    async #reconcile_received(): Promise<void>
    {
        for(  const record of await this.#store.list_received()  )
        {
            try
            {
                const intent  =  deserialize_intent( record.request.intent );
                const info    =  await this.#try_bond_info( intent );
                if(  info !== null  )
                {
                    await this.#store.promote_committed( record.id, {
                        create_tx_hash:       record.create_tx_hash,
                        target_executable_at: Number( info.creation_time ) + this.#config.reveal_delay_seconds,
                    });
                }
                else if(  Date.now() - record.committed_at > RECEIVED_RECONCILE_GRACE_MS  )
                {
                    await this.#store.mark_settled( record.id, { status: "failed" } );
                }
            }
            catch( error )
            {
                console.error( "Reconcile failed for received bond %s; will retry next tick.", record.id, error );
            }
        }
    }

    async #execute_claimed( record: GaslessRecord ): Promise<void>
    {
        const intent  =  deserialize_intent( record.request.intent );
        try
        {
            const info  =  await this.#bond_info( intent );

            if(  info.status !== BOND_STATUS_ACTIVE  )
            {
                // Already settled on-chain (e.g. executed by a prior run just before a crash) — record the outcome and move on.
                await this.#store.mark_settled( record.id, { status: BOND_STATUS[ info.status ] ?? "failed" } );
                return;
            }
            if(  await this.#is_executable( info ) === false  )
            {
                await this.#store.release( record.id );    // Claimed a touch early; the reveal delay is not fully elapsed yet.
                return;
            }

            const execution_data   =  deserialize_execution_data( record.request.execution_data );
            const execute_tx_hash  =  await this.#store.with_submit_lock( () =>
                this.#submit_via_7702(
                    record.request,
                    "execute_bond_from_user",
                    [ intent, record.request.gasless_type_hash, record.request.action_struct_hash, record.request.signature, execution_data ],
                    null,    // The EOA was delegated at commit; execute needs no re-delegation.
                )
            );

            const settled  =  await this.#bond_info( intent );
            await this.#store.mark_settled( record.id, { status: BOND_STATUS[ settled.status ] ?? "failed", execute_tx_hash } );
        }
        catch( error )
        {
            console.error( "Execute failed for bond %s; returning it to the queue to retry.", record.id, error );
            await this.#store.release( record.id );
        }
    }


    // ━━━━  VALIDATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #assert_intent_addresses( intent: GaslessIntent ): void
    {
        if(  intent.helper.toLowerCase() !== this.#config.relayer_delegate_address.toLowerCase()  )
        {
            throw new RelayRejected( `Intent helper ${ intent.helper } is not this relayer's delegate.` );
        }
        if(  intent.relayer.toLowerCase() !== this.#account.address.toLowerCase()  )
        {
            throw new RelayRejected( `Intent relayer ${ intent.relayer } is not this relayer (${ this.#account.address }).` );
        }
    }

    #assert_protocol_in_scope( execution_data: ExecutionData ): void
    {
        if(  this.#allowed_protocols.has( execution_data.protocol.toLowerCase() ) === false  )
        {
            throw new RelayRejected( `Protocol ${ execution_data.protocol } is not the SafeSwap Router or NFT; relaying is refused.` );
        }
    }

    #assert_deadline( intent: GaslessIntent ): void
    {
        const now  =  BigInt( Math.floor( Date.now() / 1000 ) );
        if(  now > intent.create_deadline  )  throw new RelayRejected( `Commit deadline ${ intent.create_deadline } already passed.` );
    }

    /**
     * Re-verify the user's `SafeSwapGaslessBond` signature off-chain (mirrors the delegate's `_hash_gasless_intent` and the
     * EIP-712 domain it rebuilds with `verifyingContract == user`), so a forged or stale signature is rejected before any
     * gas is spent rather than reverting the commit on-chain.
     */
    async #assert_valid_signature( request: RelayRequest, intent: GaslessIntent ): Promise<void>
    {
        const domain_separator  =  keccak256( encodeAbiParameters(
            [ { type: "bytes32" }, { type: "bytes32" }, { type: "bytes32" }, { type: "uint256" }, { type: "address" } ],
            [ EIP712_DOMAIN_TYPE_HASH, GASLESS_DOMAIN_NAME_HASH, GASLESS_DOMAIN_VERSION_HASH, BigInt( request.chain_id ), request.user ]
        ) );

        const struct_hash  =  keccak256( encodeAbiParameters(
            [ { type: "bytes32" }, { type: "address" }, { type: "address" }, { type: "bytes32" }, { type: "bytes32" }, { type: "uint256" }, { type: "bytes32" }, { type: "bytes32" } ],
            [
                request.gasless_type_hash,
                intent.helper,
                intent.relayer,
                hash_token_amount( intent.relayer_fee ),
                hash_token_amount( intent.stake ),
                intent.create_deadline,
                intent.commitment_hash,
                request.action_struct_hash,
            ]
        ) );

        const digest     =  keccak256( concatHex([ "0x1901", domain_separator, struct_hash ]) );
        const recovered  =  await recoverAddress({ hash: digest, signature: request.signature });

        if(  recovered.toLowerCase() !== request.user.toLowerCase()  )
        {
            throw new RelayRejected( `SafeSwapGaslessBond signature recovers to ${ recovered }, not the claimed user ${ request.user }.` );
        }
    }

    async #assert_affordable_gas(): Promise<void>
    {
        // Fail-closed: without a native USD price the ceiling is unverifiable, so refuse rather than sponsor blind.
        if(  this.#config.native_usd_price === undefined  )
        {
            throw new RelayRejected( "Relayer gas-cost ceiling is unverifiable (RELAYER_NATIVE_USD_PRICE unset); refusing to sponsor." );
        }

        const gas_price    =  await this.#public_client.getGasPrice();
        const total_gas    =  ( ( ESTIMATED_CREATE_GAS + ESTIMATED_EXECUTE_GAS ) * ( 100n + GAS_MARKUP_PERCENT ) ) / 100n;
        const cost_native  =  Number( total_gas * gas_price ) / 1e18;
        const cost_usd     =  cost_native * this.#config.native_usd_price;

        if(  cost_usd > MAX_RELAY_COST_USD  )  throw new RelayRejected( `Estimated gas cost $${ cost_usd.toFixed(4) } exceeds the $${ MAX_RELAY_COST_USD } relay ceiling.` );
    }


    // ━━━━  TRANSACTIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    async #submit_via_7702( request: RelayRequest, function_name: "create_bond_from_user_stake" | "execute_bond_from_user", args: readonly unknown[], authorization: RelayRequest[ "authorization" ] ): Promise<Hex>
    {
        // The tx `to` is the user's own EOA — now running the delegate's code via the 7702 authorization. The relayer attaches
        // no value: native stake/fundings are paid from the EOA's own balance by the delegate (`{ value: ... }`). The
        // authorization is attached only when present; for the execute it is `null` because the commit already delegated the
        // EOA (and `null` also covers an already-delegated EOA whose commit needed no re-delegation).
        const base_params  =  {
            account:      this.#account,
            chain:        null,
            address:      request.user,
            abi:          SAFESWAP_RELAYER_DELEGATE_ABI,
            functionName: function_name,
            args,
            ...( authorization === null ? {} : { authorizationList: [ authorization ] } ),
        };

        // Resilient submit: a load-balanced public RPC can serve a stale `getTransactionCount`, and the relayer EOA's nonce can
        // drift, so use a locally-tracked nonce and, on any nonce/replacement error, re-sync from the chain and retry.
        let last_error: unknown;
        for(  let attempt = 0  ;  attempt < 6  ;  attempt++  )
        {
            const nonce  =  await this.#reserve_nonce();
            try
            {
                const hash     =  await this.#wallet_client.writeContract({ ...base_params, nonce } as Parameters<WalletClient["writeContract"]>[0] );
                const receipt  =  await this.#public_client.waitForTransactionReceipt({ hash });

                // `waitForTransactionReceipt` does NOT throw on a reverted tx, so check explicitly — otherwise a reverted commit
                // would be treated as success and persist a phantom bond. (A BondRoute *protocol* revert does not revert this tx;
                // it settles with a non-EXECUTED status, read back from the bond info.)
                if(  receipt.status !== "success"  )  throw new Error( `${ function_name } transaction ${ hash } reverted on-chain.` );

                this.#nonce  =  nonce + 1;   // advance only after a confirmed-mined tx
                return hash;
            }
            catch( error )
            {
                last_error   =  error;
                this.#nonce  =  null;   // force a fresh robust re-sync before any retry (covers a stale read or a drifted nonce)
                const message    =  String( ( error as { message?: string } )?.message ?? error ).toLowerCase();
                const retriable  =  message.includes( "nonce" ) || message.includes( "replacement transaction underpriced" ) || message.includes( "already known" );
                if(  retriable === false  )  throw error;   // a genuine revert / unrelated failure — surface it
            }
        }
        throw last_error;
    }

    /** Reserve the next nonce for the relayer EOA (caller holds the submit lock). Resynced from the chain when unset. */
    async #reserve_nonce(): Promise<number>
    {
        if(  this.#nonce === null  )  this.#nonce  =  await this.#fetch_chain_nonce();
        return this.#nonce;
    }

    /** Read the EOA's pending nonce, taking the MAX over several reads so one stale load-balanced node can't under-report it. */
    async #fetch_chain_nonce(): Promise<number>
    {
        let best  =  0;
        for(  let i = 0  ;  i < 5  ;  i++  )
        {
            try
            {
                const n  =  await this.#public_client.getTransactionCount({ address: this.#account.address, blockTag: "pending" });
                if(  n > best  )  best  =  n;
            }
            catch { /* skip a bad read; another attempt will land */ }
        }
        return best;
    }

    /** Whether the bond's reveal delay (both block and time floors) has fully elapsed, so execute won't revert as too-early. */
    async #is_executable( info: { creation_time: bigint, creation_block: bigint } ): Promise<boolean>
    {
        const block  =  await this.#public_client.getBlock();
        return block.number    >= info.creation_block + BigInt( this.#config.reveal_delay_blocks )
            && block.timestamp >= info.creation_time  + BigInt( this.#config.reveal_delay_seconds );
    }

    /** A single, non-retrying bond-info read that returns null when the bond does not exist (the contract reverts). Lets
     *  `relay()` detect an already-committed bond and resume it instead of re-committing (which would revert). */
    async #try_bond_info( intent: GaslessIntent ): Promise<{ creation_time: bigint, creation_block: bigint, status: number } | null>
    {
        await new Promise(( resolve ) => setTimeout( resolve, 1500 ));   // settle before reading — let the RPC catch up
        try
        {
            const info  =  await this.#public_client.readContract({
                address:      this.#bondroute_address,
                abi:          BONDROUTE_BOND_INFO_ABI,
                functionName: "__OFF_CHAIN__get_bond_info",
                args:         [ intent.commitment_hash, intent.stake ],
            });
            return { creation_time: info.creation_time, creation_block: info.creation_block, status: Number( info.status ) };
        }
        catch
        {
            return null;
        }
    }

    async #bond_info( intent: GaslessIntent ): Promise<{ creation_time: bigint, creation_block: bigint, status: number }>
    {
        // A public RPC can serve a read from a node that hasn't yet caught up to a freshly-mined block, so a just-committed
        // bond may briefly read as "not found" (the contract reverts). SETTLE ~1.5s before each read (so the node catches up),
        // and retry before giving up.
        let last_error: unknown;
        for(  let attempt = 0  ;  attempt < 10  ;  attempt++  )
        {
            await new Promise(( resolve ) => setTimeout( resolve, 1500 ));   // settle before reading — let the RPC catch up
            try
            {
                const info  =  await this.#public_client.readContract({
                    address:      this.#bondroute_address,
                    abi:          BONDROUTE_BOND_INFO_ABI,
                    functionName: "__OFF_CHAIN__get_bond_info",
                    args:         [ intent.commitment_hash, intent.stake ],
                });
                return { creation_time: info.creation_time, creation_block: info.creation_block, status: Number( info.status ) };
            }
            catch( error )
            {
                last_error  =  error;
            }
        }
        throw last_error;
    }
}


// ━━━━  SERIALIZATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function deserialize_intent( intent: SerializedGaslessIntent ): GaslessIntent
{
    return {
        helper:          intent.helper,
        relayer:         intent.relayer,
        relayer_fee:     { token: intent.relayer_fee.token, amount: BigInt( intent.relayer_fee.amount ) },
        stake:           { token: intent.stake.token, amount: BigInt( intent.stake.amount ) },
        create_deadline: BigInt( intent.create_deadline ),
        commitment_hash: intent.commitment_hash,
    };
}

function hash_token_amount( token_amount: { token: Address, amount: bigint } ): Hex
{
    return keccak256( encodeAbiParameters(
        [ { type: "bytes32" }, { type: "address" }, { type: "uint256" } ],
        [ TOKEN_AMOUNT_TYPE_HASH, token_amount.token, token_amount.amount ]
    ) );
}

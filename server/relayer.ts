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
    type GaslessRelayResult,
    type RelayRequest,
    type SerializedGaslessIntent,
} from "@safeswap/sdk";
import { load_config, MAX_RELAY_COST_USD, type RelayerConfig } from "./config.ts";
import { BondStore } from "./bond_store.ts";

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

/** BondRoute's `BondStatus.ACTIVE` (Definitions.sol relies on it being 0): created, awaiting execution. */
const BOND_STATUS_ACTIVE  =  0;

/** Map BondRoute's `BondStatus` enum (Definitions.sol) to the gasless result discriminator. */
const BOND_STATUS: Record<number, GaslessRelayResult["status"]>  =  {
    1: "executed",
    2: "invalid_bond",
    3: "protocol_reverted",
    4: "liquidated",
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
    readonly #store:             BondStore;

    private constructor( config: RelayerConfig, account: Account, public_client: PublicClient, wallet_client: WalletClient, store: BondStore )
    {
        this.#config             =  config;
        this.#account            =  account;
        this.#public_client      =  public_client;
        this.#wallet_client      =  wallet_client;
        this.#bondroute_address  =  config.bondroute_address ?? BONDROUTE_ADDRESS;
        this.#allowed_protocols  =  new Set([ config.router_address.toLowerCase(), config.nft_address.toLowerCase() ]);
        this.#store              =  store;
    }

    static init(): Relayer
    {
        const config         =  load_config();
        const account        =  privateKeyToAccount( config.relayer_private_key );
        const public_client  =  createPublicClient({ transport: http( config.rpc_url ) }) as PublicClient;
        const wallet_client  =  createWalletClient({ account, transport: http( config.rpc_url ) });

        return new Relayer( config, account, public_client, wallet_client, new BondStore( config.state_file ) );
    }

    get config(): RelayerConfig
    {
        return this.#config;
    }

    /**
     * Validate, commit, wait, and execute one gasless operation. Resolves once the bond settles. Validation runs BEFORE any
     * gas is spent; only a fully-valid, in-scope, correctly-signed operation reaches the commit transaction.
     */
    async relay( request: RelayRequest ): Promise<GaslessRelayResult>
    {
        if(  request.chain_id !== this.#config.chain_id  )  throw new RelayRejected( `Wrong chain ${ request.chain_id }; relayer serves ${ this.#config.chain_id }.` );

        const intent          =  deserialize_intent( request.intent );
        const execution_data  =  deserialize_execution_data( request.execution_data );

        this.#assert_intent_addresses( intent );
        this.#assert_protocol_in_scope( execution_data );
        this.#assert_deadline( intent );
        await this.#assert_valid_signature( request, intent );
        await this.#assert_affordable_gas();

        // ── Commit: runs the delegate as the user's EOA, staking the user's own tokens and paying this relayer its fee. ──
        const create_tx_hash  =  await this.#submit_via_7702( request, "create_bond_from_user_stake", [ intent, request.gasless_type_hash, request.action_struct_hash, request.signature ] );

        // Persist BEFORE waiting: from here the user's stake is locked on-chain, so a crash must leave a resumable record.
        this.#store.put( intent.commitment_hash, { request, create_tx_hash, committed_at: Date.now() } );

        // ── Wait the reveal delay, then execute. ──
        const execute_tx_hash  =  await this.#wait_and_execute( request, intent, execution_data );

        const status  =  await this.#settled_status( intent );
        this.#store.remove( intent.commitment_hash );
        return { status, commitment_hash: intent.commitment_hash, create_tx_hash, execute_tx_hash };
    }

    /**
     * Finish any bonds that were committed but not executed before a previous process exited — so the user's locked stake is
     * always carried through to execution rather than left to expire and be liquidated. Call once at startup.
     */
    async resume_pending(): Promise<void>
    {
        const pending  =  this.#store.pending();
        if(  pending.length === 0  )  return;

        console.warn( "Resuming %d committed bond(s) left in flight by a previous run.", pending.length );

        for(  const entry of pending  )
        {
            const intent  =  deserialize_intent( entry.request.intent );
            try
            {
                // Only ACTIVE bonds still need executing; anything already settled (executed/reverted/liquidated) is just cleared.
                const info  =  await this.#bond_info( intent );
                if(  info.status === BOND_STATUS_ACTIVE  )
                {
                    await this.#wait_and_execute( entry.request, intent, deserialize_execution_data( entry.request.execution_data ) );
                }
                this.#store.remove( intent.commitment_hash );
            }
            catch( error )
            {
                console.error( "Could not resume bond %s; leaving it persisted to retry on the next restart.", intent.commitment_hash, error );
            }
        }
    }

    async #wait_and_execute( request: RelayRequest, intent: GaslessIntent, execution_data: ExecutionData ): Promise<Hex>
    {
        await this.#wait_for_reveal( intent );
        return await this.#submit_via_7702( request, "execute_bond_from_user", [ intent, request.gasless_type_hash, request.action_struct_hash, request.signature, execution_data ] );
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

    async #submit_via_7702( request: RelayRequest, function_name: "create_bond_from_user_stake" | "execute_bond_from_user", args: readonly unknown[] ): Promise<Hex>
    {
        // The tx `to` is the user's own EOA — now running the delegate's code via the 7702 authorization. The relayer attaches
        // no value: native stake/fundings are paid from the EOA's own balance by the delegate (`{ value: ... }`). The
        // authorization is attached only when present; a `null` authorization means the EOA is already delegated (e.g. the
        // commit applied it, so the execute needs no re-delegation), so the call dispatches to the existing delegate code.
        const params  =  {
            account:      this.#account,
            chain:        null,
            address:      request.user,
            abi:          SAFESWAP_RELAYER_DELEGATE_ABI,
            functionName: function_name,
            args,
            ...( request.authorization === null ? {} : { authorizationList: [ request.authorization ] } ),
        };

        const hash     =  await this.#wallet_client.writeContract( params as Parameters<WalletClient["writeContract"]>[0] );
        const receipt  =  await this.#public_client.waitForTransactionReceipt({ hash });

        // `waitForTransactionReceipt` does NOT throw on a reverted tx, so check explicitly — otherwise a reverted commit would
        // be treated as success and persist a phantom bond that `resume_pending` retries forever. (A BondRoute *protocol*
        // revert does not revert this tx; it settles with a non-EXECUTED status, surfaced by `#settled_status`.)
        if(  receipt.status !== "success"  )  throw new Error( `${ function_name } transaction ${ hash } reverted on-chain.` );

        return hash;
    }

    async #wait_for_reveal( intent: GaslessIntent ): Promise<void>
    {
        const info  =  await this.#bond_info( intent );
        const target_block      =  info.creation_block + BigInt( this.#config.reveal_delay_blocks );
        const target_timestamp  =  info.creation_time  + BigInt( this.#config.reveal_delay_seconds );

        for( ; ; )
        {
            const block  =  await this.#public_client.getBlock();
            if(  block.number >= target_block  &&  block.timestamp >= target_timestamp  )  return;
            await new Promise(( resolve ) => setTimeout( resolve, 1_500 ));
        }
    }

    async #settled_status( intent: GaslessIntent ): Promise<GaslessRelayResult["status"]>
    {
        const info  =  await this.#bond_info( intent );
        return BOND_STATUS[ info.status ] ?? "invalid_bond";
    }

    async #bond_info( intent: GaslessIntent ): Promise<{ creation_time: bigint, creation_block: bigint, status: number }>
    {
        const info  =  await this.#public_client.readContract({
            address:      this.#bondroute_address,
            abi:          BONDROUTE_BOND_INFO_ABI,
            functionName: "__OFF_CHAIN__get_bond_info",
            args:         [ intent.commitment_hash, intent.stake ],
        });
        return { creation_time: info.creation_time, creation_block: info.creation_block, status: Number( info.status ) };
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

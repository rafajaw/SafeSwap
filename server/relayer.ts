// SPDX-License-Identifier: MIT
//
// SafeSwap gasless relayer — the server-side half of the EIP-7702 flow. The user signs only (off-chain): an `ExecuteBondAs`
// envelope and a 7702 authorization delegating their EOA to the SafeSwap relayer delegate. This relayer validates that
// signed intent, fronts a small stake from its OWN inventory to commit the bond, waits the execution delay, tops up the
// user's funding-token balance if needed, and finally submits the type-0x04 transaction that runs the delegate code AS the
// user's EOA (approve fundings → BondRoute.execute_bond_as). The relayer pays all gas; all on-chain value flows to the user.
//
// See FRONTEND_SPEC_DECISIONS.md "Gasless execution via EIP-7702" for the binding protocol this implements.

import {
    createPublicClient,
    createWalletClient,
    http,
    parseAbi,
    type Account,
    type Address,
    type Hex,
    type PublicClient,
    type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { BONDROUTE_ADDRESS, NATIVE_TOKEN, type Bond, type BondRoute as BondRouteType, type ExecutionData } from "@bondroute/sdk";
import { BondRoute } from "@bondroute/sdk";
import {
    SAFESWAP_RELAYER_DELEGATE_ABI,
    deserialize_execution_data,
    type GaslessRelayResult,
    type RelayRequest,
} from "@safeswap/sdk";
import { load_config, MAX_RELAY_COST_USD, type RelayerConfig } from "./config.ts";

const ERC20_ABI  =  parseAbi([
    "function balanceOf(address account) view returns (uint256)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function transfer(address to, uint256 amount) returns (bool)",
]);

const BONDROUTE_CREATE_ABI  =  parseAbi([
    "function create_bond(bytes32 commitment_hash, (address token, uint256 amount) stake) external payable",
]);

const INFINITE_TOKEN_AMOUNT  =  ( 2n ** 256n ) - 1n;

// *NOTE*  -  The commit (`create_bond`) is estimated live (`estimateContractGas`) at guard time. These statics are fallbacks:
//            ESTIMATED_CREATE_GAS only when live estimation can't run (e.g. before the relayer's one-time stake approval lands),
//            ESTIMATED_EXECUTE_GAS always — the execute leg runs the 7702 delegate AS the user's EOA and cannot be simulated
//            until the bond exists and its delay has elapsed. Both intentionally overstate so the guard never under-counts.
const ESTIMATED_CREATE_GAS   =  350_000n;
const ESTIMATED_EXECUTE_GAS  =  450_000n;

/** Safety markup applied to the summed gas estimate before the USD ceiling check. */
const GAS_MARKUP_PERCENT  =  10n;

/** A relay rejection the caller should surface as a 4xx (bad/forbidden request), distinct from an internal failure. */
export class RelayRejected extends Error {
    constructor( message: string )
    {
        super( message );
        this.name  =  "RelayRejected";
    }
}


export class Relayer {

    readonly #config:        RelayerConfig;
    readonly #account:       Account;
    readonly #public_client: PublicClient;
    readonly #wallet_client: WalletClient;
    readonly #bond_route:    BondRouteType;
    readonly #bondroute_address: Address;
    readonly #allowed_protocols: Set<string>;

    private constructor( config: RelayerConfig, account: Account, public_client: PublicClient, wallet_client: WalletClient, bond_route: BondRouteType )
    {
        this.#config            =  config;
        this.#account           =  account;
        this.#public_client     =  public_client;
        this.#wallet_client     =  wallet_client;
        this.#bond_route        =  bond_route;
        this.#bondroute_address  =  config.bondroute_address ?? BONDROUTE_ADDRESS;
        this.#allowed_protocols  =  new Set([ config.router_address.toLowerCase(), config.nft_address.toLowerCase() ]);
    }

    static async init(): Promise<Relayer>
    {
        const config         =  load_config();
        const account        =  privateKeyToAccount( config.relayer_private_key );
        const public_client  =  createPublicClient({ transport: http( config.rpc_url ) }) as PublicClient;
        const wallet_client  =  createWalletClient({ account, transport: http( config.rpc_url ) });

        const bond_route  =  await BondRoute.init({
            public_client,
            wallet_client,
            account,
            bondroute_address: config.bondroute_address,
            on_pending_bond:   () => { /* the relayer drives each bond inline within one request — no recovery pass. */ },
            storage:           "memory",
        });

        return new Relayer( config, account, public_client, wallet_client, bond_route );
    }

    get config(): RelayerConfig
    {
        return this.#config;
    }

    /**
     * Validate, commit, wait, top-up, and execute one gasless operation. Resolves once the bond settles. Validation runs
     * BEFORE any value is spent; only a fully-valid, affordable, in-scope operation reaches the commit step.
     */
    async relay( request: RelayRequest ): Promise<GaslessRelayResult>
    {
        if(  request.chain_id !== this.#config.chain_id  )  throw new RelayRejected( `Wrong chain ${ request.chain_id }; relayer serves ${ this.#config.chain_id }.` );

        const execution_data  =  deserialize_execution_data( request.execution_data );
        const bond            =  this.#bond_route.bond( execution_data );

        this.#assert_no_native_fundings( execution_data );
        this.#assert_protocol_in_scope( execution_data );
        await this.#assert_valid_signature( bond, request );
        await this.#assert_affordable_gas( bond );

        // ── Commit: the relayer fronts the stake from its own inventory (never the user's funds). ──
        await this.#ensure_stake_ready( execution_data.stake );
        await bond.create();

        // ── Wait the execution delay, then make the user's EOA solvent for the funding pull the delegate performs. ──
        await bond.wait_until_executable();
        await this.#top_up_user_fundings( request.user, execution_data.fundings );

        // ── Execute: the 7702 type-0x04 tx runs the delegate AS the user's EOA. ──
        const execute_tx_hash  =  await this.#execute_via_7702( request, execution_data );

        await bond.refresh();
        return {
            status:          bond.status,
            commitment_hash: bond.commitment_hash,
            create_tx_hash:  bond.create_tx_hash,
            execute_tx_hash,
            revert_output:   bond.revert_output === "0x" ? undefined : bond.revert_output,
        };
    }


    // ━━━━  VALIDATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    #assert_no_native_fundings( execution_data: ExecutionData ): void
    {
        const has_native  =  execution_data.fundings.some(( funding ) => funding.token.toLowerCase() === NATIVE_TOKEN.toLowerCase() );
        if(  has_native  )  throw new RelayRejected( "Native-input operations cannot be relayed; the relayer cannot attach the user's native value." );
    }

    #assert_protocol_in_scope( execution_data: ExecutionData ): void
    {
        if(  this.#allowed_protocols.has( execution_data.protocol.toLowerCase() ) === false  )
        {
            throw new RelayRejected( `Protocol ${ execution_data.protocol } is not the SafeSwap Router or NFT; relaying is refused.` );
        }
    }

    async #assert_valid_signature( bond: Bond, request: RelayRequest ): Promise<void>
    {
        // The bond's `ExecuteBondAs` typed data is independent of who created it; verify the user signed exactly this execution.
        const typed_data  =  await bond.build_execution_typed_data();

        const valid  =  await this.#public_client.verifyTypedData({
            address:     request.user,
            domain:      typed_data.domain,
            types:       typed_data.types,
            primaryType: typed_data.primaryType,
            message:     typed_data.message,
            signature:   request.signature,
        } as Parameters<PublicClient["verifyTypedData"]>[0] );

        if(  valid === false  )  throw new RelayRejected( "ExecuteBondAs signature does not match the supplied user and execution data." );
    }

    async #assert_affordable_gas( bond: Bond ): Promise<void>
    {
        // Fail-closed: without a native USD price the ceiling is unverifiable, so refuse rather than sponsor blind.
        if(  this.#config.native_usd_price === undefined  )
        {
            throw new RelayRejected( "Relayer gas-cost ceiling is unverifiable (RELAYER_NATIVE_USD_PRICE unset); refusing to sponsor." );
        }

        const create_gas   =  await this.#estimate_create_gas( bond );
        const total_gas    =  ( ( create_gas + ESTIMATED_EXECUTE_GAS ) * ( 100n + GAS_MARKUP_PERCENT ) ) / 100n;
        const gas_price    =  await this.#public_client.getGasPrice();
        const cost_native  =  Number( total_gas * gas_price ) / 1e18;
        const cost_usd     =  cost_native * this.#config.native_usd_price;

        if(  cost_usd > MAX_RELAY_COST_USD  )  throw new RelayRejected( `Estimated gas cost $${ cost_usd.toFixed(4) } exceeds the $${ MAX_RELAY_COST_USD } relay ceiling.` );
    }

    // The commit is fully determined pre-commit, so estimate it live. Falls back to the static ceiling if estimation reverts
    // (e.g. before the relayer's one-time stake approval lands) — the safe, higher-or-equal direction for an under-count guard.
    async #estimate_create_gas( bond: Bond ): Promise<bigint>
    {
        try
        {
            return await this.#public_client.estimateContractGas({
                account:      this.#account,
                address:      this.#bondroute_address,
                abi:          BONDROUTE_CREATE_ABI,
                functionName: "create_bond",
                args:         [ bond.commitment_hash, bond.execution_data.stake ],
                value:        bond.get_native_value_for_create(),
            } as unknown as Parameters<PublicClient["estimateContractGas"]>[0] );
        }
        catch( error )
        {
            console.warn( "create_bond gas estimation failed; using the static create ceiling.", error );
            return ESTIMATED_CREATE_GAS;
        }
    }


    // ━━━━  COMMIT / EXECUTE HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    async #ensure_stake_ready( stake: ExecutionData["stake"] ): Promise<void>
    {
        if(  stake.token.toLowerCase() === NATIVE_TOKEN.toLowerCase()  )
        {
            const balance  =  await this.#public_client.getBalance({ address: this.#account.address });
            if(  balance < stake.amount  )  throw new RelayRejected( `Relayer holds insufficient native stake (${ balance } < ${ stake.amount }).` );
            return;
        }

        const balance  =  await this.#read_erc20( stake.token, "balanceOf", [ this.#account.address ] );
        if(  balance < stake.amount  )  throw new RelayRejected( `Relayer holds insufficient ${ stake.token } stake inventory (${ balance } < ${ stake.amount }).` );

        const allowance  =  await this.#read_erc20( stake.token, "allowance", [ this.#account.address, this.#bondroute_address ] );
        if(  allowance < stake.amount  )  await this.#approve_max( stake.token );
    }

    async #top_up_user_fundings( user: Address, fundings: ExecutionData["fundings"] ): Promise<void>
    {
        for(  const funding of fundings  )
        {
            const balance  =  await this.#read_erc20( funding.token, "balanceOf", [ user ] );
            if(  balance >= funding.amount  )  continue;

            const shortfall  =  funding.amount - balance;
            const hash       =  await this.#wallet_client.writeContract({
                account:      this.#account,
                chain:        null,
                address:      funding.token,
                abi:          ERC20_ABI,
                functionName: "transfer",
                args:         [ user, shortfall ],
            });
            await this.#public_client.waitForTransactionReceipt({ hash });
        }
    }

    async #execute_via_7702( request: RelayRequest, execution_data: ExecutionData ): Promise<Hex>
    {
        // The tx `to` is the user's own EOA — now running the delegate's code via the supplied 7702 authorization.
        const hash  =  await this.#wallet_client.writeContract({
            account:           this.#account,
            chain:             null,
            address:           request.user,
            abi:               SAFESWAP_RELAYER_DELEGATE_ABI,
            functionName:      "approve_fundings_and_execute_bond_as_user",
            args:              [ execution_data, request.user, request.signature, request.is_eip1271 ],
            authorizationList: [ request.authorization ],
        } as Parameters<WalletClient["writeContract"]>[0] );

        await this.#public_client.waitForTransactionReceipt({ hash });
        return hash;
    }

    async #approve_max( token: Address ): Promise<void>
    {
        const hash  =  await this.#wallet_client.writeContract({
            account:      this.#account,
            chain:        null,
            address:      token,
            abi:          ERC20_ABI,
            functionName: "approve",
            args:         [ this.#bondroute_address, INFINITE_TOKEN_AMOUNT ],
        });
        await this.#public_client.waitForTransactionReceipt({ hash });
    }

    async #read_erc20( token: Address, fn: "balanceOf" | "allowance", args: readonly Address[] ): Promise<bigint>
    {
        return await this.#public_client.readContract({ address: token, abi: ERC20_ABI, functionName: fn, args }) as bigint;
    }
}

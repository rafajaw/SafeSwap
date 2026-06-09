// SPDX-License-Identifier: MIT

import { describe, expect, test } from "bun:test";
import { decodeFunctionData, encodeErrorResult, encodeEventTopics, hashTypedData, keccak256, toBytes, type Address, type Hex } from "viem";
import { BONDROUTE_ADDRESS, NATIVE_TOKEN } from "@bondroute/sdk";
import {
    SAFESWAP_ABI,
    SAFESWAP_NFT_ABI,
    SAFESWAP_ROUTER_ABI,
    SafeSwap,
    SafeSwapSwaps,
    SafeSwapPositions,
    compute_gasless_type_hash,
    explain_safeswap_revert,
    parse_safeswap_revert,
} from "../SafeSwap";

const USER        =  "0x1111111111111111111111111111111111111111" as const;
const ROUTER      =  "0x2222222222222222222222222222222222222222" as const;
const NFT         =  "0x7777777777777777777777777777777777777777" as const;
const BONDROUTE   =  "0x3333333333333333333333333333333333333333" as const;
const TOKEN_IN    =  "0x4444444444444444444444444444444444444444" as const;
const TOKEN_OUT   =  "0x5555555555555555555555555555555555555555" as const;
const TOKEN_OTHER =  "0x6666666666666666666666666666666666666666" as const;

const POOL_INFO  =  { base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 } as const;
const DESCRIPTOR =  "0x8888888888888888888888888888888888888888" as const;

const SIGNING_DOMAIN = {
    name: "BondRoute", version: "1", chainId: 1n, verifyingContract: BONDROUTE,
} as const;
let tamper_signing_values  =  false;

const SIGNING_VECTORS = {
    swap_exact_input: {
        action_type: "ExactInputSwap", action_field: "sS__SWAP__Ss",
        fields: [
            [ "Pay", "string", "= 1 USDC" ],
            [ "Receive", "string", ">= 0.4 WETH" ],
            [ "Pool", "string", "0.3% base fee | 50% rebate | tick spacing 60" ],
            [ "Warning", "string", ">>  Check protocol and token addresses  <<" ],
            [ "WETH", "address", TOKEN_OUT ],
        ],
    },
    swap_exact_output: {
        action_type: "ExactOutputSwap", action_field: "sS__SWAP__Ss",
        fields: [
            [ "Pay", "string", "<= 1.1 USDC" ],
            [ "Receive", "string", "= 0.4 WETH" ],
            [ "Pool", "string", "0.3% base fee | 50% rebate | tick spacing 60" ],
            [ "Warning", "string", ">>  Check protocol and token addresses  <<" ],
            [ "WETH", "address", TOKEN_OUT ],
        ],
    },
    create_position: {
        action_type: "CreatePosition", action_field: "sS__CREATE_POSITION__Ss",
        fields: [
            [ "Deposit", "string", "<= 1 WETH + 3,000 USDC" ],
            [ "Minimum", "string", ">= 0.99 WETH + 2,970 USDC" ],
            [ "Liquidity", "string", "1000000000000000000" ],
            [ "Range", "string", "2,850 ~ 3,150 USDC/WETH" ],
            [ "Price", "string", "3,000 USDC/WETH" ],
            [ "Pool", "string", "0.3% base fee | 50% rebate | tick spacing 60" ],
            [ "Warning", "string", ">>  Check protocol and token addresses  <<" ],
            [ "WETH", "address", TOKEN_OUT ],
            [ "USDC", "address", TOKEN_IN ],
        ],
    },
    add_liquidity: {
        action_type: "AddLiquidity", action_field: "sS__ADD_LIQUIDITY__Ss",
        fields: [
            [ "Position", "string", "LP #8" ],
            [ "Deposit", "string", "<= 0.5 WETH + 1,500 USDC" ],
            [ "Minimum", "string", ">= 0.49 WETH + 1,485 USDC" ],
            [ "Liquidity", "string", "500000000000000000" ],
            [ "Pool", "string", "0.3% base fee | 50% rebate | tick spacing 60" ],
            [ "Warning", "string", ">>  Check protocol and token addresses  <<" ],
            [ "WETH", "address", TOKEN_OUT ],
            [ "USDC", "address", TOKEN_IN ],
        ],
    },
    remove_liquidity: {
        action_type: "RemoveLiquidity", action_field: "sS__REMOVE_LIQUIDITY__Ss",
        fields: [
            [ "Position", "string", "LP #8" ],
            [ "Burn", "string", "500000000000000000 liquidity" ],
            [ "Receive", "string", ">= 0.49 WETH + 1,485 USDC" ],
            [ "Pool", "string", "0.3% base fee | 50% rebate | tick spacing 60" ],
            [ "Warning", "string", ">>  Check protocol and token addresses  <<" ],
            [ "WETH", "address", TOKEN_OUT ],
            [ "USDC", "address", TOKEN_IN ],
        ],
    },
} as const;

function signing_vector_for_call( protocol: Address, call: Hex )
{
    const decoded  =  decodeFunctionData({ abi: protocol === ROUTER ? SAFESWAP_ROUTER_ABI : SAFESWAP_NFT_ABI, data: call });
    const kind     =  decoded.functionName.replace( /^bonded_/, "" );
    return SIGNING_VECTORS[ kind as keyof typeof SIGNING_VECTORS ];
}

function signing_response( execution_data: any )
{
    const vector  =  signing_vector_for_call( execution_data.protocol, execution_data.call );
    const action_fields  =  vector.fields.map(( [ name, type ] ) => ({ name, type }));
    const types  =  {
        ExecuteBondAs: [
            { name: "fundings", type: "TokenAmount[]" },
            { name: "stake", type: "TokenAmount" },
            { name: "salt", type: "uint256" },
            { name: "protocol", type: "address" },
            { name: vector.action_field, type: vector.action_type },
        ],
        [ vector.action_type ]: action_fields,
        TokenAmount: [ { name: "token", type: "address" }, { name: "amount", type: "uint256" } ],
    };
    const action  =  Object.fromEntries( vector.fields.map(( [ name, , value ] ) => [ name, value ]) );
    const message = {
        fundings: execution_data.fundings, stake: execution_data.stake, salt: execution_data.salt,
        protocol: execution_data.protocol, [ vector.action_field ]: action,
    };
    const type_string  =  `ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,${ vector.action_type } ${ vector.action_field })${ vector.action_type }(${ vector.fields.map(( [ name, type ] ) => `${ type } ${ name }`).join( "," ) })TokenAmount(address token,uint256 amount)`;
    return [ hashTypedData({ domain: SIGNING_DOMAIN, primaryType: "ExecuteBondAs", types, message } as any), keccak256( toBytes( type_string ) ), type_string, SIGNING_DOMAIN ] as const;
}

function make_sdk_clients( balances?: Record<string, bigint> )
{
    const quote_calls: Array<{ address: Address, functionName: string, args: readonly unknown[] }> = [];
    const view_calls: Array<{ address: Address, functionName: string, args: readonly unknown[] }> = [];
    const write_calls: Array<{ address: Address, functionName: string, args: readonly unknown[] }> = [];
    const signing_requests: any[] = [];

    const public_client = {
        getChainId: async () => 1,
        getBalance: async () => balances?.[ NATIVE_TOKEN.toLowerCase() ] ?? 0n,
        readContract: async ( request: { address: Address, functionName?: string, args?: readonly unknown[] } ) => {
            const fn    =  request.functionName ?? "";
            const args  =  request.args ?? [];

            if(  fn === "balanceOf"  )  return balances?.[ request.address.toLowerCase() ] ?? 0n;
            if(  fn === "decimals"  )   return request.address === TOKEN_IN  ?  6  :  18;
            if(  fn === "symbol"  )     return request.address === TOKEN_IN  ?  "USDC"  :  "WETH";
            if(  fn === "SigningDescriptor"  )  return DESCRIPTOR;
            if(  fn === "__OFF_CHAIN__get_signing_info"  )  return signing_response( args[0] );
            if(  fn === "build_router_signing_values" || fn === "build_nft_signing_values"  )
            {
                const call    =  args[ args.length - 1 ] as Hex;
                const vector  =  signing_vector_for_call( fn === "build_router_signing_values" ? ROUTER : NFT, call );
                const display_values: string[]  =  vector.fields.filter(( [ , type ] ) => type === "string" ).map(( [ , , value ] ) => value);
                if(  tamper_signing_values  )  display_values[0] = "= tampered";
                return [
                    display_values,
                    vector.fields.filter(( [ , type ] ) => type === "address" ).map(( [ , , value ] ) => value),
                ];
            }

            if(  fn === "BondRoute_quote_call"  )
            {
                quote_calls.push({ address: request.address, functionName: fn, args });
                return [
                    { token: args[ 1 ] as Address, amount: 10n },    // min_stake (echoes preferred_stake)
                    args[ 2 ],                                        // min_fundings (echoes preferred_fundings)
                    3n, 2n, 3600n,
                    { min: 0n, max: 0n },
                    { min: 0n, max: 0n },
                ];
            }

            view_calls.push({ address: request.address, functionName: fn, args });

            if(  fn === "__OFF_CHAIN__quote_swap_exact_input"  )   return [ 990n, 3050, 12n ];
            if(  fn === "__OFF_CHAIN__quote_swap_exact_output"  )  return [ 1010n, 3050, 12n ];
            if(  fn === "__OFF_CHAIN__get_pool_id"  )             return "0xabc0000000000000000000000000000000000000000000000000000000000def";
            if(  fn === "get_hook_address"  )                     return TOKEN_OTHER;
            if(  fn === "get_lp_position"  )
            {
                return {
                    hook:           TOKEN_OTHER,
                    token0:         TOKEN_IN,
                    token1:         TOKEN_OUT,
                    base_fee_bps:   30,
                    rebate_percent: 50,
                    tick_spacing:   60,
                    tick_lower:     -60,
                    tick_upper:     60,
                };
            }
            if(  fn === "get_position_info"  )  return [ 100n, 7n, 9n ];

            throw new Error( `unexpected readContract: ${ fn }` );
        },
    };
    const wallet_client = {
        writeContract: async ( request: { address: Address, functionName?: string, args?: readonly unknown[] } ) => {
            write_calls.push({
                address: request.address,
                functionName: request.functionName ?? "",
                args: request.args ?? [],
            });
            return `0x${ "22".repeat( 32 ) }` as Hex;
        },
        signTypedData: async ( request: unknown ) => {
            signing_requests.push( request );
            return `0x${ "11".repeat( 65 ) }` as Hex;
        },
    };
    return { public_client, wallet_client, quote_calls, view_calls, write_calls, signing_requests };
}

async function make_sdk( balances?: Record<string, bigint> )
{
    const clients  =  make_sdk_clients( balances );
    const safeswap  =  await SafeSwap.init({
        public_client: clients.public_client as any,
        wallet_client: clients.wallet_client as any,
        account: USER,
        storage: "memory",
        router_address: ROUTER,
        nft_address: NFT,
        bondroute_address: BONDROUTE,
        on_pending_bond: () => {},
    });
    return { safeswap, ...clients };
}


describe( "SafeSwap.init", () => {

    test( "exposes swaps and positions surfaces bound to the configured addresses", async () => {
        const { safeswap } = await make_sdk();

        expect( safeswap.swaps ).toBeInstanceOf( SafeSwapSwaps );
        expect( safeswap.positions ).toBeInstanceOf( SafeSwapPositions );
        expect( safeswap.swaps.router_address ).toBe( ROUTER );
        expect( safeswap.positions.nft_address ).toBe( NFT );
    });

    test( "throws when the router address is left unconfigured", async () => {
        const { public_client, wallet_client } = make_sdk_clients();
        await expect( SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            nft_address: NFT,
            on_pending_bond: () => {},
        })).rejects.toThrow( "router_address is not configured." );
    });

    test( "defaults to the canonical BondRoute address when not overridden", async () => {
        const { public_client, wallet_client } = make_sdk_clients();
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            router_address: ROUTER,
            nft_address: NFT,
            on_pending_bond: () => {},
        });

        const bond = await safeswap.swaps.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 100n },
            output: { token: TOKEN_OUT, minimum_amount: 1n },
            pool_info: POOL_INFO,
        });

        expect( bond.bondroute ).toBe( BONDROUTE_ADDRESS );
    });
});


describe( "SafeSwapSwaps", () => {

    test( "prepares an exact-input swap bonded to the router with a single funding", async () => {
        const { safeswap, quote_calls } = await make_sdk();

        const op = await safeswap.swaps.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 1_000_000n },
            output: { token: TOKEN_OUT, minimum_amount: 1n },
            pool_info: POOL_INFO,
        });

        expect( op.kind ).toBe( "swap_exact_input" );
        expect( op.execution_data.protocol ).toBe( ROUTER );
        expect( quote_calls[0]?.address ).toBe( ROUTER );
        expect( op.execution_data.fundings ).toEqual( [{ token: TOKEN_IN, amount: 1_000_000n }] );
        expect( await op.render_description() ).toBe( "Swap exactly 1 USDC for at least 0.000000000000000001 WETH." );
    });

    test( "prepares an exact-output swap funding the maximum input", async () => {
        const { safeswap } = await make_sdk();

        const op = await safeswap.swaps.prepare_swap_exact_output({
            input: { token: TOKEN_IN, maximum_amount: 1_100_000n },
            output: { token: TOKEN_OUT, exact_amount: 400_000_000_000_000_000n },
            pool_info: POOL_INFO,
        });

        expect( op.kind ).toBe( "swap_exact_output" );
        expect( op.execution_data.fundings ).toEqual( [{ token: TOKEN_IN, amount: 1_100_000n }] );
        expect( await op.render_description() ).toBe( "Swap up to 1.1 USDC for exactly 0.4 WETH." );
    });

    test( "quotes exact input against the router's off-chain quoter", async () => {
        const { safeswap, view_calls } = await make_sdk();

        const quote = await safeswap.swaps.quote_swap_exact_input({
            token_in: TOKEN_IN, token_out: TOKEN_OUT, pool_info: POOL_INFO, amount_in: 1_000_000n,
        });

        expect( quote ).toEqual({ expected_net_output: 990n, total_fee_pips: 3050, movement_bps: 12n });
        expect( view_calls[0]?.functionName ).toBe( "__OFF_CHAIN__quote_swap_exact_input" );
        expect( view_calls[0]?.address ).toBe( ROUTER );
    });

    test( "quotes exact output against the router's off-chain quoter", async () => {
        const { safeswap } = await make_sdk();

        const quote = await safeswap.swaps.quote_swap_exact_output({
            token_in: TOKEN_IN, token_out: TOKEN_OUT, pool_info: POOL_INFO, exact_output_amount: 1_000n,
        });

        expect( quote ).toEqual({ required_input: 1010n, total_fee_pips: 3050, movement_bps: 12n });
    });

    test( "resolves a pool id and a registered hook", async () => {
        const { safeswap, view_calls } = await make_sdk();

        const pool_id = await safeswap.swaps.get_pool_id( TOKEN_OUT, TOKEN_IN, POOL_INFO );
        const hook    = await safeswap.swaps.get_hook_address( 30, 50 );

        expect( pool_id.startsWith( "0xabc" ) ).toBe( true );
        expect( hook ).toBe( TOKEN_OTHER );
        expect( view_calls.map( ( c ) => c.functionName ) ).toEqual( [ "__OFF_CHAIN__get_pool_id", "get_hook_address" ] );
    });

    test( "rejects same-token swaps before quoting", async () => {
        const { safeswap, quote_calls } = await make_sdk();

        await expect( safeswap.swaps.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 100n },
            output: { token: TOKEN_IN, minimum_amount: 1n },
            pool_info: POOL_INFO,
        })).rejects.toThrow( "swap tokens must be different." );

        expect( quote_calls.length ).toBe( 0 );
    });

    test( "rejects a capture share that is not a 10% step before quoting", async () => {
        const { safeswap, quote_calls } = await make_sdk();

        await expect( safeswap.swaps.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 100n },
            output: { token: TOKEN_OUT, minimum_amount: 1n },
            pool_info: { base_fee_bps: 30, rebate_percent: 55, tick_spacing: 60 },
        })).rejects.toThrow( "pool_info.rebate_percent must be a multiple of 10 between 0 and 90." );

        expect( quote_calls.length ).toBe( 0 );
    });

    test( "rejects an out-of-range base fee before quoting", async () => {
        const { safeswap } = await make_sdk();

        await expect( safeswap.swaps.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 100n },
            output: { token: TOKEN_OUT, minimum_amount: 1n },
            pool_info: { base_fee_bps: 1000, rebate_percent: 50, tick_spacing: 60 },
        })).rejects.toThrow( "pool_info.base_fee_bps must be a whole number of basis points between 0 and 999." );
    });

    test( "propagates token metadata errors while rendering descriptions", async () => {
        const clients = make_sdk_clients();
        const failing_public_client = {
            ...clients.public_client,
            readContract: async ( request: { functionName?: string } ) => {
                if(  request.functionName === "decimals"  )  throw new Error( "metadata unavailable" );
                return await clients.public_client.readContract( request as any );
            },
        };
        const safeswap = await SafeSwap.init({
            public_client: failing_public_client as any,
            wallet_client: clients.wallet_client as any,
            account: USER,
            storage: "memory",
            router_address: ROUTER,
            nft_address: NFT,
            on_pending_bond: () => {},
        });

        const op = await safeswap.swaps.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 1_000_000n },
            output: { token: TOKEN_OUT, minimum_amount: 1n },
            pool_info: POOL_INFO,
        });

        await expect( op.render_description() ).rejects.toThrow( "metadata unavailable" );
    });
});


describe( "SafeSwapPositions", () => {

    test( "auto-quotes both pool tokens when no stake preference is given for create", async () => {
        const { safeswap, quote_calls } = await make_sdk();

        await safeswap.positions.prepare_create_position({
            pool_info: POOL_INFO,
            sqrt_price_lower_x96: 1n, sqrt_price_upper_x96: 79228162514264337593543950336n,
            liquidity: 1n,
            sqrt_price_x96: 79228162514264337593543950336n,
            a: { token: TOKEN_OUT, amount: 200n, minimum_deposited: 0n },
            b: { token: TOKEN_IN, amount: 100n, minimum_deposited: 0n },
        });

        expect( quote_calls.length ).toBe( 2 );
        expect( quote_calls[0]?.args[1] ).toBe( TOKEN_IN );    // token0 by address order
        expect( quote_calls[1]?.args[1] ).toBe( TOKEN_OUT );   // token1 by address order
        expect( quote_calls.every( ( c ) => c.address === NFT ) ).toBe( true );
    });

    test( "passes an explicit stake preference through for create with a single quote", async () => {
        const { safeswap, quote_calls } = await make_sdk();

        const op = await safeswap.positions.prepare_create_position({
            pool_info: POOL_INFO,
            sqrt_price_lower_x96: 1n, sqrt_price_upper_x96: 79228162514264337593543950336n,
            liquidity: 1n,
            sqrt_price_x96: 79228162514264337593543950336n,
            a: { token: TOKEN_IN, amount: 100n, minimum_deposited: 0n },
            b: { token: TOKEN_OUT, amount: 200n, minimum_deposited: 0n },
            preferred_stake_token: TOKEN_OUT,
        });

        expect( op.kind ).toBe( "create_position" );
        expect( quote_calls.length ).toBe( 1 );
        expect( quote_calls[0]?.args[1] ).toBe( TOKEN_OUT );
    });

    test( "auto-selects the only affordable stake token for remove liquidity", async () => {
        const { safeswap, quote_calls } = await make_sdk({
            [ TOKEN_IN.toLowerCase() ]: 0n,
            [ TOKEN_OUT.toLowerCase() ]: 10n,
        });

        const op = await safeswap.positions.prepare_remove_liquidity({
            token_id: 1n,
            liquidity: 1n,
            a: { token: TOKEN_OUT, minimum_received: 0n },
            b: { token: TOKEN_IN, minimum_received: 0n },
        });

        expect( op.execution_data.stake.token ).toBe( TOKEN_OUT );
        expect( quote_calls[0]?.args[1] ).toBe( TOKEN_IN );
        expect( quote_calls[1]?.args[1] ).toBe( TOKEN_OUT );
        expect( op.execution_data.fundings ).toEqual( [] );
    });

    test( "collects fees directly through the NFT contract", async () => {
        const { safeswap, quote_calls, write_calls } = await make_sdk();

        const transaction_hash  =  await safeswap.positions.collect_fees({
            token_id: 1n,
            a: { token: TOKEN_OUT, minimum_received: 0n },
            b: { token: NATIVE_TOKEN, minimum_received: 0n },
        });

        expect( transaction_hash ).toBe( `0x${ "22".repeat( 32 ) }` );
        expect( quote_calls.length ).toBe( 0 );
        expect( write_calls ).toEqual( [{
            address: NFT,
            functionName: "collect_fees",
            args: [{
                token_id: 1n,
                minimum_received_a: { token: TOKEN_OUT, amount: 0n },
                minimum_received_b: { token: NATIVE_TOKEN, amount: 0n },
            }],
        }] );
    });

    test( "passes an explicit stake preference through for add liquidity", async () => {
        const { safeswap, quote_calls } = await make_sdk();

        await safeswap.positions.prepare_add_liquidity({
            token_id: 1n,
            liquidity: 1n,
            a: { token: TOKEN_IN, amount: 100n, minimum_deposited: 0n },
            b: { token: TOKEN_OUT, amount: 200n, minimum_deposited: 0n },
            preferred_stake_token: TOKEN_OUT,
        });

        expect( quote_calls.length ).toBe( 1 );
        expect( quote_calls[0]?.args[1] ).toBe( TOKEN_OUT );
    });

    test( "rejects an unexpected stake preference before quoting", async () => {
        const { safeswap, quote_calls } = await make_sdk();

        await expect( safeswap.positions.prepare_add_liquidity({
            token_id: 1n,
            liquidity: 1n,
            a: { token: TOKEN_IN, amount: 100n, minimum_deposited: 0n },
            b: { token: TOKEN_OUT, amount: 200n, minimum_deposited: 0n },
            preferred_stake_token: TOKEN_OTHER,
        })).rejects.toThrow( "preferred_stake_token must be one of the SafeSwap pool tokens." );

        expect( quote_calls.length ).toBe( 0 );
    });

    test( "rejects inverted price bounds for create before quoting", async () => {
        const { safeswap, quote_calls } = await make_sdk();

        await expect( safeswap.positions.prepare_create_position({
            pool_info: POOL_INFO,
            sqrt_price_lower_x96: 2n, sqrt_price_upper_x96: 1n,
            liquidity: 1n,
            sqrt_price_x96: 79228162514264337593543950336n,
            a: { token: TOKEN_IN, amount: 100n, minimum_deposited: 0n },
            b: { token: TOKEN_OUT, amount: 200n, minimum_deposited: 0n },
        })).rejects.toThrow( "sqrt_price_lower_x96 must be less than sqrt_price_upper_x96." );

        expect( quote_calls.length ).toBe( 0 );
    });
});


describe( "SafeSwapPositions getters", () => {

    test( "reads and normalizes immutable position metadata", async () => {
        const { safeswap } = await make_sdk();

        const info = await safeswap.positions.get_lp_position( 1n );

        expect( info ).toEqual({
            hook:           TOKEN_OTHER,
            token0:         TOKEN_IN,
            token1:         TOKEN_OUT,
            base_fee_bps:   30,
            rebate_percent: 50,
            tick_spacing:   60,
            tick_lower:     -60,
            tick_upper:     60,
        });
    });

    test( "reads live position state from the pool manager", async () => {
        const { safeswap } = await make_sdk();

        const state = await safeswap.positions.get_position_state( "0xabc" as Hex, 1n, -60, 60 );

        expect( state ).toEqual({
            liquidity:                     100n,
            fee_growth_inside_0_last_x128: 7n,
            fee_growth_inside_1_last_x128: 9n,
        });
    });

    test( "decodes the minted token id from create-position execution logs", async () => {
        const { safeswap } = await make_sdk();

        const topics = encodeEventTopics({
            abi: SAFESWAP_NFT_ABI,
            eventName: "Transfer",
            args: { from: NATIVE_TOKEN, to: USER, tokenId: 42n },
        });

        const settled_operation = {
            status: "executed",
            execution_logs: [{ address: NFT, data: "0x", topics }],
        } as any;

        expect( safeswap.positions.get_minted_token_id( settled_operation ) ).toBe( 42n );
    });

    test( "returns null for the minted token id of an unsettled operation", async () => {
        const { safeswap } = await make_sdk();
        const active_operation = { status: "active", execution_logs: [] } as any;

        expect( safeswap.positions.get_minted_token_id( active_operation ) ).toBeNull();
    });
});


describe( "REFERENCE_2 signing previews", () => {

    async function prepared_vectors()
    {
        const { safeswap }  =  await make_sdk({
            [ TOKEN_IN.toLowerCase() ]:  1_000_000_000_000n,
            [ TOKEN_OUT.toLowerCase() ]: 10_000_000_000_000_000_000n,
        });

        return [
            await safeswap.swaps.prepare_swap_exact_input({
                input: { token: TOKEN_IN, exact_amount: 1_000_000n },
                output: { token: TOKEN_OUT, minimum_amount: 400_000_000_000_000_000n },
                pool_info: POOL_INFO,
            }),
            await safeswap.swaps.prepare_swap_exact_output({
                input: { token: TOKEN_IN, maximum_amount: 1_100_000n },
                output: { token: TOKEN_OUT, exact_amount: 400_000_000_000_000_000n },
                pool_info: POOL_INFO,
            }),
            await safeswap.positions.prepare_create_position({
                pool_info: POOL_INFO,
                sqrt_price_lower_x96: 1n, sqrt_price_upper_x96: 79228162514264337593543950336n,
                liquidity: 1_000_000_000_000_000_000n,
                sqrt_price_x96: 79228162514264337593543950336n,
                a: { token: TOKEN_IN, amount: 3_000_000_000n, minimum_deposited: 2_970_000_000n },
                b: { token: TOKEN_OUT, amount: 1_000_000_000_000_000_000n, minimum_deposited: 990_000_000_000_000_000n },
                preferred_stake_token: TOKEN_IN,
            }),
            await safeswap.positions.prepare_add_liquidity({
                token_id: 8n, liquidity: 500_000_000_000_000_000n,
                a: { token: TOKEN_IN, amount: 1_500_000_000n, minimum_deposited: 1_485_000_000n },
                b: { token: TOKEN_OUT, amount: 500_000_000_000_000_000n, minimum_deposited: 490_000_000_000_000_000n },
                preferred_stake_token: TOKEN_IN,
            }),
            await safeswap.positions.prepare_remove_liquidity({
                token_id: 8n, liquidity: 500_000_000_000_000_000n,
                a: { token: TOKEN_IN, minimum_received: 1_485_000_000n },
                b: { token: TOKEN_OUT, minimum_received: 490_000_000_000_000_000n },
                preferred_stake_token: TOKEN_IN,
            }),
        ] as const;
    }

    test( "builds digest-verified golden previews for all five protected actions", async () => {
        const operations  =  await prepared_vectors();

        for(  const operation of operations  )
        {
            const preview  =  await operation.get_signing_preview();
            const vector   =  SIGNING_VECTORS[ operation.kind ];

            expect( preview.action_type ).toBe( vector.action_type );
            expect( preview.action_field ).toBe( vector.action_field );
            expect( preview.fields.map(( field ) => [ field.name, field.type, field.value ]) ).toEqual(
                vector.fields.map(( field ) => [ ...field ])
            );
            expect( preview.digest ).toBe( signing_response( operation.execution_data )[0] );
            expect( preview.protocol ).toBe( operation.execution_data.protocol );
        }
    });

    test( "rejects descriptor values that do not match the BondRoute digest", async () => {
        const { safeswap }  =  await make_sdk();
        const operation     =  await safeswap.swaps.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 1_000_000n },
            output: { token: TOKEN_OUT, minimum_amount: 1n },
            pool_info: POOL_INFO,
        });
        tamper_signing_values  =  true;
        await expect( operation.get_signing_preview() ).rejects.toThrow( "do not match the BondRoute signing digest" );
        tamper_signing_values  =  false;
    });

    test( "passes the verified typed data to the wallet signer", async () => {
        const { safeswap, signing_requests }  =  await make_sdk();
        const operation  =  await safeswap.swaps.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 1_000_000n },
            output: { token: TOKEN_OUT, minimum_amount: 400_000_000_000_000_000n },
            pool_info: POOL_INFO,
        });

        const signature  =  await operation.sign_execution();
        const preview    =  await operation.get_signing_preview();

        expect( signature ).toBe( `0x${ "11".repeat( 65 ) }` );
        expect( signing_requests.length ).toBe( 1 );
        expect( hashTypedData( signing_requests[0] ) ).toBe( preview.digest );
    });
});


describe( "parse_safeswap_revert", () => {

    test( "parses a slippage revert", () => {
        const output = encodeErrorResult({ abi: SAFESWAP_ABI, errorName: "SlippageExceeded", args: [ 10n, 11n ] });

        const parsed = parse_safeswap_revert( output as Hex );
        expect( parsed.kind ).toBe( "slippage_exceeded" );
        expect( parsed.description ).toBe( "SafeSwap slippage check failed: received 10, required at least 11." );
        if(  parsed.kind === "slippage_exceeded"  )
        {
            expect( parsed.amount_received ).toBe( 10n );
            expect( parsed.minimum_required ).toBe( 11n );
        }
    });

    test( "parses a hook-config-not-registered revert", () => {
        const output = encodeErrorResult({ abi: SAFESWAP_ABI, errorName: "HookConfigNotRegistered", args: [ 30, 50 ] });

        const parsed = parse_safeswap_revert( output as Hex );
        expect( parsed.kind ).toBe( "hook_config_not_registered" );
        if(  parsed.kind === "hook_config_not_registered"  )
        {
            expect( parsed.base_fee_bps ).toBe( 30 );
            expect( parsed.rebate_percent ).toBe( 50 );
        }
    });

    test( "parses a maximum-input-exceeded revert", () => {
        const output = encodeErrorResult({ abi: SAFESWAP_ABI, errorName: "MaximumInputExceeded", args: [ 120n, 100n ] });

        const parsed = parse_safeswap_revert( output as Hex );
        expect( parsed.kind ).toBe( "maximum_input_exceeded" );
    });

    test( "parses a position-unauthorized revert", () => {
        const output = encodeErrorResult({ abi: SAFESWAP_ABI, errorName: "PositionUnauthorized", args: [ 1n, USER, TOKEN_OUT ] });

        const parsed = parse_safeswap_revert( output as Hex );
        expect( parsed.kind ).toBe( "position_unauthorized" );
        if(  parsed.kind === "position_unauthorized"  )  expect( parsed.token_id ).toBe( 1n );
    });

    test( "parses a signed-swap-input-mismatch revert", () => {
        const output = encodeErrorResult({ abi: SAFESWAP_ABI, errorName: "SignedSwapInputMismatch", args: [ TOKEN_IN, 100n, TOKEN_OUT, 90n ] });

        const parsed = parse_safeswap_revert( output as Hex );
        expect( parsed.kind ).toBe( "signed_swap_input_mismatch" );
        if(  parsed.kind === "signed_swap_input_mismatch"  )
        {
            expect( parsed.signed_token ).toBe( TOKEN_IN );
            expect( parsed.signed_amount ).toBe( 100n );
            expect( parsed.funded_token ).toBe( TOKEN_OUT );
            expect( parsed.funded_amount ).toBe( 90n );
        }
    });

    test( "parses a repricing-fee-exceeds-v4-limit revert", () => {
        const output = encodeErrorResult({ abi: SAFESWAP_ABI, errorName: "RepricingFeeExceedsV4Limit", args: [ 1_000_000n, 999_999n ] });

        const parsed = parse_safeswap_revert( output as Hex );
        expect( parsed.kind ).toBe( "repricing_fee_exceeds_v4_limit" );
        if(  parsed.kind === "repricing_fee_exceeds_v4_limit"  )
        {
            expect( parsed.total_fee_pips ).toBe( 1_000_000n );
            expect( parsed.maximum_fee_pips ).toBe( 999_999n );
        }
    });

    test( "returns an unknown shape for unknown revert data", () => {
        expect( parse_safeswap_revert( "0xdeadbeef" ) ).toEqual({
            kind:        "unknown",
            description: "SafeSwap reverted with an unknown error.",
        });
    });
});


describe( "explain_safeswap_revert", () => {

    test( "explains a bundled SafeSwap custom error", () => {
        const output = encodeErrorResult({ abi: SAFESWAP_ABI, errorName: "SlippageExceeded", args: [ 10n, 11n ] });

        expect( explain_safeswap_revert( output as Hex ) ).toBe( "SafeSwap slippage check failed: received 10, required at least 11." );
    });

    test( "returns a generic explanation for unknown revert data", () => {
        expect( explain_safeswap_revert( "0xdeadbeef" ) ).toBe( "SafeSwap reverted with an unknown error." );
    });
});


// ━━━━  GASLESS TYPE-HASH SPLICE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

describe( "compute_gasless_type_hash (the SafeSwapGaslessBond splice)", () => {

    const BONDROUTE_PREFIX  =  "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,";

    test( "re-parents the protocol action tail under the SafeSwapGaslessBond prefix (matches the on-chain delegate)", () => {
        const protocol_string  =  `${ BONDROUTE_PREFIX }Foo bar)Foo(uint256 x)TokenAmount(address token,uint256 amount)`;

        const expected  =  keccak256( toBytes(
            "SafeSwapGaslessBond(address helper,address relayer,TokenAmount relayer_fee,TokenAmount stake,uint256 create_deadline,bytes32 commitment_hash,Foo bar)Foo(uint256 x)TokenAmount(address token,uint256 amount)"
        ) );

        expect( compute_gasless_type_hash( protocol_string ) ).toBe( expected );
    });

    test( "throws when the protocol string lacks the BondRoute ExecuteBondAs prefix", () => {
        expect( () => compute_gasless_type_hash( "WrongRoot(uint256 x)" ) ).toThrow( /ExecuteBondAs prefix/ );
    });
});

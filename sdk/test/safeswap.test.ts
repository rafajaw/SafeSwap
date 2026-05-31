// SPDX-License-Identifier: MIT

import { describe, expect, test } from "bun:test";
import { encodeErrorResult, type Address, type Hex } from "viem";
import { BONDROUTE_ADDRESS, NATIVE_TOKEN } from "@bondroute/sdk";
import { SAFESWAP_ABI, SafeSwap, explain_safeswap_revert, parse_safeswap_revert } from "../SafeSwap";

const USER        =  "0x1111111111111111111111111111111111111111" as const;
const SAFESWAP    =  "0x2222222222222222222222222222222222222222" as const;
const BONDROUTE   =  "0x3333333333333333333333333333333333333333" as const;
const TOKEN_IN    =  "0x4444444444444444444444444444444444444444" as const;
const TOKEN_OUT   =  "0x5555555555555555555555555555555555555555" as const;
const TOKEN_OTHER =  "0x6666666666666666666666666666666666666666" as const;

function make_sdk_clients( balances?: Record<string, bigint> )
{
    const quote_calls: Array<{ address: Address, args: readonly unknown[] }> = [];
    const balance_reads: Address[] = [];
    const public_client = {
        getChainId: async () => 1,
        getBalance: async () => balances?.[ NATIVE_TOKEN.toLowerCase() ] ?? 0n,
        readContract: async ( request: { address: Address, functionName?: string, args?: readonly unknown[] } ) => {
            if(  request.functionName === "balanceOf"  )
        {
            balance_reads.push( request.address );
            return balances?.[ request.address.toLowerCase() ] ?? 0n;
        }
            if(  request.functionName === "decimals"  )  return request.address === TOKEN_IN  ?  6  :  18;
            if(  request.functionName === "symbol"  )    return request.address === TOKEN_IN  ?  "USDC"  :  "WETH";

            const args  =  request.args ?? [];
            quote_calls.push({ address: request.address, args });
            return [
                { token: args[ 1 ] as Address, amount: 10n },
                args[ 2 ],
                3n,
                2n,
                3600n,
                { min: 0n, max: 0n },
                { min: 0n, max: 0n },
            ];
        },
    };
    const wallet_client = {};
    return { public_client, wallet_client, quote_calls, balance_reads };
}

describe( "SafeSwap address overrides", () => {

    test( "uses configured SafeSwap and BondRoute addresses when preparing a bond", async () => {
        const { public_client, wallet_client, quote_calls } = make_sdk_clients();
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            bondroute_address: BONDROUTE,
            on_pending_bond: () => {},
        });

        const bond = await safeswap.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 100n },
            output: { token: TOKEN_OUT, minimum_amount: 1n },
            pool_info: { fee: 3000, tick_spacing: 60 },
        });

        expect( quote_calls[0]?.address ).toBe( SAFESWAP );
        expect( bond.execution_data.protocol ).toBe( SAFESWAP );
        expect( bond.bondroute ).toBe( BONDROUTE );
    });

    test( "defaults to the canonical BondRoute address when not overridden", async () => {
        const { public_client, wallet_client } = make_sdk_clients();
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        const bond = await safeswap.prepare_remove_liquidity({
            pool_info: { fee: 3000, tick_spacing: 60 },
            tick_lower: -60,
            tick_upper: 60,
            liquidity: 1n,
            a: { token: TOKEN_IN, minimum_received: 0n },
            b: { token: TOKEN_OUT, minimum_received: 0n },
        });

        expect( bond.bondroute ).toBe( BONDROUTE_ADDRESS );
    });
});

describe( "SafeSwap operation descriptions", () => {

    test( "lazily renders a prepared swap description with token metadata", async () => {
        const { public_client, wallet_client } = make_sdk_clients();
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        const operation = await safeswap.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 1_000_000n },
            output: { token: TOKEN_OUT, minimum_amount: 390_000_000_000_000_000n },
            pool_info: { fee: 3000, tick_spacing: 60 },
        });

        expect( operation.kind ).toBe( "swap_exact_input" );
        expect( await operation.render_description() ).toBe( "Swap exactly 1 USDC for at least 0.39 WETH." );
    });

    test( "propagates token metadata errors while rendering descriptions", async () => {
        const { public_client, wallet_client } = make_sdk_clients();
        const failing_public_client = {
            ...public_client,
            readContract: async ( request: { functionName?: string } ) => {
                if(  request.functionName === "decimals"  )  throw new Error( "metadata unavailable" );
                return await public_client.readContract( request as any );
            },
        };
        const safeswap = await SafeSwap.init({
            public_client: failing_public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        const operation = await safeswap.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 1_000_000n },
            output: { token: TOKEN_OUT, minimum_amount: 390_000_000_000_000_000n },
            pool_info: { fee: 3000, tick_spacing: 60 },
        });

        await expect( operation.render_description() ).rejects.toThrow( "metadata unavailable" );
    });
});

describe( "SafeSwap parameter validation", () => {

    test( "rejects same-token swaps before quote", async () => {
        const { public_client, wallet_client, quote_calls } = make_sdk_clients();
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        await expect( safeswap.prepare_swap_exact_input({
            input: { token: TOKEN_IN, exact_amount: 100n },
            output: { token: TOKEN_IN, minimum_amount: 1n },
            pool_info: { fee: 3000, tick_spacing: 60 },
        })).rejects.toThrow( "swap tokens must be different." );

        expect( quote_calls.length ).toBe( 0 );
    });

    test( "rejects invalid tick ranges before quote", async () => {
        const { public_client, wallet_client, quote_calls } = make_sdk_clients();
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        await expect( safeswap.prepare_remove_liquidity({
            pool_info: { fee: 3000, tick_spacing: 60 },
            tick_lower: 60,
            tick_upper: 60,
            liquidity: 1n,
            a: { token: TOKEN_IN, minimum_received: 0n },
            b: { token: TOKEN_OUT, minimum_received: 0n },
        })).rejects.toThrow( "tick_lower must be less than tick_upper." );

        expect( quote_calls.length ).toBe( 0 );
    });
});

describe( "SafeSwap preferred stake token", () => {

    test( "auto-selects token0 when omitted add-liquidity stake preference has no better candidate", async () => {
        const { public_client, wallet_client, quote_calls } = make_sdk_clients();
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        await safeswap.prepare_add_liquidity({
            a: { token: TOKEN_OUT, amount: 200n, minimum_added: 0n },
            b: { token: TOKEN_IN, amount: 100n, minimum_added: 0n },
            pool_info: { fee: 3000, tick_spacing: 60 },
            tick_lower: -60,
            tick_upper: 60,
        });

        expect( quote_calls[0]?.args[1] ).toBe( TOKEN_IN );
        expect( quote_calls[1]?.args[1] ).toBe( TOKEN_OUT );
    });

    test( "passes preferred stake token through for add liquidity", async () => {
        const { public_client, wallet_client, quote_calls } = make_sdk_clients();
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        await safeswap.prepare_add_liquidity({
            a: { token: TOKEN_IN, amount: 100n, minimum_added: 0n },
            b: { token: TOKEN_OUT, amount: 200n, minimum_added: 0n },
            pool_info: { fee: 3000, tick_spacing: 60 },
            tick_lower: -60,
            tick_upper: 60,
            preferred_stake_token: TOKEN_OUT,
        });

        expect( quote_calls[0]?.args[1] ).toBe( TOKEN_OUT );
    });

    test( "auto-selects token1 for remove liquidity when only token1 stake is affordable", async () => {
        const { public_client, wallet_client, quote_calls } = make_sdk_clients({
            [ TOKEN_IN.toLowerCase() ]: 0n,
            [ TOKEN_OUT.toLowerCase() ]: 10n,
        });
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        const bond = await safeswap.prepare_remove_liquidity({
            pool_info: { fee: 3000, tick_spacing: 60 },
            tick_lower: -60,
            tick_upper: 60,
            liquidity: 1n,
            a: { token: TOKEN_OUT, minimum_received: 0n },
            b: { token: TOKEN_IN, minimum_received: 0n },
        });

        expect( bond.execution_data.stake.token ).toBe( TOKEN_OUT );
        expect( quote_calls[0]?.args[1] ).toBe( TOKEN_IN );
        expect( quote_calls[1]?.args[1] ).toBe( TOKEN_OUT );
    });

    test( "passes preferred stake token through for remove liquidity", async () => {
        const { public_client, wallet_client, quote_calls } = make_sdk_clients();
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        await safeswap.prepare_remove_liquidity({
            pool_info: { fee: 3000, tick_spacing: 60 },
            tick_lower: -60,
            tick_upper: 60,
            liquidity: 1n,
            a: { token: TOKEN_IN, minimum_received: 0n },
            b: { token: TOKEN_OUT, minimum_received: 0n },
            preferred_stake_token: TOKEN_OUT,
        });

        expect( quote_calls[0]?.args[1] ).toBe( TOKEN_OUT );
    });

    test( "auto-selects native stake token when both donate candidates are affordable", async () => {
        const { public_client, wallet_client, quote_calls } = make_sdk_clients({
            [ NATIVE_TOKEN.toLowerCase() ]: 1_000n,
            [ TOKEN_OUT.toLowerCase() ]: 1_000n,
        });
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        const bond = await safeswap.prepare_donate({
            a: { token: TOKEN_OUT, amount: 200n },
            b: { token: NATIVE_TOKEN, amount: 100n },
            pool_info: { fee: 3000, tick_spacing: 60 },
        });

        expect( bond.execution_data.stake.token ).toBe( NATIVE_TOKEN );
        expect( quote_calls[0]?.args[1] ).toBe( NATIVE_TOKEN );
        expect( quote_calls[1]?.args[1] ).toBe( TOKEN_OUT );
    });

    test( "passes preferred stake token through for donate", async () => {
        const { public_client, wallet_client, quote_calls } = make_sdk_clients();
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        await safeswap.prepare_donate({
            a: { token: TOKEN_IN, amount: 100n },
            b: { token: TOKEN_OUT, amount: 200n },
            pool_info: { fee: 3000, tick_spacing: 60 },
            preferred_stake_token: TOKEN_OUT,
        });

        expect( quote_calls[0]?.args[1] ).toBe( TOKEN_OUT );
    });

    test( "rejects unexpected preferred stake token before quote", async () => {
        const { public_client, wallet_client, quote_calls } = make_sdk_clients();
        const safeswap = await SafeSwap.init({
            public_client: public_client as any,
            wallet_client: wallet_client as any,
            account: USER,
            storage: "memory",
            safeswap_address: SAFESWAP,
            on_pending_bond: () => {},
        });

        expect( safeswap.prepare_add_liquidity({
            a: { token: TOKEN_IN, amount: 100n, minimum_added: 0n },
            b: { token: TOKEN_OUT, amount: 200n, minimum_added: 0n },
            pool_info: { fee: 3000, tick_spacing: 60 },
            tick_lower: -60,
            tick_upper: 60,
            preferred_stake_token: TOKEN_OTHER,
        })).rejects.toThrow( "preferred_stake_token must be one of the SafeSwap pool tokens." );

        expect( quote_calls.length ).toBe( 0 );
    });
});

describe( "parse_safeswap_revert", () => {

    test( "parses bundled SafeSwap custom errors", () => {
        const output = encodeErrorResult({
            abi: SAFESWAP_ABI,
            errorName: "SlippageExceeded",
            args: [ 10n, 11n ],
        });

        const parsed = parse_safeswap_revert( output as Hex );
        expect( parsed.kind ).toBe( "slippage_exceeded" );
        expect( parsed.description ).toBe( "SafeSwap slippage check failed: received 10, required at least 11." );
        if(  parsed.kind === "slippage_exceeded"  )
        {
            expect( parsed.amount_received ).toBe( 10n );
            expect( parsed.minimum_required ).toBe( 11n );
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

    test( "explains bundled SafeSwap custom errors", () => {
        const output = encodeErrorResult({
            abi: SAFESWAP_ABI,
            errorName: "SlippageExceeded",
            args: [ 10n, 11n ],
        });

        expect( explain_safeswap_revert( output as Hex ) ).toBe( "SafeSwap slippage check failed: received 10, required at least 11." );
    });

    test( "returns a generic explanation for unknown revert data", () => {
        expect( explain_safeswap_revert( "0xdeadbeef" ) ).toBe( "SafeSwap reverted with an unknown error." );
    });
});

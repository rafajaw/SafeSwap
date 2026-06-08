import { describe, expect, test } from "bun:test";
import type { SafeSwapOperationKind, SafeSwapSigningPreview } from "../../sdk/SafeSwap";
import { signing_preview_snapshot } from "../src/signing_preview";

const ACTIONS = {
    swap_exact_input: [
        "ExactInputSwap (sS__SWAP__Ss)",
        "Pay: = 1 USDC",
        "Receive: >= 0.4 WETH",
        "Pool: 0.3% base fee | 50% rebate | tick spacing 60",
        "Warning: >>  Check protocol and token addresses  <<",
        "WETH: 0x5555555555555555555555555555555555555555",
    ],
    swap_exact_output: [
        "ExactOutputSwap (sS__SWAP__Ss)",
        "Pay: <= 1.1 USDC",
        "Receive: = 0.4 WETH",
        "Pool: 0.3% base fee | 50% rebate | tick spacing 60",
        "Warning: >>  Check protocol and token addresses  <<",
        "WETH: 0x5555555555555555555555555555555555555555",
    ],
    create_position: [
        "CreatePosition (sS__CREATE_POSITION__Ss)",
        "Deposit: <= 1 WETH + 3,000 USDC",
        "Minimum: >= 0.99 WETH + 2,970 USDC",
        "Liquidity: 1000000000000000000",
        "Range: 2,850 ~ 3,150 USDC/WETH",
        "Price: 3,000 USDC/WETH",
        "Pool: 0.3% base fee | 50% rebate | tick spacing 60",
        "Warning: >>  Check protocol and token addresses  <<",
        "WETH: 0x5555555555555555555555555555555555555555",
        "USDC: 0x4444444444444444444444444444444444444444",
    ],
    add_liquidity: [
        "AddLiquidity (sS__ADD_LIQUIDITY__Ss)",
        "Position: LP #8",
        "Deposit: <= 0.5 WETH + 1,500 USDC",
        "Minimum: >= 0.49 WETH + 1,485 USDC",
        "Liquidity: 500000000000000000",
        "Pool: 0.3% base fee | 50% rebate | tick spacing 60",
        "Warning: >>  Check protocol and token addresses  <<",
        "WETH: 0x5555555555555555555555555555555555555555",
        "USDC: 0x4444444444444444444444444444444444444444",
    ],
    remove_liquidity: [
        "RemoveLiquidity (sS__REMOVE_LIQUIDITY__Ss)",
        "Position: LP #8",
        "Burn: 500000000000000000 liquidity",
        "Receive: >= 0.49 WETH + 1,485 USDC",
        "Pool: 0.3% base fee | 50% rebate | tick spacing 60",
        "Warning: >>  Check protocol and token addresses  <<",
        "WETH: 0x5555555555555555555555555555555555555555",
        "USDC: 0x4444444444444444444444444444444444444444",
    ],
} as const;

function preview_for( kind: SafeSwapOperationKind, lines: readonly string[] ): SafeSwapSigningPreview
{
    const [ header, ...field_lines ]  =  lines;
    const [ action_type, action_field_with_paren ]  =  header!.split( " (" );
    return {
        kind,
        action_type: action_type!,
        action_field: action_field_with_paren!.slice( 0, -1 ),
        fields: field_lines.map(( line ) => {
            const separator  =  line.indexOf( ": " );
            const name       =  line.slice( 0, separator );
            const value      =  line.slice( separator + 2 );
            return { name, type: value.startsWith( "0x" ) ? "address" : "string", value };
        }),
    } as SafeSwapSigningPreview;
}

describe( "REFERENCE_2 frontend snapshots", () => {
    for(  const [ kind, lines ] of Object.entries( ACTIONS )  )
    {
        test( `renders ${ kind } labels and values`, () => {
            expect( signing_preview_snapshot( preview_for( kind as SafeSwapOperationKind, lines ) ) ).toBe( lines.join( "\n" ) );
        });
    }
});

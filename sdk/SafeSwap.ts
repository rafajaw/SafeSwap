// SPDX-License-Identifier: MIT
//
//  ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
//  ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
//  ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
//  ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
//  ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
//  ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
//  ━━━━━━━━━━━━━━━━━━━━━  Trustless MEV-protected Uniswap pools  ━━━━━━━━━━━━━━━━━━━━━
//
// SafeSwap SDK — single-file TypeScript client wrapping BondRoute for SafeSwap operations.
//
// QUICK INTEGRATION:
//   1. Copy this file into your project (or install once published as @safeswap/sdk)
//   2. Install peer deps: `npm install viem @bondroute/sdk`
//   3. Initialize once: `const safeswap = await SafeSwap.init({ on_pending_bond: ..., ... })`
//   4. Prepare + dispatch: `const operation = await safeswap.prepare_swap_exact_input({ ... })`
//
// No external dependencies beyond viem and @bondroute/sdk.
// Storage and recovery are handled by the embedded BondRoute instance.

import {
    decodeErrorResult,
    encodeFunctionData,
    formatUnits,
    parseAbi,
    type Account,
    type Address,
    type Hex,
    type PublicClient,
    type WalletClient,
} from "viem";

import {
    BondRoute,
    NATIVE_TOKEN,
    type Bond,
    type BondConstraints,
    type BondSnapshot,
    type ExecutionData,
    type Storage,
    type TokenAmount,
} from "@bondroute/sdk";


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// CONSTANTS
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/** Canonical SafeSwap deployment address (same across all chains). ***TODO*** Set before release. */
export const SAFESWAP_ADDRESS  =  "0x0000000000000000000000000000000000000000" as const;
const ZERO_ADDRESS             =  "0x0000000000000000000000000000000000000000" as const;

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// TYPES
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/** Re-export Bond and BondSnapshot so callers don't need to import BondRoute SDK directly. */
export type { Bond, BondSnapshot, BondConstraints, ExecutionData, TokenAmount };

export type SafeSwapOperationKind =
    | "swap_exact_input"
    | "swap_exact_output"
    | "add_liquidity"
    | "remove_liquidity"
    | "donate";

export type TokenDisplayMetadata = {
    symbol:   string;
    decimals: number;
};

export type RenderDescriptionOpts = {
    native_token?: TokenDisplayMetadata;
};

export type PreparedSafeSwapOperation = Bond & {
    kind: SafeSwapOperationKind;
    render_description: ( opts?: RenderDescriptionOpts ) => Promise<string>;
};

/** Uniswap V4 pool configuration shared by all SafeSwap operations. */
export type PoolInfo = {
    fee:          number;
    tick_spacing: number;
};

export type SwapExactInputParams = {
    input: {
        token: Address;
        exact_amount: bigint;
    };
    output: {
        token: Address;
        minimum_amount: bigint;
    };
    pool_info: PoolInfo;
};

export type SwapExactOutputParams = {
    input: {
        token: Address;
        maximum_amount: bigint;
    };
    output: {
        token: Address;
        exact_amount: bigint;
    };
    pool_info: PoolInfo;
};

export type AddLiquidityParams = {
    a: {
        token: Address;
        amount: bigint;
        minimum_added: bigint;
    };
    b: {
        token: Address;
        amount: bigint;
        minimum_added: bigint;
    };
    pool_info: PoolInfo;
    tick_lower: number;
    tick_upper: number;
    /**
     * Optional stake token preference.
     * If supplied, must be a.token or b.token and is used exactly.
     * If omitted, the SDK prepares both pool-token stake candidates and picks an affordable one from current balances.
     */
    preferred_stake_token?: Address;
};

export type RemoveLiquidityParams = {
    pool_info:  PoolInfo;
    tick_lower: number;
    tick_upper: number;
    liquidity:  bigint;
    a: {
        token: Address;
        minimum_received: bigint;
    };
    b: {
        token: Address;
        minimum_received: bigint;
    };
    /**
     * Optional stake token preference.
     * If supplied, must be a.token or b.token and is used exactly.
     * If omitted, the SDK prepares both pool-token stake candidates and picks an affordable one from current balances.
     */
    preferred_stake_token?: Address;
};

export type DonateParams = {
    a: {
        token: Address;
        amount: bigint;
    };
    b: {
        token: Address;
        amount: bigint;
    };
    pool_info: PoolInfo;
    /**
     * Optional stake token preference.
     * If supplied, must be a.token or b.token and is used exactly.
     * If omitted, the SDK prepares both pool-token stake candidates and picks an affordable one from current balances.
     */
    preferred_stake_token?: Address;
};

export type PositionInfo = {
    liquidity:                        bigint;
    fee_growth_inside_0_last_x128:    bigint;
    fee_growth_inside_1_last_x128:    bigint;
};

export type ParsedSafeSwapRevert =
    | {
        kind:                "slippage_exceeded";
        description:         string;
        amount_received:     bigint;
        minimum_required:    bigint;
    }
    | {
        kind:                "unsupported_fee_tier";
        description:         string;
        fee:                 number;
    }
    | {
        kind:                "one_sided_deposit_mismatch";
        description:         string;
        expected_token:      Address;
        minimum_required:    bigint;
    }
    | {
        kind:                    "minimum_added_tokens_mismatch";
        description:             string;
        funding_token0:          Address;
        funding_token1:          Address;
        minimum_added_a_token:   Address;
        minimum_added_b_token:   Address;
    }
    | {
        kind:                "bondroute_required";
        description:         string;
        caller:              Address;
        bondroute:           Address;
    }
    | {
        kind:                "unauthorized";
        description:         string;
        caller:              Address;
        expected:            Address;
    }
    | {
        kind:                "invalid";
        description:         string;
        field:               string;
        value:               bigint;
    }
    | {
        kind:                "transfer_failed";
        description:         string;
        token:               Address;
        recipient:           Address;
        amount:              bigint;
    }
    | {
        kind:                "unsupported_call";
        description:         string;
    }
    | {
        kind:                "unknown";
        description:         string;
    };

export type SafeSwapOpts = {
    public_client:  PublicClient;
    wallet_client:  WalletClient;
    account:        Account | Address;
    /** Override the SafeSwap contract address (advanced — for forks and testnets). */
    safeswap_address?:  Address;
    /** Override the BondRoute contract address (advanced — for forks and testnets). */
    bondroute_address?: Address;
    /**
     * Required. Invoked once per unfinished bond discovered in storage at init.
     * Pass `(bond) => bond.resume()` to auto-resume, or keep a reference for later.
     */
    on_pending_bond: ( bond: Bond ) => void | Promise<void>;
    /**
     * Storage adapter for bond persistence. Defaults to `localStorage` in browsers.
     * Pass `"memory"` to opt out of recovery (NOT recommended outside tests).
     */
    storage?: Storage | "memory";
    gas?: {
        default_multiplier?:      number;
        default_bump_multiplier?: number;
    };
    min_confirmations_to_forget?: number;
};


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ABI (minimal — only what the SDK actually calls)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

export const SAFESWAP_ABI  =  parseAbi([
    // PoolInfo tuple: (uint24 fee, int24 tick_spacing)
    // TokenAmount tuple: (address token, uint256 amount)

    "function swap_exact_input((address token_out, uint256 minimum_output_amount, (uint24 fee, int24 tick_spacing) pool_info) params) external",
    "function swap_exact_output((address token_out, uint256 exact_output_amount, (uint24 fee, int24 tick_spacing) pool_info) params) external",
    "function add_liquidity(((uint24 fee, int24 tick_spacing) pool_info, int24 tick_lower, int24 tick_upper, (address token, uint256 amount) minimum_added_a, (address token, uint256 amount) minimum_added_b) params) external",
    "function remove_liquidity(((uint24 fee, int24 tick_spacing) pool_info, int24 tick_lower, int24 tick_upper, uint128 liquidity, (address token, uint256 amount) minimum_received_a, (address token, uint256 amount) minimum_received_b) params) external",
    "function donate(((uint24 fee, int24 tick_spacing) pool_info) params) external",

    "function __OFF_CHAIN__get_pool_id(address token_a, address token_b, (uint24 fee, int24 tick_spacing) pool_info) external view returns (bytes32 pool_id)",
    "function __OFF_CHAIN__get_position_info(bytes32 pool_id, address user, int24 tick_lower, int24 tick_upper) external view returns (uint128 liquidity, uint256 fee_growth_inside_0_last_x128, uint256 fee_growth_inside_1_last_x128)",

    "error SlippageExceeded(uint256 amount_received, uint256 minimum_required)",
    "error UnsupportedFeeTier(uint24 fee)",
    "error OneSidedDepositMismatch(address expected_token, uint256 minimum_required)",
    "error MinimumAddedTokensMismatch(address funding_token0, address funding_token1, address minimum_added_a_token, address minimum_added_b_token)",
    "error BondRouteRequired(address caller, address bondroute)",
    "error Unauthorized(address caller, address expected)",
    "error Invalid(string field, uint256 value)",
    "error TransferFailed(address token, address recipient, uint256 amount)",
    "error UnsupportedCall()",
]);

const ERC20_METADATA_ABI  =  parseAbi([
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
]);

/** Decode SafeSwap revert output against the SDK's bundled SafeSwap ABI. */
function decode_safeswap_revert( output: Hex ): { name: string, args: readonly unknown[] } | null
{
    if(  output.length < 10  )  return null;
    try
    {
        const decoded  =  decodeErrorResult({ abi: SAFESWAP_ABI, data: output }) as { errorName: string, args?: readonly unknown[] };
        return { name: decoded.errorName, args: decoded.args ?? [] };
    }
    catch
    {
        return null;
    }
}

function as_bigint( value: unknown ): bigint
{
    return typeof value === "bigint"  ?  value  :  BigInt( String( value ) );
}

function as_number( value: unknown ): number
{
    return Number( as_bigint( value ) );
}

function as_address( value: unknown ): Address
{
    return String( value ) as Address;
}

function as_string( value: unknown ): string
{
    return String( value );
}

/** Parse SafeSwap revert output into a UI-facing semantic shape. */
export function parse_safeswap_revert( output: Hex ): ParsedSafeSwapRevert
{
    const decoded  =  decode_safeswap_revert( output );
    if(  decoded === null  )  return { kind: "unknown", description: "SafeSwap reverted with an unknown error." };

    switch( decoded.name )
    {
        case "SlippageExceeded": {
            const amount_received   =  as_bigint( decoded.args[0] );
            const minimum_required  =  as_bigint( decoded.args[1] );
            return {
                kind:        "slippage_exceeded",
                description: `SafeSwap slippage check failed: received ${ String(amount_received) }, required at least ${ String(minimum_required) }.`,
                amount_received,
                minimum_required,
            };
        }

        case "UnsupportedFeeTier": {
            const fee  =  as_number( decoded.args[0] );
            return {
                kind:        "unsupported_fee_tier",
                description: `SafeSwap does not support this pool fee tier: ${ String(fee) }.`,
                fee,
            };
        }

        case "OneSidedDepositMismatch": {
            const expected_token    =  as_address( decoded.args[0] );
            const minimum_required  =  as_bigint( decoded.args[1] );
            return {
                kind:        "one_sided_deposit_mismatch",
                description: `SafeSwap expected a one-sided liquidity deposit in token ${ expected_token } with minimum amount ${ String(minimum_required) }.`,
                expected_token,
                minimum_required,
            };
        }

        case "MinimumAddedTokensMismatch": {
            const funding_token0         =  as_address( decoded.args[0] );
            const funding_token1         =  as_address( decoded.args[1] );
            const minimum_added_a_token  =  as_address( decoded.args[2] );
            const minimum_added_b_token  =  as_address( decoded.args[3] );
            return {
                kind:        "minimum_added_tokens_mismatch",
                description: `SafeSwap minimum-added token order does not match the bond fundings. Funding tokens were ${ funding_token0 } and ${ funding_token1 }; minimum-added tokens were ${ minimum_added_a_token } and ${ minimum_added_b_token }.`,
                funding_token0,
                funding_token1,
                minimum_added_a_token,
                minimum_added_b_token,
            };
        }

        case "BondRouteRequired": {
            const caller     =  as_address( decoded.args[0] );
            const bondroute  =  as_address( decoded.args[1] );
            return {
                kind:        "bondroute_required",
                description: `SafeSwap operation must execute through BondRoute ${ bondroute }; caller was ${ caller }.`,
                caller,
                bondroute,
            };
        }

        case "Unauthorized": {
            const caller    =  as_address( decoded.args[0] );
            const expected  =  as_address( decoded.args[1] );
            return {
                kind:        "unauthorized",
                description: `SafeSwap rejected unauthorized caller ${ caller }; expected ${ expected }.`,
                caller,
                expected,
            };
        }

        case "Invalid": {
            const field  =  as_string( decoded.args[0] );
            const value  =  as_bigint( decoded.args[1] );
            return {
                kind:        "invalid",
                description: `SafeSwap rejected invalid parameter ${ field } with value ${ String(value) }.`,
                field,
                value,
            };
        }

        case "TransferFailed": {
            const token      =  as_address( decoded.args[0] );
            const recipient  =  as_address( decoded.args[1] );
            const amount     =  as_bigint( decoded.args[2] );
            return {
                kind:        "transfer_failed",
                description: `SafeSwap token transfer failed for token ${ token } to recipient ${ recipient } with amount ${ String(amount) }.`,
                token,
                recipient,
                amount,
            };
        }

        case "UnsupportedCall":
            return { kind: "unsupported_call", description: "SafeSwap does not support this encoded call." };

        default:
            return { kind: "unknown", description: `SafeSwap reverted with ${ decoded.name }.` };
    }
}

/** Return a user-facing explanation for SafeSwap revert output. */
export function explain_safeswap_revert( output: Hex ): string
{
    return parse_safeswap_revert( output ).description;
}

function get_ordered_pool_tokens( token_a: Address, token_b: Address ): { token0: Address, token1: Address }
{
    return BigInt(token_a) < BigInt(token_b)
        ?  { token0: token_a, token1: token_b }
        :  { token0: token_b, token1: token_a };
}

function resolve_explicit_preferred_stake_token( preferred_stake_token: Address | undefined, token_a: Address, token_b: Address ): Address | undefined
{
    if(  preferred_stake_token === undefined  )  return undefined;

    const preferred  =  preferred_stake_token.toLowerCase();
    if(  preferred === token_a.toLowerCase()  ||  preferred === token_b.toLowerCase()  )  return preferred_stake_token;

    throw new Error( "preferred_stake_token must be one of the SafeSwap pool tokens." );
}

async function can_pay_bond( bond: Bond ): Promise<boolean>
{
    return ( await bond.get_missing_balances() ).length === 0;
}

function is_native_token( token: Address ): boolean
{
    return token.toLowerCase() === NATIVE_TOKEN.toLowerCase();
}

function assert_positive_amount( field: string, amount: bigint ): void
{
    if(  amount <= 0n  )  throw new Error( `${ field } must be greater than zero.` );
}

function assert_distinct_tokens( token_a: Address, token_b: Address, context: string ): void
{
    if(  token_a.toLowerCase() === token_b.toLowerCase()  )  throw new Error( `${ context } tokens must be different.` );
}

function assert_ticks( tick_lower: number, tick_upper: number, tick_spacing: number ): void
{
    if(  tick_spacing <= 0  )  throw new Error( "pool_info.tick_spacing must be greater than zero." );
    if(  tick_lower >= tick_upper  )  throw new Error( "tick_lower must be less than tick_upper." );
    if(  tick_lower % tick_spacing !== 0  )  throw new Error( "tick_lower must be aligned to pool_info.tick_spacing." );
    if(  tick_upper % tick_spacing !== 0  )  throw new Error( "tick_upper must be aligned to pool_info.tick_spacing." );
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SDK
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * SafeSwap SDK entry point.
 *
 * Wraps BondRoute to provide high-level SafeSwap operations. All bond lifecycle
 * management (persistence, recovery, create → wait → execute) is handled internally.
 *
 * @example
 *   const safeswap = await SafeSwap.init({
 *       public_client, wallet_client, account,
 *       on_pending_bond: (bond) => bond.resume(),
 *   });
 *   const operation = await safeswap.prepare_swap_exact_input({
 *       input:  { token: USDC, exact_amount: 1000_000_000n },
 *       output: { token: WETH, minimum_amount: 0n },
 *       pool_info: { fee: 3000, tick_spacing: 60 },
 *   });
 *   await operation.dispatch();
 *   if (operation.status === "executed") { ... }
 */
export class SafeSwap {

    readonly #bondRoute: BondRoute;
    readonly safeswap_address: Address;
    readonly #tokenMetadataCache = new Map<string, Promise<TokenDisplayMetadata>>();

    private constructor( bondRoute: BondRoute, safeswap_address: Address )
    {
        this.#bondRoute        =  bondRoute;
        this.safeswap_address  =  safeswap_address;
    }

    /**
     * Async factory. Initializes the embedded BondRoute instance, scans storage for any
     * unfinished bonds, and routes them through `on_pending_bond` before returning.
     *
     * Throws if `on_pending_bond` is missing — recovery is too important to make optional.
     */
    static async init( opts: SafeSwapOpts ): Promise<SafeSwap>
    {
        const safeswap_address  =  opts.safeswap_address ?? SAFESWAP_ADDRESS;
        if(  safeswap_address.toLowerCase() === ZERO_ADDRESS  )  throw new Error( "safeswap_address is not configured." );

        const bondRoute  =  await BondRoute.init({
            public_client:              opts.public_client,
            wallet_client:              opts.wallet_client,
            account:                    opts.account,
            bondroute_address:          opts.bondroute_address,
            on_pending_bond:            opts.on_pending_bond,
            storage:                    opts.storage,
            gas:                        opts.gas,
            min_confirmations_to_forget: opts.min_confirmations_to_forget,
        });
        return new SafeSwap( bondRoute, safeswap_address );
    }


    // ━━━━  OPERATIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * Prepare a swap where the input amount is fixed and the output amount is at least `output.minimum_amount`.
     * Returns a prepared operation; call `operation.dispatch()` to execute.
     *
     * @example
     *   const operation = await safeswap.prepare_swap_exact_input({
     *       input:  { token: USDC, exact_amount: 1000_000_000n },
     *       output: { token: WETH, minimum_amount: 390_000_000_000_000_000n },
     *       pool_info: { fee: 3000, tick_spacing: 60 },
     *   });
     *   await operation.dispatch();
     */
    async prepare_swap_exact_input( params: SwapExactInputParams ): Promise<PreparedSafeSwapOperation>
    {
        assert_distinct_tokens( params.input.token, params.output.token, "swap" );
        assert_positive_amount( "input.exact_amount", params.input.exact_amount );

        const call  =  encodeFunctionData({
            abi:          SAFESWAP_ABI,
            functionName: "swap_exact_input",
            args:         [{
                token_out:              params.output.token,
                minimum_output_amount:  params.output.minimum_amount,
                pool_info:              params.pool_info,
            }],
        });

        const operation  =  await this.#bondRoute.prepare({
            protocol:           this.safeswap_address,
            call,
            preferred_fundings: [{ token: params.input.token, amount: params.input.exact_amount }],
        });
        return this.#attach_operation_description( operation, "swap_exact_input", async ( opts ) => {
            const input   =  await this.#render_token_amount( params.input.token, params.input.exact_amount, opts );
            const output  =  await this.#render_token_amount( params.output.token, params.output.minimum_amount, opts );
            return `Swap exactly ${ input } for at least ${ output }.`;
        });
    }

    /**
     * Prepare a swap where the output amount is exact and input is capped at `input.maximum_amount`.
     * Reverts if required input exceeds the cap. Returns a prepared operation.
     *
     * @example
     *   const operation = await safeswap.prepare_swap_exact_output({
     *       input:  { token: USDC, maximum_amount: 1100_000_000n },
     *       output: { token: WETH, exact_amount: 400_000_000_000_000_000n },
     *       pool_info: { fee: 3000, tick_spacing: 60 },
     *   });
     *   await operation.dispatch();
     */
    async prepare_swap_exact_output( params: SwapExactOutputParams ): Promise<PreparedSafeSwapOperation>
    {
        assert_distinct_tokens( params.input.token, params.output.token, "swap" );
        assert_positive_amount( "input.maximum_amount", params.input.maximum_amount );
        assert_positive_amount( "output.exact_amount", params.output.exact_amount );

        const call  =  encodeFunctionData({
            abi:          SAFESWAP_ABI,
            functionName: "swap_exact_output",
            args:         [{
                token_out:             params.output.token,
                exact_output_amount:   params.output.exact_amount,
                pool_info:             params.pool_info,
            }],
        });

        const operation  =  await this.#bondRoute.prepare({
            protocol:           this.safeswap_address,
            call,
            preferred_fundings: [{ token: params.input.token, amount: params.input.maximum_amount }],
        });
        return this.#attach_operation_description( operation, "swap_exact_output", async ( opts ) => {
            const input   =  await this.#render_token_amount( params.input.token, params.input.maximum_amount, opts );
            const output  =  await this.#render_token_amount( params.output.token, params.output.exact_amount, opts );
            return `Swap up to ${ input } for exactly ${ output }.`;
        });
    }

    /**
     * Prepare an add-liquidity operation. Both token amounts come from bond fundings.
     * `minimum_added` guards against slippage during position minting.
     *
     * @example
     *   const operation = await safeswap.prepare_add_liquidity({
     *       a: { token: USDC, amount: 1000_000_000n, minimum_added: 990_000_000n },
     *       b: { token: WETH, amount: 400_000_000_000_000_000n, minimum_added: 396_000_000_000_000_000n },
     *       pool_info: { fee: 3000, tick_spacing: 60 },
     *       tick_lower: -887220, tick_upper: 887220,
     *   });
     *   await operation.dispatch();
     */
    async prepare_add_liquidity( params: AddLiquidityParams ): Promise<PreparedSafeSwapOperation>
    {
        assert_distinct_tokens( params.a.token, params.b.token, "liquidity" );
        assert_positive_amount( "a.amount", params.a.amount );
        assert_positive_amount( "b.amount", params.b.amount );
        assert_ticks( params.tick_lower, params.tick_upper, params.pool_info.tick_spacing );

        const preferred_stake_token  =  resolve_explicit_preferred_stake_token( params.preferred_stake_token, params.a.token, params.b.token );

        const call  =  encodeFunctionData({
            abi:          SAFESWAP_ABI,
            functionName: "add_liquidity",
            args:         [{
                pool_info:  params.pool_info,
                tick_lower: params.tick_lower,
                tick_upper: params.tick_upper,
                minimum_added_a: { token: params.a.token, amount: params.a.minimum_added },
                minimum_added_b: { token: params.b.token, amount: params.b.minimum_added },
            }],
        });

        const preferred_fundings  =  [
            { token: params.a.token, amount: params.a.amount },
            { token: params.b.token, amount: params.b.amount },
        ];

        const operation  =  await this.#prepare_with_auto_stake_token( call, params.a.token, params.b.token, preferred_fundings, preferred_stake_token );
        return this.#attach_operation_description( operation, "add_liquidity", async ( opts ) => {
            const amount_a   =  await this.#render_token_amount( params.a.token, params.a.amount, opts );
            const amount_b   =  await this.#render_token_amount( params.b.token, params.b.amount, opts );
            const minimum_a  =  await this.#render_token_amount( params.a.token, params.a.minimum_added, opts );
            const minimum_b  =  await this.#render_token_amount( params.b.token, params.b.minimum_added, opts );
            return `Add ${ amount_a } and ${ amount_b } as liquidity from tick ${ params.tick_lower } to ${ params.tick_upper }, requiring at least ${ minimum_a } and ${ minimum_b } added.`;
        });
    }

    /**
     * Prepare a remove-liquidity operation. Tokens come from the position; no fundings needed.
     * `minimum_received` guards against slippage during position burn.
     *
     * @example
     *   const operation = await safeswap.prepare_remove_liquidity({
     *       pool_info: { fee: 3000, tick_spacing: 60 },
     *       tick_lower: -887220, tick_upper: 887220,
     *       liquidity: 500_000_000_000_000n,
     *       a: { token: USDC, minimum_received: 990_000_000n },
     *       b: { token: WETH, minimum_received: 396_000_000_000_000_000n },
     *   });
     *   await operation.dispatch();
     */
    async prepare_remove_liquidity( params: RemoveLiquidityParams ): Promise<PreparedSafeSwapOperation>
    {
        assert_distinct_tokens( params.a.token, params.b.token, "liquidity" );
        assert_positive_amount( "liquidity", params.liquidity );
        assert_ticks( params.tick_lower, params.tick_upper, params.pool_info.tick_spacing );

        const preferred_stake_token  =  resolve_explicit_preferred_stake_token( params.preferred_stake_token, params.a.token, params.b.token );

        const call  =  encodeFunctionData({
            abi:          SAFESWAP_ABI,
            functionName: "remove_liquidity",
            args:         [{
                pool_info:  params.pool_info,
                tick_lower: params.tick_lower,
                tick_upper: params.tick_upper,
                liquidity:  params.liquidity,
                minimum_received_a: { token: params.a.token, amount: params.a.minimum_received },
                minimum_received_b: { token: params.b.token, amount: params.b.minimum_received },
            }],
        });

        const operation  =  await this.#prepare_with_auto_stake_token( call, params.a.token, params.b.token, [], preferred_stake_token );
        return this.#attach_operation_description( operation, "remove_liquidity", async ( opts ) => {
            const minimum_a  =  await this.#render_token_amount( params.a.token, params.a.minimum_received, opts );
            const minimum_b  =  await this.#render_token_amount( params.b.token, params.b.minimum_received, opts );
            return `Remove ${ String(params.liquidity) } liquidity from tick ${ params.tick_lower } to ${ params.tick_upper }, receiving at least ${ minimum_a } and ${ minimum_b }.`;
        });
    }

    /**
     * Prepare a donation of both tokens to the pool's in-range liquidity providers.
     * Both amounts come from bond fundings.
     *
     * @example
     *   const operation = await safeswap.prepare_donate({
     *       a: { token: USDC, amount: 100_000_000n },
     *       b: { token: WETH, amount: 40_000_000_000_000_000n },
     *       pool_info: { fee: 3000, tick_spacing: 60 },
     *   });
     *   await operation.dispatch();
     */
    async prepare_donate( params: DonateParams ): Promise<PreparedSafeSwapOperation>
    {
        assert_distinct_tokens( params.a.token, params.b.token, "donation" );
        assert_positive_amount( "a.amount", params.a.amount );
        assert_positive_amount( "b.amount", params.b.amount );

        const preferred_stake_token  =  resolve_explicit_preferred_stake_token( params.preferred_stake_token, params.a.token, params.b.token );

        const call  =  encodeFunctionData({
            abi:          SAFESWAP_ABI,
            functionName: "donate",
            args:         [{ pool_info: params.pool_info }],
        });

        const preferred_fundings  =  [
            { token: params.a.token, amount: params.a.amount },
            { token: params.b.token, amount: params.b.amount },
        ];

        const operation  =  await this.#prepare_with_auto_stake_token( call, params.a.token, params.b.token, preferred_fundings, preferred_stake_token );
        return this.#attach_operation_description( operation, "donate", async ( opts ) => {
            const amount_a  =  await this.#render_token_amount( params.a.token, params.a.amount, opts );
            const amount_b  =  await this.#render_token_amount( params.b.token, params.b.amount, opts );
            return `Donate ${ amount_a } and ${ amount_b } to in-range liquidity providers.`;
        });
    }

    async #prepare_with_auto_stake_token(
        call: Hex,
        token_a: Address,
        token_b: Address,
        preferred_fundings: TokenAmount[],
        explicit_preferred_stake_token: Address | undefined
    ): Promise<Bond>
    {
        if(  explicit_preferred_stake_token !== undefined  )
        {
            return await this.#prepare_with_stake_token( call, preferred_fundings, explicit_preferred_stake_token );
        }

        const { token0, token1 }  =  get_ordered_pool_tokens( token_a, token_b );
        const [ token0_bond, token1_bond ]  =  await Promise.all([
            this.#prepare_with_stake_token( call, preferred_fundings, token0 ),
            this.#prepare_with_stake_token( call, preferred_fundings, token1 ),
        ]);
        const [ token0_can_pay, token1_can_pay ]  =  await Promise.all([ can_pay_bond( token0_bond ), can_pay_bond( token1_bond ) ]);

        if(  token0_can_pay  &&  token1_can_pay  )
        {
            if(  is_native_token( token0_bond.execution_data.stake.token )  )  return token0_bond;
            if(  is_native_token( token1_bond.execution_data.stake.token )  )  return token1_bond;
            return token0_bond;
        }
        if(  token1_can_pay  )  return token1_bond;

        return token0_bond;
    }

    async #prepare_with_stake_token( call: Hex, preferred_fundings: TokenAmount[], preferred_stake_token: Address ): Promise<Bond>
    {
        return await this.#bondRoute.prepare({
            protocol: this.safeswap_address,
            call,
            preferred_stake_token,
            preferred_fundings,
        });
    }

    #attach_operation_description(
        bond: Bond,
        kind: SafeSwapOperationKind,
        render_description: ( opts?: RenderDescriptionOpts ) => Promise<string>
    ): PreparedSafeSwapOperation
    {
        return Object.assign( bond, { kind, render_description });
    }

    async #render_token_amount( token: Address, amount: bigint, opts?: RenderDescriptionOpts ): Promise<string>
    {
        const metadata  =  await this.#get_token_display_metadata( token, opts );
        return `${ formatUnits( amount, metadata.decimals ) } ${ metadata.symbol }`;
    }

    async #get_token_display_metadata( token: Address, opts?: RenderDescriptionOpts ): Promise<TokenDisplayMetadata>
    {
        if(  is_native_token( token )  )  return opts?.native_token ?? { symbol: "ETH", decimals: 18 };

        const key  =  token.toLowerCase();
        const cached  =  this.#tokenMetadataCache.get( key );
        if(  cached !== undefined  )  return await cached;

        const promise  =  this.#fetch_token_display_metadata( token );
        this.#tokenMetadataCache.set( key, promise );
        return await promise;
    }

    async #fetch_token_display_metadata( token: Address ): Promise<TokenDisplayMetadata>
    {
        const [ decimals, symbol ]  =  await Promise.all([
            this.#bondRoute.public_client.readContract({
                address:      token,
                abi:          ERC20_METADATA_ABI,
                functionName: "decimals",
            }),
            this.#bondRoute.public_client.readContract({
                address:      token,
                abi:          ERC20_METADATA_ABI,
                functionName: "symbol",
            }),
        ]);
        return { decimals: Number( decimals ), symbol: String( symbol ) };
    }


    // ━━━━  READ-ONLY HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * Compute the Uniswap V4 pool ID for a given token pair and pool configuration.
     * Tokens can be passed in any order; SafeSwap sorts them internally.
     */
    async get_pool_id( token_a: Address, token_b: Address, pool_info: PoolInfo ): Promise<Hex>
    {
        return await this.#bondRoute.public_client.readContract({
            address:      this.safeswap_address,
            abi:          SAFESWAP_ABI,
            functionName: "__OFF_CHAIN__get_pool_id",
            args:         [ token_a, token_b, pool_info ],
        }) as Hex;
    }

    /**
     * Read a user's SafeSwap LP position from the PoolManager.
     *
     * @param pool_id  Obtain via `get_pool_id()`.
     */
    async get_position_info( pool_id: Hex, user: Address, tick_lower: number, tick_upper: number ): Promise<PositionInfo>
    {
        const [ liquidity, fee_growth_inside_0_last_x128, fee_growth_inside_1_last_x128 ]  =
            await this.#bondRoute.public_client.readContract({
                address:      this.safeswap_address,
                abi:          SAFESWAP_ABI,
                functionName: "__OFF_CHAIN__get_position_info",
                args:         [ pool_id, user, tick_lower, tick_upper ],
            }) as [ bigint, bigint, bigint ];

        return { liquidity, fee_growth_inside_0_last_x128, fee_growth_inside_1_last_x128 };
    }


    // ━━━━  BOND MANAGEMENT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /** Return all in-progress bonds in storage for the current account. */
    async list_pending(): Promise<Bond[]>
    {
        return await this.#bondRoute.list_pending();
    }

    /**
     * Poll a bond until settled, calling `on_update` on each tick.
     * Returns a stop function.
     */
    watch_bond( bond: Bond, on_update: ( snapshot: BondSnapshot ) => void | Promise<void>, opts?: { interval_ms?: number } ): () => void
    {
        return this.#bondRoute.watch_bond( bond, on_update, opts );
    }

    /** Poll pending storage records, calling `on_update` on each tick. Returns a stop function. */
    watch_pending( on_update: ( bonds: Bond[] ) => void | Promise<void>, opts?: { interval_ms?: number } ): () => void
    {
        return this.#bondRoute.watch_pending( on_update, opts );
    }

    /** Serialize a bond to portable JSON for cross-device or cross-session handoff. */
    serialize_bond( bond: Bond ): string
    {
        return this.#bondRoute.serialize_bond( bond );
    }

    /** Parse a previously-serialized bond back into an SDK-attached Bond instance. */
    deserialize_bond( json: string ): Bond
    {
        return this.#bondRoute.deserialize_bond( json );
    }
}

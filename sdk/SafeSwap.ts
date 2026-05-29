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
//   4. Prepare + dispatch: `const bond = await safeswap.swap_exact_input({ ... })`
//
// No external dependencies beyond viem and @bondroute/sdk.
// Storage and recovery are handled by the embedded BondRoute instance.

import {
    decodeErrorResult,
    encodeFunctionData,
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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// TYPES
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/** Re-export Bond and BondSnapshot so callers don't need to import BondRoute SDK directly. */
export type { Bond, BondSnapshot, BondConstraints, ExecutionData, TokenAmount };

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

/** Decode SafeSwap revert output against the SDK's bundled SafeSwap ABI. */
export function decode_safeswap_revert( output: Hex ): { name: string, args: readonly unknown[] } | null
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
 *   const bond = await safeswap.swap_exact_input({
 *       input:  { token: USDC, exact_amount: 1000_000_000n },
 *       output: { token: WETH, minimum_amount: 0n },
 *       pool_info: { fee: 3000, tick_spacing: 60 },
 *   });
 *   await bond.dispatch();
 *   if (bond.status === "executed") { ... }
 */
export class SafeSwap {

    readonly #bondRoute: BondRoute;
    readonly safeswap_address: Address;

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
        return new SafeSwap( bondRoute, opts.safeswap_address ?? SAFESWAP_ADDRESS );
    }


    // ━━━━  OPERATIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * Prepare a swap where the input amount is fixed and the output amount is at least `output.minimum_amount`.
     * Returns a prepared Bond; call `bond.dispatch()` to execute.
     *
     * @example
     *   const bond = await safeswap.swap_exact_input({
     *       input:  { token: USDC, exact_amount: 1000_000_000n },
     *       output: { token: WETH, minimum_amount: 390_000_000_000_000_000n },
     *       pool_info: { fee: 3000, tick_spacing: 60 },
     *   });
     *   await bond.dispatch();
     */
    async swap_exact_input( params: SwapExactInputParams ): Promise<Bond>
    {
        const call  =  encodeFunctionData({
            abi:          SAFESWAP_ABI,
            functionName: "swap_exact_input",
            args:         [{
                token_out:              params.output.token,
                minimum_output_amount:  params.output.minimum_amount,
                pool_info:              params.pool_info,
            }],
        });

        return await this.#bondRoute.prepare({
            protocol:           this.safeswap_address,
            call,
            preferred_fundings: [{ token: params.input.token, amount: params.input.exact_amount }],
        });
    }

    /**
     * Prepare a swap where the output amount is exact and input is capped at `input.maximum_amount`.
     * Reverts if required input exceeds the cap. Returns a prepared Bond.
     *
     * @example
     *   const bond = await safeswap.swap_exact_output({
     *       input:  { token: USDC, maximum_amount: 1100_000_000n },
     *       output: { token: WETH, exact_amount: 400_000_000_000_000_000n },
     *       pool_info: { fee: 3000, tick_spacing: 60 },
     *   });
     *   await bond.dispatch();
     */
    async swap_exact_output( params: SwapExactOutputParams ): Promise<Bond>
    {
        const call  =  encodeFunctionData({
            abi:          SAFESWAP_ABI,
            functionName: "swap_exact_output",
            args:         [{
                token_out:             params.output.token,
                exact_output_amount:   params.output.exact_amount,
                pool_info:             params.pool_info,
            }],
        });

        return await this.#bondRoute.prepare({
            protocol:           this.safeswap_address,
            call,
            preferred_fundings: [{ token: params.input.token, amount: params.input.maximum_amount }],
        });
    }

    /**
     * Prepare an add-liquidity operation. Both token amounts come from bond fundings.
     * `minimum_added` guards against slippage during position minting.
     *
     * @example
     *   const bond = await safeswap.add_liquidity({
     *       a: { token: USDC, amount: 1000_000_000n, minimum_added: 990_000_000n },
     *       b: { token: WETH, amount: 400_000_000_000_000_000n, minimum_added: 396_000_000_000_000_000n },
     *       pool_info: { fee: 3000, tick_spacing: 60 },
     *       tick_lower: -887220, tick_upper: 887220,
     *   });
     *   await bond.dispatch();
     */
    async add_liquidity( params: AddLiquidityParams ): Promise<Bond>
    {
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

        return await this.#prepare_with_auto_stake_token( call, params.a.token, params.b.token, preferred_fundings, preferred_stake_token );
    }

    /**
     * Prepare a remove-liquidity operation. Tokens come from the position; no fundings needed.
     * `minimum_received` guards against slippage during position burn.
     *
     * @example
     *   const bond = await safeswap.remove_liquidity({
     *       pool_info: { fee: 3000, tick_spacing: 60 },
     *       tick_lower: -887220, tick_upper: 887220,
     *       liquidity: 500_000_000_000_000n,
     *       a: { token: USDC, minimum_received: 990_000_000n },
     *       b: { token: WETH, minimum_received: 396_000_000_000_000_000n },
     *   });
     *   await bond.dispatch();
     */
    async remove_liquidity( params: RemoveLiquidityParams ): Promise<Bond>
    {
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

        return await this.#prepare_with_auto_stake_token( call, params.a.token, params.b.token, [], preferred_stake_token );
    }

    /**
     * Prepare a donation of both tokens to the pool's in-range liquidity providers.
     * Both amounts come from bond fundings.
     *
     * @example
     *   const bond = await safeswap.donate({
     *       a: { token: USDC, amount: 100_000_000n },
     *       b: { token: WETH, amount: 40_000_000_000_000_000n },
     *       pool_info: { fee: 3000, tick_spacing: 60 },
     *   });
     *   await bond.dispatch();
     */
    async donate( params: DonateParams ): Promise<Bond>
    {
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

        return await this.#prepare_with_auto_stake_token( call, params.a.token, params.b.token, preferred_fundings, preferred_stake_token );
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

// SPDX-License-Identifier: MIT
//
//  ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
//  ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
//  ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
//  ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
//  ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
//  ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
//  ━━━━━━━━━━━━━━━  MEV protection for traders. Repricing revenue for LPs.  ━━━━━━━━━━━━━━━
//
// SafeSwap SDK — single-file TypeScript client wrapping BondRoute for SafeSwap operations.
//
// The protocol is two BondRoute-protected contracts: a canonical SwapRouter (swaps + quoting + hook registry) and an
// NFT position manager (LP lifecycle: create / add / remove / collect). This SDK mirrors that split with two objects:
//
//   safeswap.swaps      → SafeSwapSwaps      (exact-input / exact-output swaps, quoting, pool ids)
//   safeswap.positions  → SafeSwapPositions  (create / add / remove / collect NFT-backed LP positions)
//
// QUICK INTEGRATION:
//   1. Copy this file into your project (or install once published as @safeswap/sdk)
//   2. Install peer deps: `npm install viem @bondroute/sdk`
//   3. Initialize once:   `const safeswap = await SafeSwap.init({ on_pending_bond: ..., ... })`
//   4. Prepare + dispatch: `const op = await safeswap.swaps.prepare_swap_exact_input({ ... }); await op.dispatch();`
//
// One init scans storage for unfinished bonds across BOTH surfaces and routes them through `on_pending_bond`.
// No external dependencies beyond viem and @bondroute/sdk.

import {
    decodeEventLog,
    decodeErrorResult,
    encodeFunctionData,
    formatUnits,
    hashTypedData,
    parseAbi,
    type Address,
    type Hex,
    type Log,
    type PublicClient,
    type WalletClient,
    type Account,
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

/** Canonical SafeSwap SwapRouter address (same across all chains). ***TODO*** Set before release. */
export const SAFESWAP_ROUTER_ADDRESS  =  "0x0000000000000000000000000000000000000000" as const;
/** Canonical SafeSwap NFT position-manager address (same across all chains). ***TODO*** Set before release. */
export const SAFESWAP_NFT_ADDRESS     =  "0x0000000000000000000000000000000000000000" as const;

const ZERO_ADDRESS  =  "0x0000000000000000000000000000000000000000" as const;

/** Highest base fee a config hook encodes (3 BCD digits → 0..999 bps, i.e. 0.00%..9.99%). */
const MAX_BASE_FEE_BPS    =  999;
/** Highest capture share a config hook encodes (one BCD digit r → 10·r, capped at 90). */
const MAX_REBATE_PERCENT  =  90;
/** Capture is quantized to whole 10% steps (the single rebate digit). */
const REBATE_PERCENT_STEP =  10;


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// TYPES
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/** Re-export BondRoute primitives so callers don't need to import the BondRoute SDK directly. */
export type { Bond, BondSnapshot, BondConstraints, ExecutionData, TokenAmount };

export type SafeSwapOperationKind =
    | "swap_exact_input"
    | "swap_exact_output"
    | "create_position"
    | "add_liquidity"
    | "remove_liquidity"
    | "collect_fees";

export type TokenDisplayMetadata = {
    symbol:   string;
    decimals: number;
};

export type RenderDescriptionOpts = {
    native_token?: TokenDisplayMetadata;
};

/** A prepared SafeSwap operation: a BondRoute `Bond` enriched with the operation kind and a lazy description renderer. */
export type PreparedSafeSwapOperation = Bond & {
    kind: SafeSwapOperationKind;
    render_description: ( opts?: RenderDescriptionOpts ) => Promise<string>;
    get_signing_preview: () => Promise<SafeSwapSigningPreview>;
    sign_verified_execution: () => Promise<Hex>;
};

export type SafeSwapSigningField = {
    name:  string;
    type:  "string" | "address";
    value: string;
};

export type SafeSwapSigningPreview = {
    kind:          SafeSwapOperationKind;
    digest:        Hex;
    type_hash:     Hex;
    type_string:   string;
    domain: {
        name:              string;
        version:           string;
        chainId:           bigint;
        verifyingContract: Address;
    };
    primary_type:  "ExecuteBondAs";
    action_type:   string;
    action_field:  string;
    fields:        SafeSwapSigningField[];
    fundings:      TokenAmount[];
    stake:         TokenAmount;
    salt:          bigint;
    protocol:      Address;
    typed_data: {
        domain: {
            name:              string;
            version:           string;
            chainId:           bigint;
            verifyingContract: Address;
        };
        primaryType: "ExecuteBondAs";
        types: Record<string, { name: string, type: string }[]>;
        message: Record<string, unknown>;
    };
};

/**
 * SafeSwap pool configuration shared by all SafeSwap operations.
 * @param base_fee_bps Base LP fee in basis points (1 bps = 0.01%), 0..999. Selects the config hook.
 * @param rebate_percent LP capture share in percent (0..90, in 10% steps). Selects the config hook and the surplus share.
 * @param tick_spacing Uniswap V4 pool tick spacing.
 */
export type PoolInfo = {
    base_fee_bps:   number;
    rebate_percent: number;
    tick_spacing:   number;
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

export type SwapQuoteExactInputParams = {
    token_in:  Address;
    token_out: Address;
    pool_info: PoolInfo;
    amount_in: bigint;
};

export type SwapQuoteExactOutputParams = {
    token_in:            Address;
    token_out:           Address;
    pool_info:           PoolInfo;
    exact_output_amount: bigint;
};

export type SwapExactInputQuote = {
    /** Output the user would receive, net of the SafeSwap protocol fee, at the estimated total fee. */
    expected_net_output: bigint;
    /** Total LP fee (base + repricing) the hook would apply, in Uniswap V4 pips (100 pips = 1 bps). */
    total_fee_pips:      number;
    /** Estimated pool price movement in ticks (labelled basis points by the contract). */
    movement_bps:        bigint;
};

export type SwapExactOutputQuote = {
    /** Input the user must fund to receive `exact_output_amount` net of the protocol fee, at the estimated total fee. */
    required_input: bigint;
    /** Total LP fee (base + repricing) the hook would apply, in Uniswap V4 pips (100 pips = 1 bps). */
    total_fee_pips: number;
    /** Estimated pool price movement in ticks (labelled basis points by the contract). */
    movement_bps:   bigint;
};

/**
 * Create a brand-new NFT-backed position. Both token amounts come from bond fundings; one LP NFT is minted to the user.
 * @param sqrt_price_x96 Initial pool price (Q64.96). Used only if the pool has not been initialized yet; otherwise it must
 *        equal the live price or the contract reverts.
 */
export type CreatePositionParams = {
    pool_info:              PoolInfo;
    sqrt_price_lower_x96:   bigint;
    sqrt_price_upper_x96:   bigint;
    liquidity:              bigint;
    sqrt_price_x96:         bigint;
    a: {
        token:  Address;
        amount: bigint;
        minimum_deposited: bigint;
    };
    b: {
        token:  Address;
        amount: bigint;
        minimum_deposited: bigint;
    };
    /**
     * Optional stake-token preference (must be `a.token` or `b.token`). If omitted, the SDK prepares both pool-token stake
     * candidates and picks an affordable one from current balances.
     */
    preferred_stake_token?: Address;
};

/**
 * Add liquidity to an existing NFT-backed position. Both token amounts come from bond fundings.
 * `amount` is the committed funding cap for each token; `minimum_deposited` is the slippage floor on what is actually
 * deposited for the requested `liquidity`.
 */
export type AddPositionLiquidityParams = {
    token_id:  bigint;
    liquidity: bigint;
    a: {
        token:  Address;
        amount: bigint;
        minimum_deposited: bigint;
    };
    b: {
        token:  Address;
        amount: bigint;
        minimum_deposited: bigint;
    };
    preferred_stake_token?: Address;
};

/** Remove liquidity from an existing NFT-backed position. Released tokens go to the position owner; no fundings needed. */
export type RemovePositionLiquidityParams = {
    token_id:  bigint;
    liquidity: bigint;
    a: {
        token:  Address;
        minimum_received: bigint;
    };
    b: {
        token:  Address;
        minimum_received: bigint;
    };
    preferred_stake_token?: Address;
};

/** Collect accrued fees from an existing NFT-backed position; no fundings needed. */
export type CollectFeesParams = {
    token_id: bigint;
    a: {
        token:  Address;
        minimum_received: bigint;
    };
    b: {
        token:  Address;
        minimum_received: bigint;
    };
    preferred_stake_token?: Address;
};

/** Immutable metadata for an NFT-backed SafeSwap LP position (mirrors the on-chain `SafeSwapPositionInfo`). */
export type SafeSwapPositionInfo = {
    hook:           Address;
    token0:         Address;
    token1:         Address;
    base_fee_bps:   number;
    rebate_percent: number;
    tick_spacing:   number;
    tick_lower:     number;
    tick_upper:     number;
};

/** Live Uniswap V4 state for a position, read directly from the PoolManager. */
export type PositionState = {
    liquidity:                     bigint;
    fee_growth_inside_0_last_x128: bigint;
    fee_growth_inside_1_last_x128: bigint;
};

export type ParsedSafeSwapRevert =
    | {
        kind:             "slippage_exceeded";
        description:      string;
        amount_received:  bigint;
        minimum_required: bigint;
    }
    | {
        kind:             "maximum_input_exceeded";
        description:      string;
        required_input:   bigint;
        maximum_required: bigint;
    }
    | {
        kind:             "one_sided_deposit_mismatch";
        description:      string;
        expected_token:   Address;
        minimum_required: bigint;
    }
    | {
        kind:            "modify_liquidity_tokens_mismatch";
        description:     string;
        token0:          Address;
        token1:          Address;
        amount_a_token:  Address;
        amount_b_token:  Address;
    }
    | {
        kind:            "funding_declaration_mismatch";
        description:     string;
        declared_token:  Address;
        declared_amount: bigint;
        funded_token:    Address;
        funded_amount:   bigint;
    }
    | {
        kind:            "invalid_liquidity_modification";
        description:     string;
        token_id:        bigint;
        liquidity_delta: bigint;
        funding_count:   bigint;
    }
    | {
        kind:        "position_info_mismatch";
        description: string;
        token_id:    bigint;
    }
    | {
        kind:        "position_unauthorized";
        description: string;
        token_id:    bigint;
        caller:      Address;
        owner:       Address;
    }
    | {
        kind:                    "pool_initialization_price_mismatch";
        description:             string;
        pool_id:                 Hex;
        current_sqrt_price_x96:  bigint;
        expected_sqrt_price_x96: bigint;
    }
    | {
        kind:           "hook_config_not_registered";
        description:    string;
        base_fee_bps:   number;
        rebate_percent: number;
    }
    | {
        kind:        "unsupported_call";
        description: string;
    }
    | {
        kind:        "unauthorized";
        description: string;
        caller:      Address;
        expected:    Address;
    }
    | {
        kind:        "invalid";
        description: string;
        field:       string;
        value:       bigint;
    }
    | {
        kind:        "transfer_failed";
        description: string;
        token:       Address;
        recipient:   Address;
        amount:      bigint;
    }
    | {
        kind:           "signed_swap_input_mismatch";
        description:    string;
        signed_token:   Address;
        signed_amount:  bigint;
        funded_token:   Address;
        funded_amount:  bigint;
    }
    | {
        kind:             "repricing_fee_exceeds_v4_limit";
        description:      string;
        total_fee_pips:   bigint;
        maximum_fee_pips: bigint;
    }
    | {
        kind:        "unknown";
        description: string;
    };

export type SafeSwapOpts = {
    public_client:  PublicClient;
    wallet_client:  WalletClient;
    account:        Account | Address;
    /** Override the SafeSwap SwapRouter address (advanced — for forks and testnets). */
    router_address?: Address;
    /** Override the SafeSwap NFT position-manager address (advanced — for forks and testnets). */
    nft_address?:    Address;
    /** Override the BondRoute contract address (advanced — for forks and testnets). */
    bondroute_address?: Address;
    /**
     * Required. Invoked once per unfinished bond discovered in storage at init (across both swap and position surfaces).
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
// ABI (minimal — only what the SDK actually calls or decodes)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// PoolInfo tuple:   (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing)
// TokenAmount tuple: (address token, uint256 amount)

/** SafeSwap SwapRouter surface: swaps + quoting + pool-id + hook registry resolution. */
export const SAFESWAP_ROUTER_ABI  =  parseAbi([
    "function swap_exact_input((address token_in, uint256 input_amount, address token_out, uint256 minimum_output_amount, (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info) params) external",
    "function swap_exact_output((address token_in, uint256 maximum_input_amount, address token_out, uint256 exact_output_amount, (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info) params) external",

    "function get_hook(uint16 base_fee_bps, uint8 rebate_percent) external view returns (address hook)",

    "function __OFF_CHAIN__get_pool_id(address token_a, address token_b, (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info) external view returns (bytes32 pool_id)",
    "function __OFF_CHAIN__quote_swap_exact_input(address token_in, address token_out, (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info, uint256 amount_in) external view returns (uint256 expected_net_output, uint24 total_fee_pips, uint256 movement_bps)",
    "function __OFF_CHAIN__quote_swap_exact_output(address token_in, address token_out, (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info, uint256 exact_output_amount) external view returns (uint256 required_input, uint24 total_fee_pips, uint256 movement_bps)",
]);

/** SafeSwap NFT position-manager surface: LP lifecycle + position getters + the ERC721 mint event. */
export const SAFESWAP_NFT_ABI  =  parseAbi([
    "function create_position(((uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info, uint160 sqrt_price_lower_x96, uint160 sqrt_price_upper_x96, uint128 liquidity, uint160 sqrt_price_x96, (address token, uint256 amount) maximum_deposit_a, uint256 minimum_deposit_a, (address token, uint256 amount) maximum_deposit_b, uint256 minimum_deposit_b) params) external",
    "function add_liquidity((uint256 token_id, uint128 liquidity, (address token, uint256 amount) maximum_deposit_a, uint256 minimum_deposit_a, (address token, uint256 amount) maximum_deposit_b, uint256 minimum_deposit_b) params) external",
    "function remove_liquidity((uint256 token_id, uint128 liquidity, (address token, uint256 amount) minimum_received_a, (address token, uint256 amount) minimum_received_b) params) external",
    "function collect_fees((uint256 token_id, (address token, uint256 amount) minimum_received_a, (address token, uint256 amount) minimum_received_b) params) external",

    "function get_lp_position(uint256 token_id) external view returns ((address hook, address token0, address token1, uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing, int24 tick_lower, int24 tick_upper) position_info)",
    "function __OFF_CHAIN__get_position_info(bytes32 pool_id, uint256 token_id, int24 tick_lower, int24 tick_upper) external view returns (uint128 liquidity, uint256 fee_growth_inside_0_last_x128, uint256 fee_growth_inside_1_last_x128)",

    "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
]);

const SAFESWAP_SIGNING_PROTOCOL_ABI  =  parseAbi([
    "function SigningDescriptor() external view returns (address)",
]);

const SAFESWAP_SIGNING_DESCRIPTOR_ABI  =  parseAbi([
    "function build_router_signing_values(bytes protected_call) external view returns (string[] display_values, address[] token_addresses)",
    "function build_nft_signing_values(address safe_swap_nft, bytes protected_call) external view returns (string[] display_values, address[] token_addresses)",
]);

/** Custom errors surfaced by SafeSwap execution and quoting (used to decode `bond.revert_output`). */
export const SAFESWAP_ERRORS_ABI  =  parseAbi([
    "error SlippageExceeded(uint256 amount_received, uint256 minimum_required)",
    "error MaximumInputExceeded(uint256 required_input, uint256 maximum_required)",
    "error OneSidedDepositMismatch(address expected_token, uint256 minimum_required)",
    "error ModifyLiquidityTokensMismatch(address token0, address token1, address amount_a_token, address amount_b_token)",
    "error FundingDeclarationMismatch(address declared_token, uint256 declared_amount, address funded_token, uint256 funded_amount)",
    "error InvalidLiquidityModification(uint256 token_id, int128 liquidity_delta, uint256 funding_count)",
    "error PositionInfoMismatch(uint256 token_id)",
    "error PositionUnauthorized(uint256 token_id, address caller, address owner)",
    "error PoolInitializationPriceMismatch(bytes32 pool_id, uint160 current_sqrt_price_x96, uint160 expected_sqrt_price_x96)",
    "error HookConfigNotRegistered(uint16 base_fee_bps, uint8 rebate_percent)",
    "error Unauthorized(address caller, address expected)",
    "error UnsupportedCall()",
    "error Invalid(string field, uint256 value)",
    "error TransferFailed(address token, address recipient, uint256 amount)",
    "error SignedSwapInputMismatch(address signed_token, uint256 signed_amount, address funded_token, uint256 funded_amount)",
    "error RepricingFeeExceedsV4Limit(uint256 total_fee_pips, uint256 maximum_fee_pips)",
]);

/** Combined ABI for revert decoding: every SafeSwap function, event, and custom error. */
export const SAFESWAP_ABI  =  [ ...SAFESWAP_ROUTER_ABI, ...SAFESWAP_NFT_ABI, ...SAFESWAP_ERRORS_ABI ] as const;

const ERC20_METADATA_ABI  =  parseAbi([
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
]);


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// REVERT PARSING
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

function as_bigint( value: unknown ): bigint   {  return typeof value === "bigint"  ?  value  :  BigInt( String( value ) );  }
function as_number( value: unknown ): number   {  return Number( as_bigint( value ) );  }
function as_address( value: unknown ): Address {  return String( value ) as Address;  }
function as_hex( value: unknown ): Hex         {  return String( value ) as Hex;  }
function as_string( value: unknown ): string   {  return String( value );  }

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

        case "MaximumInputExceeded": {
            const required_input    =  as_bigint( decoded.args[0] );
            const maximum_required  =  as_bigint( decoded.args[1] );
            return {
                kind:        "maximum_input_exceeded",
                description: `SafeSwap required input ${ String(required_input) } exceeds the committed maximum ${ String(maximum_required) }.`,
                required_input,
                maximum_required,
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

        case "ModifyLiquidityTokensMismatch": {
            const token0          =  as_address( decoded.args[0] );
            const token1          =  as_address( decoded.args[1] );
            const amount_a_token  =  as_address( decoded.args[2] );
            const amount_b_token  =  as_address( decoded.args[3] );
            return {
                kind:        "modify_liquidity_tokens_mismatch",
                description: `SafeSwap liquidity tokens (${ amount_a_token }, ${ amount_b_token }) do not match the pool tokens (${ token0 }, ${ token1 }).`,
                token0,
                token1,
                amount_a_token,
                amount_b_token,
            };
        }

        case "FundingDeclarationMismatch": {
            const declared_token   =  as_address( decoded.args[0] );
            const declared_amount  =  as_bigint( decoded.args[1] );
            const funded_token     =  as_address( decoded.args[2] );
            const funded_amount    =  as_bigint( decoded.args[3] );
            return {
                kind:        "funding_declaration_mismatch",
                description: `SafeSwap declared funding ${ String(declared_amount) } for ${ declared_token }, but BondRoute supplied ${ String(funded_amount) } for ${ funded_token }.`,
                declared_token,
                declared_amount,
                funded_token,
                funded_amount,
            };
        }

        case "InvalidLiquidityModification": {
            const token_id         =  as_bigint( decoded.args[0] );
            const liquidity_delta  =  as_bigint( decoded.args[1] );
            const funding_count    =  as_bigint( decoded.args[2] );
            return {
                kind:        "invalid_liquidity_modification",
                description: `SafeSwap rejected an invalid liquidity modification for token ${ String(token_id) }: liquidity delta ${ String(liquidity_delta) }, funding count ${ String(funding_count) }.`,
                token_id,
                liquidity_delta,
                funding_count,
            };
        }

        case "PositionInfoMismatch": {
            const token_id  =  as_bigint( decoded.args[0] );
            return {
                kind:        "position_info_mismatch",
                description: `SafeSwap pool configuration does not match the stored metadata for position ${ String(token_id) }.`,
                token_id,
            };
        }

        case "PositionUnauthorized": {
            const token_id  =  as_bigint( decoded.args[0] );
            const caller    =  as_address( decoded.args[1] );
            const owner     =  as_address( decoded.args[2] );
            return {
                kind:        "position_unauthorized",
                description: `SafeSwap caller ${ caller } is not authorized for position ${ String(token_id) } owned by ${ owner }.`,
                token_id,
                caller,
                owner,
            };
        }

        case "PoolInitializationPriceMismatch": {
            const pool_id                  =  as_hex( decoded.args[0] );
            const current_sqrt_price_x96   =  as_bigint( decoded.args[1] );
            const expected_sqrt_price_x96  =  as_bigint( decoded.args[2] );
            return {
                kind:        "pool_initialization_price_mismatch",
                description: `SafeSwap pool ${ pool_id } already exists at price ${ String(current_sqrt_price_x96) }; expected ${ String(expected_sqrt_price_x96) }.`,
                pool_id,
                current_sqrt_price_x96,
                expected_sqrt_price_x96,
            };
        }

        case "HookConfigNotRegistered": {
            const base_fee_bps    =  as_number( decoded.args[0] );
            const rebate_percent  =  as_number( decoded.args[1] );
            return {
                kind:        "hook_config_not_registered",
                description: `SafeSwap has no registered hook for base fee ${ String(base_fee_bps) } bps and capture ${ String(rebate_percent) }%.`,
                base_fee_bps,
                rebate_percent,
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

        case "UnsupportedCall":
            return { kind: "unsupported_call", description: "SafeSwap does not support this encoded call." };

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

        case "SignedSwapInputMismatch": {
            const signed_token   =  as_address( decoded.args[0] );
            const signed_amount  =  as_bigint( decoded.args[1] );
            const funded_token   =  as_address( decoded.args[2] );
            const funded_amount  =  as_bigint( decoded.args[3] );
            return {
                kind:        "signed_swap_input_mismatch",
                description: `SafeSwap swap funding ${ String(funded_amount) } for ${ funded_token } does not match the signed input ${ String(signed_amount) } for ${ signed_token }.`,
                signed_token,
                signed_amount,
                funded_token,
                funded_amount,
            };
        }

        case "RepricingFeeExceedsV4Limit": {
            const total_fee_pips    =  as_bigint( decoded.args[0] );
            const maximum_fee_pips  =  as_bigint( decoded.args[1] );
            return {
                kind:        "repricing_fee_exceeds_v4_limit",
                description: `SafeSwap total fee ${ String(total_fee_pips) } pips exceeds the Uniswap V4 limit of ${ String(maximum_fee_pips) } pips.`,
                total_fee_pips,
                maximum_fee_pips,
            };
        }

        default:
            return { kind: "unknown", description: `SafeSwap reverted with ${ decoded.name }.` };
    }
}

/** Return a user-facing explanation for SafeSwap revert output. */
export function explain_safeswap_revert( output: Hex ): string
{
    return parse_safeswap_revert( output ).description;
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SHARED HELPERS
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/** Internal context shared by both SafeSwap surfaces: one BondRoute instance and one token-metadata cache. */
type SafeSwapContext = {
    bond_route:           BondRoute;
    token_metadata_cache: Map<string, Promise<TokenDisplayMetadata>>;
};

function is_native_token( token: Address ): boolean
{
    return token.toLowerCase() === NATIVE_TOKEN.toLowerCase();
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

function assert_positive_amount( field: string, amount: bigint ): void
{
    if(  amount <= 0n  )  throw new Error( `${ field } must be greater than zero.` );
}

function assert_distinct_tokens( token_a: Address, token_b: Address, context: string ): void
{
    if(  token_a.toLowerCase() === token_b.toLowerCase()  )  throw new Error( `${ context } tokens must be different.` );
}

function assert_pool_info( pool_info: PoolInfo ): void
{
    if(  Number.isInteger( pool_info.base_fee_bps ) === false  ||  pool_info.base_fee_bps < 0  ||  pool_info.base_fee_bps > MAX_BASE_FEE_BPS  )
    {
        throw new Error( `pool_info.base_fee_bps must be a whole number of basis points between 0 and ${ MAX_BASE_FEE_BPS }.` );
    }
    if(  Number.isInteger( pool_info.rebate_percent ) === false  ||  pool_info.rebate_percent < 0  ||  pool_info.rebate_percent > MAX_REBATE_PERCENT  ||  pool_info.rebate_percent % REBATE_PERCENT_STEP !== 0  )
    {
        throw new Error( `pool_info.rebate_percent must be a multiple of ${ REBATE_PERCENT_STEP } between 0 and ${ MAX_REBATE_PERCENT }.` );
    }
    if(  pool_info.tick_spacing <= 0  )  throw new Error( "pool_info.tick_spacing must be greater than zero." );
}

function attach_operation_description(
    ctx: SafeSwapContext,
    bond: Bond,
    kind: SafeSwapOperationKind,
    render_description: ( opts?: RenderDescriptionOpts ) => Promise<string>
): PreparedSafeSwapOperation
{
    const get_signing_preview      =  async () => await build_signing_preview( ctx, bond, kind );
    const sign_verified_execution  =  async (): Promise<Hex> => await sign_signing_preview( ctx, await get_signing_preview() );
    return Object.assign( bond, {
        kind,
        render_description,
        get_signing_preview,
        sign_verified_execution,
        sign_execution: sign_verified_execution,
    });
}

function parse_eip712_types( type_string: string ): Record<string, { name: string, type: string }[]>
{
    const types: Record<string, { name: string, type: string }[]>  =  {};
    const definition_pattern  =  /([A-Za-z_][A-Za-z0-9_]*)\(([^)]*)\)/g;

    for(  const match of type_string.matchAll( definition_pattern )  )
    {
        const type_name  =  match[1]!;
        const body       =  match[2]!;
        types[ type_name ]  =  body === ""  ?  []  :  body.split( "," ).map(( field ) => {
            const parts  =  field.trim().split( /\s+/ );
            if(  parts.length !== 2  )  throw new Error( `Invalid EIP-712 field declaration: ${ field }.` );
            return { type: parts[0]!, name: parts[1]! };
        });
    }

    if(  types.ExecuteBondAs === undefined  )  throw new Error( "SafeSwap signing type string is missing ExecuteBondAs." );
    return types;
}

async function build_signing_preview( ctx: SafeSwapContext, bond: Bond, kind: SafeSwapOperationKind ): Promise<SafeSwapSigningPreview>
{
    const info   =  await bond.get_signing_info();
    const types  =  parse_eip712_types( info.type_string );
    const outer  =  types.ExecuteBondAs!;
    const custom_fields  =  outer.filter(( field ) => ! [ "fundings", "stake", "salt", "protocol" ].includes( field.name ) );
    if(  custom_fields.length !== 1  )  throw new Error( "SafeSwap signing envelope must contain exactly one action field." );

    const action_field  =  custom_fields[0]!;
    const action_fields =  types[ action_field.type ];
    if(  action_fields === undefined  )  throw new Error( `SafeSwap signing type is missing ${ action_field.type }.` );

    const descriptor  =  await ctx.bond_route.public_client.readContract({
        address:      bond.execution_data.protocol,
        abi:          SAFESWAP_SIGNING_PROTOCOL_ABI,
        functionName: "SigningDescriptor",
    }) as Address;

    const is_router  =  kind === "swap_exact_input" || kind === "swap_exact_output";
    const [ display_values, token_addresses ]  =  await ctx.bond_route.public_client.readContract({
        address:      descriptor,
        abi:          SAFESWAP_SIGNING_DESCRIPTOR_ABI,
        functionName: is_router ? "build_router_signing_values" : "build_nft_signing_values",
        args:         is_router ? [ bond.execution_data.call ] : [ bond.execution_data.protocol, bond.execution_data.call ],
    }) as [ string[], Address[] ];

    let display_index  =  0;
    let address_index  =  0;
    const fields: SafeSwapSigningField[]  =  action_fields.map(( field ) => {
        if(  field.type === "string"  )
        {
            const value  =  display_values[ display_index++ ];
            if(  value === undefined  )  throw new Error( `Missing SafeSwap signing value for ${ field.name }.` );
            return { name: field.name, type: "string", value };
        }
        if(  field.type === "address"  )
        {
            const value  =  token_addresses[ address_index++ ];
            if(  value === undefined  )  throw new Error( `Missing SafeSwap token anchor for ${ field.name }.` );
            return { name: field.name, type: "address", value };
        }
        throw new Error( `Unsupported SafeSwap signing field type ${ field.type }.` );
    });
    if(  display_index !== display_values.length || address_index !== token_addresses.length  )
    {
        throw new Error( "SafeSwap signing descriptor returned unexpected extra values." );
    }

    const action_message  =  Object.fromEntries( fields.map(( field ) => [ field.name, field.value ]) );
    const message: Record<string, unknown>  =  {
        fundings: bond.execution_data.fundings,
        stake:    bond.execution_data.stake,
        salt:     bond.execution_data.salt,
        protocol: bond.execution_data.protocol,
        [ action_field.name ]: action_message,
    };
    const domain  =  {
        name:              info.domain.name,
        version:           info.domain.version,
        chainId:           BigInt( info.domain.chainId ),
        verifyingContract: info.domain.verifyingContract,
    };
    const typed_data  =  { domain, primaryType: "ExecuteBondAs" as const, types, message };
    const digest      =  hashTypedData( typed_data as any );
    if(  digest.toLowerCase() !== info.digest.toLowerCase()  )
    {
        throw new Error( "SafeSwap signing values do not match the BondRoute signing digest." );
    }

    return {
        kind,
        digest,
        type_hash: info.type_hash,
        type_string: info.type_string,
        domain,
        primary_type: "ExecuteBondAs",
        action_type: action_field.type,
        action_field: action_field.name,
        fields,
        fundings: bond.execution_data.fundings,
        stake: bond.execution_data.stake,
        salt: bond.execution_data.salt,
        protocol: bond.execution_data.protocol,
        typed_data,
    };
}

async function sign_signing_preview( ctx: SafeSwapContext, preview: SafeSwapSigningPreview ): Promise<Hex>
{
    const sign_typed_data  =  (ctx.bond_route.wallet_client as any).signTypedData;
    if(  typeof sign_typed_data === "function"  )
    {
        return await sign_typed_data.call( ctx.bond_route.wallet_client, {
            account: ctx.bond_route.account,
            ...preview.typed_data,
        });
    }

    const account  =  ctx.bond_route.wallet_client.account as any;
    if(  typeof account?.signTypedData === "function"  )  return await account.signTypedData( preview.typed_data );
    throw new Error( "Wallet client cannot sign verified SafeSwap EIP-712 typed data." );
}

async function get_token_display_metadata( ctx: SafeSwapContext, token: Address, opts?: RenderDescriptionOpts ): Promise<TokenDisplayMetadata>
{
    if(  is_native_token( token )  )  return opts?.native_token ?? native_currency_metadata( ctx );

    const key     =  token.toLowerCase();
    const cached  =  ctx.token_metadata_cache.get( key );
    if(  cached !== undefined  )  return await cached;

    const promise  =  fetch_token_display_metadata( ctx, token );
    ctx.token_metadata_cache.set( key, promise );
    return await promise;
}

// The native gas token has no on-chain symbol/decimals source (that is why the contracts read it from ChainConfig). Off-chain
// the standard source is viem's chain.nativeCurrency (EIP-3085), populated when the client is created with a chain. Falls back
// to ETH/18 when the client has no chain configured; callers can always override via `RenderDescriptionOpts.native_token`.
function native_currency_metadata( ctx: SafeSwapContext ): TokenDisplayMetadata
{
    const native  =  ctx.bond_route.public_client.chain?.nativeCurrency;
    if(  native !== undefined  )  return { symbol: native.symbol, decimals: native.decimals };
    return { symbol: "ETH", decimals: 18 };
}

async function fetch_token_display_metadata( ctx: SafeSwapContext, token: Address ): Promise<TokenDisplayMetadata>
{
    const [ decimals, symbol ]  =  await Promise.all([
        ctx.bond_route.public_client.readContract({ address: token, abi: ERC20_METADATA_ABI, functionName: "decimals" }),
        ctx.bond_route.public_client.readContract({ address: token, abi: ERC20_METADATA_ABI, functionName: "symbol" }),
    ]);
    return { decimals: Number( decimals ), symbol: String( symbol ) };
}

async function render_token_amount( ctx: SafeSwapContext, token: Address, amount: bigint, opts?: RenderDescriptionOpts ): Promise<string>
{
    const metadata  =  await get_token_display_metadata( ctx, token, opts );
    return `${ formatUnits( amount, metadata.decimals ) } ${ metadata.symbol }`;
}

/**
 * Prepare a bond, auto-selecting an affordable pool token as the stake when no explicit preference is supplied.
 *
 * Mirrors the contract stake model: liquidity bonds stake a normalized share of the committed value in one pool token, so
 * the SDK quotes both token0 and token1 candidates and returns one the user can currently afford. If both are affordable,
 * native token wins (it doubles as gas), otherwise token0 by address order. If neither is affordable, token0 is returned so
 * BondRoute's normal balance error surfaces the shortfall.
 */
async function prepare_with_auto_stake_token(
    ctx: SafeSwapContext,
    protocol: Address,
    call: Hex,
    token_a: Address,
    token_b: Address,
    preferred_fundings: TokenAmount[],
    explicit_preferred_stake_token: Address | undefined
): Promise<Bond>
{
    if(  explicit_preferred_stake_token !== undefined  )
    {
        return await ctx.bond_route.prepare({ protocol, call, preferred_stake_token: explicit_preferred_stake_token, preferred_fundings });
    }

    const { token0, token1 }  =  get_ordered_pool_tokens( token_a, token_b );
    const [ token0_bond, token1_bond ]  =  await Promise.all([
        ctx.bond_route.prepare({ protocol, call, preferred_stake_token: token0, preferred_fundings }),
        ctx.bond_route.prepare({ protocol, call, preferred_stake_token: token1, preferred_fundings }),
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


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// SWAPS  (SafeSwap SwapRouter)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * SafeSwap swap surface. Wraps the canonical BondRoute-protected SwapRouter: exact-input / exact-output swaps, the swap
 * quoter (same simulator the hook uses, so quote == executed fee), pool-id derivation, and hook registry resolution.
 *
 * The pool's LP fee (base + repricing surplus share) is applied natively by the hook and accrues to LPs; the SDK only
 * surfaces the user's net amounts after the separate SafeSwap protocol fee.
 */
export class SafeSwapSwaps {

    readonly #ctx: SafeSwapContext;
    readonly router_address: Address;

    constructor( ctx: SafeSwapContext, router_address: Address )
    {
        this.#ctx            =  ctx;
        this.router_address  =  router_address;
    }


    // ━━━━  PREPARE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * Prepare a swap where the input amount is fixed and the output is at least `output.minimum_amount`.
     *
     * @example
     *   const op = await safeswap.swaps.prepare_swap_exact_input({
     *       input:  { token: USDC, exact_amount: 1000_000_000n },
     *       output: { token: WETH, minimum_amount: 390_000_000_000_000_000n },
     *       pool_info: { base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 },
     *   });
     *   await op.dispatch();
     */
    async prepare_swap_exact_input( params: SwapExactInputParams ): Promise<PreparedSafeSwapOperation>
    {
        assert_distinct_tokens( params.input.token, params.output.token, "swap" );
        assert_positive_amount( "input.exact_amount", params.input.exact_amount );
        assert_pool_info( params.pool_info );

        const call  =  encodeFunctionData({
            abi:          SAFESWAP_ROUTER_ABI,
            functionName: "swap_exact_input",
            args:         [{
                token_in:              params.input.token,
                input_amount:          params.input.exact_amount,
                token_out:             params.output.token,
                minimum_output_amount: params.output.minimum_amount,
                pool_info:             this.#encode_pool_info( params.pool_info ),
            }],
        });

        const operation  =  await this.#ctx.bond_route.prepare({
            protocol:           this.router_address,
            call,
            preferred_fundings: [{ token: params.input.token, amount: params.input.exact_amount }],
        });
        return attach_operation_description( this.#ctx, operation, "swap_exact_input", async ( opts ) => {
            const input   =  await render_token_amount( this.#ctx, params.input.token, params.input.exact_amount, opts );
            const output  =  await render_token_amount( this.#ctx, params.output.token, params.output.minimum_amount, opts );
            return `Swap exactly ${ input } for at least ${ output }.`;
        });
    }

    /**
     * Prepare a swap where the output is exact and input is capped at `input.maximum_amount`.
     * Reverts at execution if the required input (plus the LP fee charged on input) exceeds the cap.
     *
     * @example
     *   const op = await safeswap.swaps.prepare_swap_exact_output({
     *       input:  { token: USDC, maximum_amount: 1100_000_000n },
     *       output: { token: WETH, exact_amount: 400_000_000_000_000_000n },
     *       pool_info: { base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 },
     *   });
     *   await op.dispatch();
     */
    async prepare_swap_exact_output( params: SwapExactOutputParams ): Promise<PreparedSafeSwapOperation>
    {
        assert_distinct_tokens( params.input.token, params.output.token, "swap" );
        assert_positive_amount( "input.maximum_amount", params.input.maximum_amount );
        assert_positive_amount( "output.exact_amount", params.output.exact_amount );
        assert_pool_info( params.pool_info );

        const call  =  encodeFunctionData({
            abi:          SAFESWAP_ROUTER_ABI,
            functionName: "swap_exact_output",
            args:         [{
                token_in:             params.input.token,
                maximum_input_amount: params.input.maximum_amount,
                token_out:           params.output.token,
                exact_output_amount: params.output.exact_amount,
                pool_info:           this.#encode_pool_info( params.pool_info ),
            }],
        });

        const operation  =  await this.#ctx.bond_route.prepare({
            protocol:           this.router_address,
            call,
            preferred_fundings: [{ token: params.input.token, amount: params.input.maximum_amount }],
        });
        return attach_operation_description( this.#ctx, operation, "swap_exact_output", async ( opts ) => {
            const input   =  await render_token_amount( this.#ctx, params.input.token, params.input.maximum_amount, opts );
            const output  =  await render_token_amount( this.#ctx, params.output.token, params.output.exact_amount, opts );
            return `Swap up to ${ input } for exactly ${ output }.`;
        });
    }


    // ━━━━  QUOTING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * Quote an exact-input swap using the same simulator the hook uses at execution time, so the quoted total fee equals
     * the executed fee. Returns the user's net output (after the protocol fee), the total LP fee, and the price movement.
     */
    async quote_swap_exact_input( params: SwapQuoteExactInputParams ): Promise<SwapExactInputQuote>
    {
        assert_distinct_tokens( params.token_in, params.token_out, "swap" );
        assert_positive_amount( "amount_in", params.amount_in );
        assert_pool_info( params.pool_info );

        const [ expected_net_output, total_fee_pips, movement_bps ]  =  await this.#ctx.bond_route.public_client.readContract({
            address:      this.router_address,
            abi:          SAFESWAP_ROUTER_ABI,
            functionName: "__OFF_CHAIN__quote_swap_exact_input",
            args:         [ params.token_in, params.token_out, this.#encode_pool_info( params.pool_info ), params.amount_in ],
        }) as [ bigint, number, bigint ];

        return { expected_net_output, total_fee_pips: Number( total_fee_pips ), movement_bps };
    }

    /**
     * Quote an exact-output swap using the same simulator the hook uses at execution time. Returns the input required to
     * net `exact_output_amount`, the total LP fee, and the price movement.
     */
    async quote_swap_exact_output( params: SwapQuoteExactOutputParams ): Promise<SwapExactOutputQuote>
    {
        assert_distinct_tokens( params.token_in, params.token_out, "swap" );
        assert_positive_amount( "exact_output_amount", params.exact_output_amount );
        assert_pool_info( params.pool_info );

        const [ required_input, total_fee_pips, movement_bps ]  =  await this.#ctx.bond_route.public_client.readContract({
            address:      this.router_address,
            abi:          SAFESWAP_ROUTER_ABI,
            functionName: "__OFF_CHAIN__quote_swap_exact_output",
            args:         [ params.token_in, params.token_out, this.#encode_pool_info( params.pool_info ), params.exact_output_amount ],
        }) as [ bigint, number, bigint ];

        return { required_input, total_fee_pips: Number( total_fee_pips ), movement_bps };
    }


    // ━━━━  READ-ONLY HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /** Compute the Uniswap V4 pool id for a SafeSwap pool. Tokens may be passed in any order. */
    async get_pool_id( token_a: Address, token_b: Address, pool_info: PoolInfo ): Promise<Hex>
    {
        assert_distinct_tokens( token_a, token_b, "pool" );
        assert_pool_info( pool_info );

        return await this.#ctx.bond_route.public_client.readContract({
            address:      this.router_address,
            abi:          SAFESWAP_ROUTER_ABI,
            functionName: "__OFF_CHAIN__get_pool_id",
            args:         [ token_a, token_b, this.#encode_pool_info( pool_info ) ],
        }) as Hex;
    }

    /** Resolve the registered config-hook clone address for a `(base_fee_bps, rebate_percent)` profile. */
    async get_hook( base_fee_bps: number, rebate_percent: number ): Promise<Address>
    {
        assert_pool_info({ base_fee_bps, rebate_percent, tick_spacing: 1 });

        return await this.#ctx.bond_route.public_client.readContract({
            address:      this.router_address,
            abi:          SAFESWAP_ROUTER_ABI,
            functionName: "get_hook",
            args:         [ base_fee_bps, rebate_percent ],
        }) as Address;
    }

    #encode_pool_info( pool_info: PoolInfo ): { base_fee_bps: number, rebate_percent: number, tick_spacing: number }
    {
        return { base_fee_bps: pool_info.base_fee_bps, rebate_percent: pool_info.rebate_percent, tick_spacing: pool_info.tick_spacing };
    }
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// POSITIONS  (SafeSwap NFT position manager)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * SafeSwap LP position surface. Wraps the BondRoute-protected NFT position manager that owns the Uniswap V4 positions
 * (salt = token id) and exposes their lifecycle: create, add, remove, collect — plus the position getters.
 *
 * Each operation auto-selects an affordable pool token as the bond stake unless `preferred_stake_token` is given.
 */
export class SafeSwapPositions {

    readonly #ctx: SafeSwapContext;
    readonly nft_address: Address;

    constructor( ctx: SafeSwapContext, nft_address: Address )
    {
        this.#ctx          =  ctx;
        this.nft_address   =  nft_address;
    }


    // ━━━━  PREPARE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * Prepare a brand-new NFT-backed position. Both token amounts come from bond fundings; one LP NFT is minted to the user.
     * After dispatch, read the minted token id with `positions.get_minted_token_id( operation )`.
     *
     * @example
     *   const op = await safeswap.positions.prepare_create_position({
     *       pool_info: { base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 },
     *       sqrt_price_lower_x96, sqrt_price_upper_x96,
     *       liquidity: 500_000_000_000_000n,
     *       sqrt_price_x96: 79228162514264337593543950336n,
     *       a: { token: USDC, amount: 1000_000_000n, minimum_deposited: 990_000_000n },
     *       b: { token: WETH, amount: 400_000_000_000_000_000n, minimum_deposited: 396_000_000_000_000_000n },
     *   });
     *   await op.dispatch();
     */
    async prepare_create_position( params: CreatePositionParams ): Promise<PreparedSafeSwapOperation>
    {
        assert_distinct_tokens( params.a.token, params.b.token, "liquidity" );
        assert_positive_amount( "a.amount", params.a.amount );
        assert_positive_amount( "b.amount", params.b.amount );
        assert_positive_amount( "liquidity", params.liquidity );
        assert_positive_amount( "sqrt_price_x96", params.sqrt_price_x96 );
        assert_pool_info( params.pool_info );
        assert_positive_amount( "sqrt_price_lower_x96", params.sqrt_price_lower_x96 );
        assert_positive_amount( "sqrt_price_upper_x96", params.sqrt_price_upper_x96 );
        if(  params.sqrt_price_lower_x96 >= params.sqrt_price_upper_x96  )  throw new Error( "sqrt_price_lower_x96 must be less than sqrt_price_upper_x96." );

        const preferred_stake_token  =  resolve_explicit_preferred_stake_token( params.preferred_stake_token, params.a.token, params.b.token );

        const call  =  encodeFunctionData({
            abi:          SAFESWAP_NFT_ABI,
            functionName: "create_position",
            args:         [{
                pool_info:           this.#encode_pool_info( params.pool_info ),
                sqrt_price_lower_x96: params.sqrt_price_lower_x96,
                sqrt_price_upper_x96: params.sqrt_price_upper_x96,
                liquidity:           params.liquidity,
                sqrt_price_x96:      params.sqrt_price_x96,
                maximum_deposit_a: { token: params.a.token, amount: params.a.amount },
                minimum_deposit_a: params.a.minimum_deposited,
                maximum_deposit_b: { token: params.b.token, amount: params.b.amount },
                minimum_deposit_b: params.b.minimum_deposited,
            }],
        });

        const preferred_fundings  =  [
            { token: params.a.token, amount: params.a.amount },
            { token: params.b.token, amount: params.b.amount },
        ];

        const operation  =  await prepare_with_auto_stake_token( this.#ctx, this.nft_address, call, params.a.token, params.b.token, preferred_fundings, preferred_stake_token );
        return attach_operation_description( this.#ctx, operation, "create_position", async ( opts ) => {
            const amount_a   =  await render_token_amount( this.#ctx, params.a.token, params.a.amount, opts );
            const amount_b   =  await render_token_amount( this.#ctx, params.b.token, params.b.amount, opts );
            return `Create a position with ${ amount_a } and ${ amount_b } across the signed price range.`;
        });
    }

    /**
     * Prepare adding liquidity to an existing position. Both token amounts come from bond fundings.
     *
     * @example
     *   const op = await safeswap.positions.prepare_add_liquidity({
     *       token_id: 1n,
     *       liquidity: 250_000_000_000_000n,
     *       a: { token: USDC, amount: 500_000_000n, minimum_deposited: 495_000_000n },
     *       b: { token: WETH, amount: 200_000_000_000_000_000n, minimum_deposited: 198_000_000_000_000_000n },
     *   });
     *   await op.dispatch();
     */
    async prepare_add_liquidity( params: AddPositionLiquidityParams ): Promise<PreparedSafeSwapOperation>
    {
        assert_distinct_tokens( params.a.token, params.b.token, "liquidity" );
        assert_positive_amount( "liquidity", params.liquidity );
        assert_positive_amount( "a.amount", params.a.amount );
        assert_positive_amount( "b.amount", params.b.amount );

        const preferred_stake_token  =  resolve_explicit_preferred_stake_token( params.preferred_stake_token, params.a.token, params.b.token );

        const call  =  encodeFunctionData({
            abi:          SAFESWAP_NFT_ABI,
            functionName: "add_liquidity",
            args:         [{
                token_id:          params.token_id,
                liquidity:         params.liquidity,
                maximum_deposit_a: { token: params.a.token, amount: params.a.amount },
                minimum_deposit_a: params.a.minimum_deposited,
                maximum_deposit_b: { token: params.b.token, amount: params.b.amount },
                minimum_deposit_b: params.b.minimum_deposited,
            }],
        });

        const preferred_fundings  =  [
            { token: params.a.token, amount: params.a.amount },
            { token: params.b.token, amount: params.b.amount },
        ];

        const operation  =  await prepare_with_auto_stake_token( this.#ctx, this.nft_address, call, params.a.token, params.b.token, preferred_fundings, preferred_stake_token );
        return attach_operation_description( this.#ctx, operation, "add_liquidity", async ( opts ) => {
            const amount_a  =  await render_token_amount( this.#ctx, params.a.token, params.a.amount, opts );
            const amount_b  =  await render_token_amount( this.#ctx, params.b.token, params.b.amount, opts );
            return `Add up to ${ amount_a } and ${ amount_b } as liquidity to position ${ String(params.token_id) }.`;
        });
    }

    /**
     * Prepare removing liquidity from an existing position. Released tokens go to the position owner; no fundings needed.
     *
     * @example
     *   const op = await safeswap.positions.prepare_remove_liquidity({
     *       token_id: 1n,
     *       liquidity: 250_000_000_000_000n,
     *       a: { token: USDC, minimum_received: 495_000_000n },
     *       b: { token: WETH, minimum_received: 198_000_000_000_000_000n },
     *   });
     *   await op.dispatch();
     */
    async prepare_remove_liquidity( params: RemovePositionLiquidityParams ): Promise<PreparedSafeSwapOperation>
    {
        assert_distinct_tokens( params.a.token, params.b.token, "liquidity" );
        assert_positive_amount( "liquidity", params.liquidity );

        const preferred_stake_token  =  resolve_explicit_preferred_stake_token( params.preferred_stake_token, params.a.token, params.b.token );

        const call  =  encodeFunctionData({
            abi:          SAFESWAP_NFT_ABI,
            functionName: "remove_liquidity",
            args:         [{
                token_id:           params.token_id,
                liquidity:          params.liquidity,
                minimum_received_a: { token: params.a.token, amount: params.a.minimum_received },
                minimum_received_b: { token: params.b.token, amount: params.b.minimum_received },
            }],
        });

        const operation  =  await prepare_with_auto_stake_token( this.#ctx, this.nft_address, call, params.a.token, params.b.token, [], preferred_stake_token );
        return attach_operation_description( this.#ctx, operation, "remove_liquidity", async ( opts ) => {
            const minimum_a  =  await render_token_amount( this.#ctx, params.a.token, params.a.minimum_received, opts );
            const minimum_b  =  await render_token_amount( this.#ctx, params.b.token, params.b.minimum_received, opts );
            return `Remove ${ String(params.liquidity) } liquidity from position ${ String(params.token_id) }, receiving at least ${ minimum_a } and ${ minimum_b }.`;
        });
    }

    /**
     * Prepare collecting accrued fees from an existing position; no fundings needed.
     *
     * @example
     *   const op = await safeswap.positions.prepare_collect_fees({
     *       token_id: 1n,
     *       a: { token: USDC, minimum_received: 0n },
     *       b: { token: WETH, minimum_received: 0n },
     *   });
     *   await op.dispatch();
     */
    async prepare_collect_fees( params: CollectFeesParams ): Promise<PreparedSafeSwapOperation>
    {
        assert_distinct_tokens( params.a.token, params.b.token, "liquidity" );

        const preferred_stake_token  =  resolve_explicit_preferred_stake_token( params.preferred_stake_token, params.a.token, params.b.token );

        const call  =  encodeFunctionData({
            abi:          SAFESWAP_NFT_ABI,
            functionName: "collect_fees",
            args:         [{
                token_id:           params.token_id,
                minimum_received_a: { token: params.a.token, amount: params.a.minimum_received },
                minimum_received_b: { token: params.b.token, amount: params.b.minimum_received },
            }],
        });

        const operation  =  await prepare_with_auto_stake_token( this.#ctx, this.nft_address, call, params.a.token, params.b.token, [], preferred_stake_token );
        return attach_operation_description( this.#ctx, operation, "collect_fees", async () => {
            return `Collect accrued fees from position ${ String(params.token_id) }.`;
        });
    }


    // ━━━━  READ-ONLY HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /** Read immutable on-chain metadata for an NFT-backed SafeSwap LP position. */
    async get_lp_position( token_id: bigint ): Promise<SafeSwapPositionInfo>
    {
        const info  =  await this.#ctx.bond_route.public_client.readContract({
            address:      this.nft_address,
            abi:          SAFESWAP_NFT_ABI,
            functionName: "get_lp_position",
            args:         [ token_id ],
        }) as {
            hook: Address, token0: Address, token1: Address,
            base_fee_bps: number, rebate_percent: number,
            tick_spacing: number, tick_lower: number, tick_upper: number,
        };

        return {
            hook:           info.hook,
            token0:         info.token0,
            token1:         info.token1,
            base_fee_bps:   Number( info.base_fee_bps ),
            rebate_percent: Number( info.rebate_percent ),
            tick_spacing:   Number( info.tick_spacing ),
            tick_lower:     Number( info.tick_lower ),
            tick_upper:     Number( info.tick_upper ),
        };
    }

    /** Read a position's live Uniswap V4 state directly from the PoolManager. `pool_id` comes from `swaps.get_pool_id()`. */
    async get_position_state( pool_id: Hex, token_id: bigint, tick_lower: number, tick_upper: number ): Promise<PositionState>
    {
        const [ liquidity, fee_growth_inside_0_last_x128, fee_growth_inside_1_last_x128 ]  =  await this.#ctx.bond_route.public_client.readContract({
            address:      this.nft_address,
            abi:          SAFESWAP_NFT_ABI,
            functionName: "__OFF_CHAIN__get_position_info",
            args:         [ pool_id, token_id, tick_lower, tick_upper ],
        }) as [ bigint, bigint, bigint ];

        return { liquidity, fee_growth_inside_0_last_x128, fee_growth_inside_1_last_x128 };
    }

    /**
     * Decode the token id minted by a settled `create_position` operation from its execution logs.
     * Returns `null` if the operation has not executed or no mint event is present.
     */
    get_minted_token_id( operation: Bond ): bigint | null
    {
        if(  operation.status !== "executed"  )  return null;

        const nft  =  this.nft_address.toLowerCase();
        for(  const log of operation.execution_logs as Log[]  )
        {
            if(  log.address.toLowerCase() !== nft  )  continue;
            try
            {
                const decoded  =  decodeEventLog({ abi: SAFESWAP_NFT_ABI, data: log.data, topics: log.topics }) as { eventName: string, args: { from: Address, to: Address, tokenId: bigint } };
                if(  decoded.eventName === "Transfer"  &&  is_native_token( decoded.args.from )  )  return decoded.args.tokenId;
            }
            catch
            {
                /* not a SafeSwap NFT Transfer log — skip. */
            }
        }
        return null;
    }

    #encode_pool_info( pool_info: PoolInfo ): { base_fee_bps: number, rebate_percent: number, tick_spacing: number }
    {
        return { base_fee_bps: pool_info.base_fee_bps, rebate_percent: pool_info.rebate_percent, tick_spacing: pool_info.tick_spacing };
    }
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ENTRYPOINT
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * SafeSwap SDK entry point.
 *
 * Exposes the two protocol surfaces as `safeswap.swaps` and `safeswap.positions`, sharing one embedded BondRoute instance
 * (one storage scan, one `on_pending_bond` recovery pass across both). All bond lifecycle management — persistence,
 * recovery, create → wait → execute, approvals, balances, gas bumping — is delegated to BondRoute.
 *
 * @example
 *   const safeswap = await SafeSwap.init({
 *       public_client, wallet_client, account,
 *       on_pending_bond: ( bond ) => bond.resume(),
 *   });
 *
 *   const swap = await safeswap.swaps.prepare_swap_exact_input({
 *       input:  { token: USDC, exact_amount: 1000_000_000n },
 *       output: { token: WETH, minimum_amount: 0n },
 *       pool_info: { base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 },
 *   });
 *   await swap.dispatch();
 *   if(  swap.status === "executed"  ) { ... }
 *
 *   const position = await safeswap.positions.prepare_create_position({ ... });
 *   await position.dispatch();
 *   const token_id = safeswap.positions.get_minted_token_id( position );
 */
export class SafeSwap {

    readonly #ctx: SafeSwapContext;
    readonly swaps: SafeSwapSwaps;
    readonly positions: SafeSwapPositions;
    readonly router_address: Address;
    readonly nft_address: Address;

    private constructor( ctx: SafeSwapContext, router_address: Address, nft_address: Address )
    {
        this.#ctx            =  ctx;
        this.router_address  =  router_address;
        this.nft_address     =  nft_address;
        this.swaps           =  new SafeSwapSwaps( ctx, router_address );
        this.positions       =  new SafeSwapPositions( ctx, nft_address );
    }

    /**
     * Async factory. Initializes one embedded BondRoute instance, scans storage for unfinished bonds across both surfaces,
     * and routes them through `on_pending_bond` before returning.
     *
     * Throws if `on_pending_bond` is missing — recovery is too important to make optional.
     */
    static async init( opts: SafeSwapOpts ): Promise<SafeSwap>
    {
        const router_address  =  opts.router_address ?? SAFESWAP_ROUTER_ADDRESS;
        const nft_address     =  opts.nft_address ?? SAFESWAP_NFT_ADDRESS;
        if(  router_address.toLowerCase() === ZERO_ADDRESS  )  throw new Error( "router_address is not configured." );
        if(  nft_address.toLowerCase() === ZERO_ADDRESS  )     throw new Error( "nft_address is not configured." );

        const bond_route  =  await BondRoute.init({
            public_client:               opts.public_client,
            wallet_client:               opts.wallet_client,
            account:                     opts.account,
            bondroute_address:           opts.bondroute_address,
            on_pending_bond:             opts.on_pending_bond,
            storage:                     opts.storage,
            gas:                         opts.gas,
            min_confirmations_to_forget: opts.min_confirmations_to_forget,
        });

        const ctx: SafeSwapContext  =  { bond_route, token_metadata_cache: new Map() };
        return new SafeSwap( ctx, router_address, nft_address );
    }


    // ━━━━  BOND MANAGEMENT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /** Return all in-progress bonds in storage for the current account (swaps and positions together). */
    async list_pending(): Promise<Bond[]>
    {
        return await this.#ctx.bond_route.list_pending();
    }

    /** Poll a bond until settled, calling `on_update` on each tick. Returns a stop function. */
    watch_bond( bond: Bond, on_update: ( snapshot: BondSnapshot ) => void | Promise<void>, opts?: { interval_ms?: number } ): () => void
    {
        return this.#ctx.bond_route.watch_bond( bond, on_update, opts );
    }

    /** Poll pending storage records, calling `on_update` on each tick. Returns a stop function. */
    watch_pending( on_update: ( bonds: Bond[] ) => void | Promise<void>, opts?: { interval_ms?: number } ): () => void
    {
        return this.#ctx.bond_route.watch_pending( on_update, opts );
    }

    /** Serialize a bond to portable JSON for cross-device or cross-session handoff. */
    serialize_bond( bond: Bond ): string
    {
        return this.#ctx.bond_route.serialize_bond( bond );
    }

    /** Parse a previously-serialized bond back into an SDK-attached Bond instance. */
    deserialize_bond( json: string ): Bond
    {
        return this.#ctx.bond_route.deserialize_bond( json );
    }
}

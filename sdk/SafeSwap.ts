// SPDX-License-Identifier: MIT
//
//  ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
//  ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
//  ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
//  ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
//  ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
//  ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
//  ━━━━━━━━━━━━━━━  MEV-protected pools. Repricing revenue for LPs.  ━━━━━━━━━━━━━━━
//
// SafeSwap SDK — single-file TypeScript client wrapping BondRoute for SafeSwap operations.
//
// The protocol is a BondRoute-protected SwapRouter (swaps + quoting + hook registry) and an NFT position manager
// (BondRoute-protected create / add / remove plus direct fee collection). This SDK mirrors that split with two objects:
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
    keccak256,
    parseAbi,
    toHex,
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

/** Canonical SafeSwap SwapRouter address — mined; identical on every chain. */
export const SAFESWAP_ROUTER_ADDRESS  =  "0x5AFe000018090552d2C02d2884B0B567601332B2" as const;
/** Canonical SafeSwap NFT position-manager address — mined; identical on every chain. */
export const SAFESWAP_NFT_ADDRESS     =  "0x7210000035EE7a4336516E1a0F2615C55ACFa043" as const;
/** Canonical SafeSwap EIP-7702 relayer delegate (the EOA's gasless delegation target) — mined; identical on every chain. */
export const SAFESWAP_RELAYER_DELEGATE_ADDRESS  =  "0x77020000a6eF5B111B27d836403EED4Aa3A39620" as const;
/** Canonical BondRoute singleton — identical on every chain. */
export const BONDROUTE_ADDRESS  =  "0xb01d00000000440215e86e0A436f9b59FeB2F14a" as const;

const ZERO_ADDRESS  =  "0x0000000000000000000000000000000000000000" as const;

/** Highest base fee a config hook encodes (3 BCD digits → 0..999 bps, i.e. 0.00%..9.99%). */
const MAX_BASE_FEE_BPS    =  999;
/** Highest capture share a config hook encodes (BCD digits r0 → 10·r, capped at 90). */
const MAX_REBATE_PERCENT  =  90;
/** Capture is quantized to whole 10% steps (the address's percentage ones digit is forced to zero). */
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
    | "remove_liquidity";

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
    /**
     * True when any inbound funding is the native token. Retained for UI/diagnostics; it no longer gates gasless — the 7702
     * delegate pays native stake/fundings from the user's own EOA balance via `{ value: ... }`, so native is supported.
     */
    has_native_funding: () => boolean;
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

/** A deployed SafeSwap `(base fee, capture)` profile, discovered from the router's `HookRegistered` logs. */
export type SafeSwapProfile = {
    hook:           Address;
    base_fee_bps:   number;
    rebate_percent: number;
};

/** Live Uniswap V4 pool state for a SafeSwap pool, read through the router's off-chain getter. */
export type PoolState = {
    pool_id:        Hex;
    /** Current price (Q64.96). Zero when the pool has not been initialized yet. */
    sqrt_price_x96: bigint;
    /** Current tick. Zero when the pool has not been initialized yet. */
    tick:           number;
    /** True once a position has been created in the pool (it then has a live price). */
    initialized:    boolean;
};

/**
 * Bounded block-range options for log discovery. Some wallet RPCs cap `eth_getLogs` spans, so discovery queries fixed
 * windows from `from_block` to `to_block` in chunks of `max_block_range`.
 */
export type LogQueryRange = {
    from_block?:      bigint;
    to_block?:        bigint;
    max_block_range?: bigint;
};

/**
 * The on-chain NFT position card, decoded from the `tokenURI` `data:application/json;base64,...` payload. `attributes`
 * is the descriptor's trait map keyed by `trait_type` (e.g. "Pair", "Base Fee", "LP Rebate", "Claimable Fees",
 * "Lifetime Fees", "Annualized Fee Yield Estimate", "Status", "Pool Id", "Hook"); `image` is the position's SVG data URI.
 */
export type SafeSwapPositionCard = {
    token_id:    bigint;
    name:        string;
    description: string;
    image:       string;
    attributes:  Record<string, string>;
};

/** An EIP-7702 authorization signed by the user's wallet, delegating their EOA to the SafeSwap relayer delegate. */
export type SafeSwapAuthorization = {
    chainId:         number;
    address:         Address;
    nonce:           number;
    r:               Hex;
    s:               Hex;
    yParity:         number;
};

/**
 * The gasless relay request the client POSTs to the relayer `/relay` endpoint. Amounts are serialized as decimal strings
 * because JSON has no bigint. The relayer rehydrates it, re-verifies the user's `SafeSwapGaslessBond` signature, then drives
 * the two delegate phases (commit then, past the reveal delay, execute) as the user's 7702-delegated EOA. The user stakes
 * and funds from their own EOA balance; the relayer only sponsors gas and is paid `intent.relayer_fee` on-chain at commit.
 */
export type RelayRequest = {
    chain_id:           number;
    /** The user's EOA — the 7702 delegation target and the EIP-712 domain `verifyingContract`. */
    user:               Address;
    intent:             SerializedGaslessIntent;
    gasless_type_hash:  Hex;
    action_struct_hash: Hex;
    signature:          Hex;
    execution_data:     SerializedExecutionData;
    /** The 7702 authorization, or `null` when the EOA is already delegated to this delegate (no re-delegation needed). */
    authorization:      SafeSwapAuthorization | null;
    /** Optional human summary (what / how much) the relayer stores so it can echo it back in activity. */
    summary?:           GaslessSummary;
};

/** Human summary the client signs for, surfaced in activity without decoding calldata server-side. */
export type GaslessSummary  =  { kind: string, pay?: string, receive?: string };

/** JSON-safe `(token, amount)` pair (bigint amount rendered as a decimal string). */
export type SerializedTokenAmount = { token: Address, amount: string };

/** JSON-safe form of the `SafeSwapGaslessBond` intent the user signs. */
export type SerializedGaslessIntent = {
    helper:          Address;
    relayer:         Address;
    relayer_fee:     SerializedTokenAmount;
    stake:           SerializedTokenAmount;
    create_deadline: string;
    commitment_hash: Hex;
};

/** JSON-safe form of `ExecutionData` (bigints rendered as decimal strings). */
export type SerializedExecutionData = {
    fundings: SerializedTokenAmount[];
    stake:    SerializedTokenAmount;
    salt:     string;
    protocol: Address;
    call:     Hex;
};

/** Lifecycle of a gasless bond the relayer tracks (address-keyed, server-authoritative). */
export type GaslessBondStatus  =  "received" | "committed" | "executing" | "executed" | "protocol_reverted" | "failed";

/** What `POST /relay` returns once the bond is committed on-chain — the long reveal+execute then runs server-side. */
export type GaslessCommit = {
    id:                   Hex;        // the BondRoute commitment hash — poll `status(id)` / find it in `activity`.
    create_tx_hash:       Hex;
    status:               GaslessBondStatus;
    target_executable_at: number;     // sec epoch the reveal delay elapses.
};

/** A single bond's public state (no signature/payload), as returned by `GET /status/:id` and within activity. */
export type GaslessJob = {
    id:               Hex;
    summary:          GaslessSummary;
    status:           GaslessBondStatus;
    create_tx_hash:   Hex;
    execute_tx_hash?: Hex;
    revert_output?:   Hex;
    committed_at:     number;
    settled_at?:      number;
    eta_seconds:      number;
};

/** A user's gasless activity, keyed by their connected address. */
export type GaslessActivity  =  { in_progress: GaslessJob[], recent: GaslessJob[] };

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
     * Gasless EIP-7702 relayer configuration. When present, `safeswap.gasless` is usable: the user signs one
     * `SafeSwapGaslessBond` intent plus a 7702 authorization, and the relayer sponsors the commit + execute gas. The user
     * stakes and funds from their own EOA balance and pays the relayer `relayer_fee` on-chain. Omit to force self-execute.
     */
    relay?: {
        /** The relayer's `POST /relay` endpoint. */
        url:               string;
        /** The SafeSwap relayer delegate the user's EOA delegates to (7702 target). Defaults to the canonical address. */
        delegate_address?: Address;
        /** The relayer's address — it submits the sponsored transactions and receives `relayer_fee`. */
        relayer_address:   Address;
        /** The on-chain fee the user agrees to pay the relayer at commit. Defaults to zero (native sentinel, amount 0). */
        relayer_fee?:      { token: Address, amount: bigint };
        /** Seconds the signed commit stays valid. Defaults to 3600. */
        create_deadline_seconds?: number;
    };
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
    "function bonded_swap_exact_input((address token_in, uint256 input_amount, address token_out, uint256 minimum_output_amount, (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info) params) external",
    "function bonded_swap_exact_output((address token_in, uint256 maximum_input_amount, address token_out, uint256 exact_output_amount, (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info) params) external",

    "function get_hook_address(uint16 base_fee_bps, uint8 rebate_percent) external view returns (address hook)",

    "event HookRegistered(address indexed hook, uint16 indexed base_fee_bps, uint8 indexed rebate_percent)",

    "function __OFF_CHAIN__get_pool_id(address token_a, address token_b, (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info) external view returns (bytes32 pool_id)",
    "function __OFF_CHAIN__get_pool_state(address token_a, address token_b, (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info) external view returns (bytes32 pool_id, uint160 sqrt_price_x96, int24 tick, bool initialized)",
    "function __OFF_CHAIN__quote_swap_exact_input(address token_in, address token_out, (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info, uint256 amount_in) external view returns (uint256 expected_net_output, uint24 total_fee_pips, uint256 movement_bps)",
    "function __OFF_CHAIN__quote_swap_exact_output(address token_in, address token_out, (uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info, uint256 exact_output_amount) external view returns (uint256 required_input, uint24 total_fee_pips, uint256 movement_bps)",
]);

/** SafeSwap NFT position-manager surface: LP lifecycle + position getters + the ERC721 mint event. */
export const SAFESWAP_NFT_ABI  =  parseAbi([
    "function bonded_create_position(((uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing) pool_info, uint160 sqrt_price_lower_x96, uint160 sqrt_price_upper_x96, uint128 liquidity, uint160 sqrt_price_x96, (address token, uint256 amount) maximum_deposit_a, uint256 minimum_deposit_a, (address token, uint256 amount) maximum_deposit_b, uint256 minimum_deposit_b) params) external",
    "function bonded_add_liquidity((uint256 token_id, uint128 liquidity, (address token, uint256 amount) maximum_deposit_a, uint256 minimum_deposit_a, (address token, uint256 amount) maximum_deposit_b, uint256 minimum_deposit_b) params) external",
    "function bonded_remove_liquidity((uint256 token_id, uint128 liquidity, (address token, uint256 amount) minimum_received_a, (address token, uint256 amount) minimum_received_b) params) external",
    "function collect_fees((uint256 token_id, (address token, uint256 amount) minimum_received_a, (address token, uint256 amount) minimum_received_b) params) external",

    "function get_lp_position(uint256 token_id) external view returns ((uint40 opened_at, address hook, address token0, address token1, uint16 base_fee_bps, uint8 rebate_percent, int24 tick_spacing, int24 tick_lower, int24 tick_upper) position_info)",
    "function get_position_info(bytes32 pool_id, uint256 token_id, int24 tick_lower, int24 tick_upper) external view returns (uint128 liquidity, uint256 fee_growth_inside_0_last_x128, uint256 fee_growth_inside_1_last_x128)",

    "function ownerOf(uint256 token_id) external view returns (address owner)",
    "function balanceOf(address owner) external view returns (uint256 balance)",
    "function tokenURI(uint256 token_id) external view returns (string uri)",

    "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
]);

/**
 * The two gasless EIP-7702 delegate entrypoints the relayer invokes as the user's delegated EOA: the hidden commit (which
 * stakes the user's own tokens and pays the relayer its signed fee) and, past BondRoute's reveal delay, the reveal+execute.
 */
export const SAFESWAP_RELAYER_DELEGATE_ABI  =  parseAbi([
    "function create_bond_from_user_stake((address helper, address relayer, (address token, uint256 amount) relayer_fee, (address token, uint256 amount) stake, uint256 create_deadline, bytes32 commitment_hash) intent, bytes32 gasless_type_hash, bytes32 action_struct_hash, bytes signature) external payable",
    "function execute_bond_from_user((address helper, address relayer, (address token, uint256 amount) relayer_fee, (address token, uint256 amount) stake, uint256 create_deadline, bytes32 commitment_hash) intent, bytes32 gasless_type_hash, bytes32 action_struct_hash, bytes signature, ((address token, uint256 amount)[] fundings, (address token, uint256 amount) stake, uint256 salt, address protocol, bytes call) execution_data) external payable returns (uint8 status, bytes output)",
]);

/** Read-only view every BondRoute-protected SafeSwap protocol exposes, used to re-derive the EIP-712 signing surface. */
const BONDROUTE_PROTECTED_SIGNING_ABI  =  parseAbi([
    "function BondRoute_get_signing_info(bytes call) external view returns (string typed_string, bytes32 struct_hash, uint256 token_amount_offset)",
]);

/** The leading run of BondRoute's `ExecuteBondAs` type string, stripped before re-parenting the protocol action tail. */
const BONDROUTE_SIGNING_PREFIX  =  "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,";

/** The delegate's own leading struct fields, spliced in front of the action tail to form the `SafeSwapGaslessBond` type. */
const SAFESWAP_GASLESS_PREFIX  =
    "SafeSwapGaslessBond(address helper,address relayer,TokenAmount relayer_fee,TokenAmount stake,uint256 create_deadline,bytes32 commitment_hash,";

/**
 * Reproduce the delegate's `_calculate_gasless_type_hash` off-chain: strip BondRoute's `ExecuteBondAs` prefix and re-parent
 * the protocol action tail under the SafeSwap gasless struct prefix. The on-chain delegate re-derives and equality-checks
 * this, so a mismatch fails closed rather than mis-binding.
 */
export function compute_gasless_type_hash( protocol_typed_string: string ): Hex
{
    if(  protocol_typed_string.startsWith( BONDROUTE_SIGNING_PREFIX ) === false  )
    {
        throw new Error( "Protocol signing type string does not start with the expected BondRoute ExecuteBondAs prefix." );
    }
    const tail  =  protocol_typed_string.slice( BONDROUTE_SIGNING_PREFIX.length );
    return keccak256( toHex( SAFESWAP_GASLESS_PREFIX + tail ) );
}

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
    wallet_client:        WalletClient;
    account:              Account | Address;
    token_metadata_cache: Map<string, Promise<TokenDisplayMetadata>>;
    relay:                RelayConfig | null;
};

/** Resolved gasless relayer configuration (defaults applied) shared via the context. */
type RelayConfig = {
    url:                     string;
    delegate_address:        Address;
    relayer_address:         Address;
    relayer_fee:             { token: Address, amount: bigint };
    create_deadline_seconds: number;
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
    const has_native_funding       =  (): boolean => bond.execution_data.fundings.some(( funding ) => is_native_token( funding.token ) );
    return Object.assign( bond, {
        kind,
        render_description,
        get_signing_preview,
        sign_verified_execution,
        sign_execution: sign_verified_execution,
        has_native_funding,
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

/** Default `eth_getLogs` window. Public RPCs commonly cap the span at 10k blocks (e.g. Unichain Sepolia), so stay at/below it. */
const DEFAULT_LOG_BLOCK_RANGE  =  10_000n;

/**
 * Read event logs in bounded block windows so wallet RPCs that cap `eth_getLogs` spans don't reject the query. Defaults to
 * the full chain history (`from_block` 0 → latest) walked in `DEFAULT_LOG_BLOCK_RANGE` chunks.
 */
async function get_logs_in_ranges(
    public_client: PublicClient,
    filter: { address: Address, abi: typeof SAFESWAP_ROUTER_ABI | typeof SAFESWAP_NFT_ABI, event_name: string, args?: Record<string, unknown> },
    range?: LogQueryRange
): Promise<Log[]>
{
    const event           =  ( filter.abi as readonly { type: string, name?: string }[] ).find(( item ) => item.type === "event" && item.name === filter.event_name );
    if(  event === undefined  )  throw new Error( `SafeSwap ABI is missing event ${ filter.event_name }.` );

    const from_block      =  range?.from_block ?? 0n;
    const to_block        =  range?.to_block   ?? await public_client.getBlockNumber();
    const max_block_range =  range?.max_block_range ?? DEFAULT_LOG_BLOCK_RANGE;

    const logs: Log[]  =  [];
    for(  let start = from_block  ;  start <= to_block  ;  start = start + max_block_range  )
    {
        const end  =  start + max_block_range - 1n < to_block  ?  start + max_block_range - 1n  :  to_block;
        const window_logs  =  await public_client.getLogs({
            address:   filter.address,
            event:     event as any,
            args:      filter.args as any,
            fromBlock: start,
            toBlock:   end,
        });
        logs.push( ...window_logs as Log[] );
    }
    return logs;
}

/** Decode a single log against an ABI, returning the args or null if it is not the expected event. */
function decode_log_safely( abi: typeof SAFESWAP_ROUTER_ABI | typeof SAFESWAP_NFT_ABI, log: Log, event_name: string ): Record<string, unknown> | null
{
    try
    {
        const decoded  =  decodeEventLog({ abi, data: log.data, topics: log.topics }) as { eventName: string, args: Record<string, unknown> };
        if(  decoded.eventName !== event_name  )  return null;
        return decoded.args;
    }
    catch
    {
        return null;
    }
}

/** Decode a base64 string in browsers (atob), Deno, or Node (Buffer) without a runtime dependency. */
function decode_base64( value: string ): string
{
    const global_atob  =  ( globalThis as { atob?: ( input: string ) => string } ).atob;
    if(  typeof global_atob === "function"  )  return decodeURIComponent( escape( global_atob( value ) ) );

    const node_buffer  =  ( globalThis as { Buffer?: { from: ( input: string, encoding: string ) => { toString: ( encoding: string ) => string } } } ).Buffer;
    if(  node_buffer !== undefined  )  return node_buffer.from( value, "base64" ).toString( "utf-8" );

    throw new Error( "No base64 decoder available in this runtime." );
}

/** Serialize `ExecutionData` into the JSON-safe shape the relayer `/relay` endpoint accepts. */
export function serialize_execution_data( execution_data: ExecutionData ): SerializedExecutionData
{
    return {
        fundings: execution_data.fundings.map(( funding ) => ({ token: funding.token, amount: funding.amount.toString() })),
        stake:    { token: execution_data.stake.token, amount: execution_data.stake.amount.toString() },
        salt:     execution_data.salt.toString(),
        protocol: execution_data.protocol,
        call:     execution_data.call,
    };
}

/** Rehydrate a `SerializedExecutionData` back into `ExecutionData` (relayer side). */
export function deserialize_execution_data( data: SerializedExecutionData ): ExecutionData
{
    return {
        fundings: data.fundings.map(( funding ) => ({ token: funding.token, amount: BigInt( funding.amount ) })),
        stake:    { token: data.stake.token, amount: BigInt( data.stake.amount ) },
        salt:     BigInt( data.salt ),
        protocol: data.protocol,
        call:     data.call,
    };
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
            functionName: "bonded_swap_exact_input",
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
            functionName: "bonded_swap_exact_output",
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
    async get_hook_address( base_fee_bps: number, rebate_percent: number ): Promise<Address>
    {
        assert_pool_info({ base_fee_bps, rebate_percent, tick_spacing: 1 });

        return await this.#ctx.bond_route.public_client.readContract({
            address:      this.router_address,
            abi:          SAFESWAP_ROUTER_ABI,
            functionName: "get_hook_address",
            args:         [ base_fee_bps, rebate_percent ],
        }) as Address;
    }

    /**
     * Discover every deployed `(base_fee_bps, rebate_percent)` profile by reading the router's `HookRegistered` logs. All
     * three event fields are indexed, so the query is cheap. Returns one entry per currently-registered config hook, sorted
     * by base fee then rebate. No indexer required — this powers the Create profile selector and the Earn profile axis.
     *
     * Queries in bounded block windows (`max_block_range`, default 50,000) to stay under wallet-RPC `eth_getLogs` caps.
     */
    async discover_profiles( range?: LogQueryRange ): Promise<SafeSwapProfile[]>
    {
        const logs  =  await get_logs_in_ranges( this.#ctx.bond_route.public_client, {
            address: this.router_address,
            abi:     SAFESWAP_ROUTER_ABI,
            event_name: "HookRegistered",
        }, range );

        const by_config  =  new Map<string, SafeSwapProfile>();
        for(  const log of logs  )
        {
            const decoded  =  decode_log_safely( SAFESWAP_ROUTER_ABI, log, "HookRegistered" ) as { hook: Address, base_fee_bps: number | bigint, rebate_percent: number | bigint } | null;
            if(  decoded === null  )  continue;

            const profile  =  { hook: decoded.hook, base_fee_bps: Number( decoded.base_fee_bps ), rebate_percent: Number( decoded.rebate_percent ) };
            by_config.set( `${ profile.base_fee_bps }:${ profile.rebate_percent }`, profile );
        }

        return [ ...by_config.values() ].sort(( a, b ) => a.base_fee_bps - b.base_fee_bps || a.rebate_percent - b.rebate_percent );
    }

    /**
     * Read the live Uniswap V4 state of a SafeSwap pool: its id, current price/tick, and whether it has been initialized.
     * An uninitialized pool reports `sqrt_price_x96 === 0n` and `initialized === false`. Tokens may be passed in any order.
     */
    async get_pool_state( token_a: Address, token_b: Address, pool_info: PoolInfo ): Promise<PoolState>
    {
        assert_distinct_tokens( token_a, token_b, "pool" );
        assert_pool_info( pool_info );

        const [ pool_id, sqrt_price_x96, tick, initialized ]  =  await this.#ctx.bond_route.public_client.readContract({
            address:      this.router_address,
            abi:          SAFESWAP_ROUTER_ABI,
            functionName: "__OFF_CHAIN__get_pool_state",
            args:         [ token_a, token_b, this.#encode_pool_info( pool_info ) ],
        }) as [ Hex, bigint, number, boolean ];

        return { pool_id, sqrt_price_x96, tick: Number( tick ), initialized };
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
            functionName: "bonded_create_position",
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
            functionName: "bonded_add_liquidity",
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
            functionName: "bonded_remove_liquidity",
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
     * Collect accrued fees directly from an existing position. Fee collection has no price impact, so it does not require
     * BondRoute stake, delay, or signing.
     *
     * @example
     *   const transaction_hash = await safeswap.positions.collect_fees({
     *       token_id: 1n,
     *       a: { token: USDC, minimum_received: 0n },
     *       b: { token: WETH, minimum_received: 0n },
     *   });
     */
    async collect_fees( params: CollectFeesParams ): Promise<Hex>
    {
        assert_distinct_tokens( params.a.token, params.b.token, "liquidity" );

        return await this.#ctx.wallet_client.writeContract({
            account:      this.#ctx.account,
            chain:        this.#ctx.wallet_client.chain,
            address:      this.nft_address,
            abi:          SAFESWAP_NFT_ABI,
            functionName: "collect_fees",
            args:         [{
                token_id:           params.token_id,
                minimum_received_a: { token: params.a.token, amount: params.a.minimum_received },
                minimum_received_b: { token: params.b.token, amount: params.b.minimum_received },
            }],
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
            functionName: "get_position_info",
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

    /**
     * Discover the NFT-backed positions currently owned by `owner`, with no indexer. Reads the ERC-721 `Transfer` logs that
     * delivered a token to `owner` (the `to` topic is indexed), then confirms each is still owned via `ownerOf` (filtering
     * out positions since transferred away or burned). Queries in bounded windows to respect wallet-RPC `eth_getLogs` caps.
     */
    async discover_owned_positions( owner: Address, range?: LogQueryRange ): Promise<bigint[]>
    {
        const logs  =  await get_logs_in_ranges( this.#ctx.bond_route.public_client, {
            address:    this.nft_address,
            abi:        SAFESWAP_NFT_ABI,
            event_name: "Transfer",
            args:       { to: owner },
        }, range );

        const candidate_ids  =  new Set<bigint>();
        for(  const log of logs  )
        {
            const decoded  =  decode_log_safely( SAFESWAP_NFT_ABI, log, "Transfer" ) as { tokenId: bigint } | null;
            if(  decoded !== null  )  candidate_ids.add( decoded.tokenId );
        }

        const ownership_checks  =  await Promise.all( [ ...candidate_ids ].map( async ( token_id ) => ({ token_id, owned: await this.#is_owned_by( token_id, owner ) }) ) );
        return ownership_checks.filter(( check ) => check.owned ).map(( check ) => check.token_id ).sort(( a, b ) => ( a < b ? -1 : a > b ? 1 : 0 ) );
    }

    async #is_owned_by( token_id: bigint, owner: Address ): Promise<boolean>
    {
        try
        {
            const current_owner  =  await this.#ctx.bond_route.public_client.readContract({
                address:      this.nft_address,
                abi:          SAFESWAP_NFT_ABI,
                functionName: "ownerOf",
                args:         [ token_id ],
            }) as Address;
            return current_owner.toLowerCase() === owner.toLowerCase();
        }
        catch
        {
            return false;   // burned or non-existent token id — ownerOf reverts.
        }
    }

    /**
     * Read and decode a position's on-chain `tokenURI` into a typed card: the SVG `image` data URI (the position's visual
     * identity) and the descriptor's attribute map (Pair, Base Fee, LP Rebate, Current Position, Claimable Fees, Lifetime
     * Fees, Annualized Fee Yield Estimate, Status, Pool Id, Hook, …). Do not fabricate position metrics — these are the
     * on-chain truth. The base/repricing fee split is intentionally absent (no indexer); use the combined figures.
     */
    async get_position_card( token_id: bigint ): Promise<SafeSwapPositionCard>
    {
        const uri  =  await this.#ctx.bond_route.public_client.readContract({
            address:      this.nft_address,
            abi:          SAFESWAP_NFT_ABI,
            functionName: "tokenURI",
            args:         [ token_id ],
        }) as string;

        return decode_position_token_uri( token_id, uri );
    }

    #encode_pool_info( pool_info: PoolInfo ): { base_fee_bps: number, rebate_percent: number, tick_spacing: number }
    {
        return { base_fee_bps: pool_info.base_fee_bps, rebate_percent: pool_info.rebate_percent, tick_spacing: pool_info.tick_spacing };
    }
}

/** Decode a SafeSwap `data:application/json;base64,...` `tokenURI` into a typed position card. */
export function decode_position_token_uri( token_id: bigint, uri: string ): SafeSwapPositionCard
{
    const base64_prefix  =  "data:application/json;base64,";
    if(  uri.startsWith( base64_prefix ) === false  )  throw new Error( "SafeSwap tokenURI is not a base64 JSON data URI." );

    const json     =  JSON.parse( decode_base64( uri.slice( base64_prefix.length ) ) ) as {
        name?: string, description?: string, image?: string, attributes?: { trait_type: string, value: unknown }[],
    };

    const attributes: Record<string, string>  =  {};
    for(  const attribute of json.attributes ?? []  )  attributes[ attribute.trait_type ]  =  String( attribute.value );

    return {
        token_id,
        name:        json.name ?? "",
        description: json.description ?? "",
        image:       json.image ?? "",
        attributes,
    };
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// LIQUIDITY & PRICE MATH  (human inputs ⇄ raw Uniswap V4 sqrt-price / tick / liquidity)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// Per the spec, human→display conversions already exist on-chain (`SigningLib.render_*`); the inverse a UI needs when the
// user types prices and amounts (price→tick→sqrt-price and amounts→liquidity) is stock Uniswap math and lives here so the
// signed `liquidity` / `sqrt_price` inputs can be derived client-side. The raw integers stay in Advanced, never primary inputs.

/** 2^96 — the Uniswap Q64.96 fixed-point scale for sqrt prices. */
export const Q96  =  2n ** 96n;
/** Lowest tick a Uniswap V4 pool supports. */
export const MIN_TICK  =  -887272;
/** Highest tick a Uniswap V4 pool supports. */
export const MAX_TICK  =  887272;

/** Snap a tick to the nearest multiple of `tick_spacing` (clamped to the usable range). The signed range bounds must be spaced. */
export function nearest_usable_tick( tick: number, tick_spacing: number ): number
{
    if(  tick_spacing <= 0  )  throw new Error( "tick_spacing must be greater than zero." );

    const rounded  =  Math.round( tick / tick_spacing ) * tick_spacing;
    if(  rounded < MIN_TICK  )  return MIN_TICK + ( ( MIN_TICK % tick_spacing + tick_spacing ) % tick_spacing === 0 ? 0 : tick_spacing - ( ( MIN_TICK % tick_spacing ) + tick_spacing ) % tick_spacing );
    if(  rounded > MAX_TICK  )  return MAX_TICK - ( MAX_TICK % tick_spacing );
    return rounded;
}

/**
 * Exact Uniswap V4 `TickMath.getSqrtRatioAtTick`: the sqrt price (Q64.96) at a tick. Ported integer-for-integer so the
 * client-derived `sqrt_price_lower/upper` match the values the contract computes from the same ticks.
 */
export function get_sqrt_ratio_at_tick( tick: number ): bigint
{
    if(  Number.isInteger( tick ) === false || tick < MIN_TICK || tick > MAX_TICK  )  throw new Error( `tick must be an integer within [${ MIN_TICK }, ${ MAX_TICK }].` );

    const abs_tick  =  BigInt( tick < 0 ? -tick : tick );
    let ratio  =  ( abs_tick & 0x1n ) !== 0n  ?  0xfffcb933bd6fad37aa2d162d1a594001n  :  0x100000000000000000000000000000000n;

    const factors: [ bigint, bigint ][]  =  [
        [ 0x2n,     0xfff97272373d413259a46990580e213an ],
        [ 0x4n,     0xfff2e50f5f656932ef12357cf3c7fdccn ],
        [ 0x8n,     0xffe5caca7e10e4e61c3624eaa0941cd0n ],
        [ 0x10n,    0xffcb9843d60f6159c9db58835c926644n ],
        [ 0x20n,    0xff973b41fa98c081472e6896dfb254c0n ],
        [ 0x40n,    0xff2ea16466c96a3843ec78b326b52861n ],
        [ 0x80n,    0xfe5dee046a99a2a811c461f1969c3053n ],
        [ 0x100n,   0xfcbe86c7900a88aedcffc83b479aa3a4n ],
        [ 0x200n,   0xf987a7253ac413176f2b074cf7815e54n ],
        [ 0x400n,   0xf3392b0822b70005940c7a398e4b70f3n ],
        [ 0x800n,   0xe7159475a2c29b7443b29c7fa6e889d9n ],
        [ 0x1000n,  0xd097f3bdfd2022b8845ad8f792aa5825n ],
        [ 0x2000n,  0xa9f746462d870fdf8a65dc1f90e061e5n ],
        [ 0x4000n,  0x70d869a156d2a1b890bb3df62baf32f7n ],
        [ 0x8000n,  0x31be135f97d08fd981231505542fcfa6n ],
        [ 0x10000n, 0x9aa508b5b7a84e1c677de54f3e99bc9n ],
        [ 0x20000n, 0x5d6af8dedb81196699c329225ee604n ],
        [ 0x40000n, 0x2216e584f5fa1ea926041bedfe98n ],
        [ 0x80000n, 0x48a170391f7dc42444e8fa2n ],
    ];
    for(  const [ bit, factor ] of factors  )
    {
        if(  ( abs_tick & bit ) !== 0n  )  ratio  =  ( ratio * factor ) >> 128n;
    }

    if(  tick > 0  )  ratio  =  ( ( 2n ** 256n ) - 1n ) / ratio;

    // Round up to a Q64.96 from the Q128.128 `ratio`.
    return ( ratio >> 32n ) + ( ratio % ( 1n << 32n ) === 0n ? 0n : 1n );
}

/** Display: the human price (token1 per token0, decimal-adjusted) at a sqrt price (Q64.96). Returns `0` for an uninitialized pool. */
export function sqrt_price_x96_to_price( sqrt_price_x96: bigint, decimals0: number, decimals1: number ): number
{
    if(  sqrt_price_x96 === 0n  )  return 0;

    const ratio      =  Number( sqrt_price_x96 ) / Number( Q96 );
    const price_raw  =  ratio * ratio;
    return price_raw * 10 ** ( decimals0 - decimals1 );
}

/** The tick closest to a human price (token1 per token0, decimal-adjusted). Used to derive signed range bounds and a new-pool initial price. */
export function price_to_closest_tick( price: number, decimals0: number, decimals1: number ): number
{
    if(  price <= 0  )  throw new Error( "price must be greater than zero." );

    const price_raw  =  price * 10 ** ( decimals1 - decimals0 );
    const tick       =  Math.round( Math.log( price_raw ) / Math.log( 1.0001 ) );
    return tick < MIN_TICK ? MIN_TICK : tick > MAX_TICK ? MAX_TICK : tick;
}

/** Convenience: the sqrt price (Q64.96) at a human price, via the closest tick. New-pool initial price is advisory, so tick-rounding is acceptable. */
export function price_to_sqrt_price_x96( price: number, decimals0: number, decimals1: number ): bigint
{
    return get_sqrt_ratio_at_tick( price_to_closest_tick( price, decimals0, decimals1 ) );
}

function _ordered( sqrt_a: bigint, sqrt_b: bigint ): [ bigint, bigint ]
{
    return sqrt_a > sqrt_b  ?  [ sqrt_b, sqrt_a ]  :  [ sqrt_a, sqrt_b ];
}

function _liquidity_for_amount0( sqrt_a: bigint, sqrt_b: bigint, amount0: bigint ): bigint
{
    const [ lower, upper ]  =  _ordered( sqrt_a, sqrt_b );
    const intermediate      =  ( lower * upper ) / Q96;
    return ( amount0 * intermediate ) / ( upper - lower );
}

function _liquidity_for_amount1( sqrt_a: bigint, sqrt_b: bigint, amount1: bigint ): bigint
{
    const [ lower, upper ]  =  _ordered( sqrt_a, sqrt_b );
    return ( amount1 * Q96 ) / ( upper - lower );
}

/**
 * Stock Uniswap `getLiquidityForAmounts`: the maximum liquidity supported by `amount0`/`amount1` at the current price within
 * `[sqrt_lower, sqrt_upper]`. This is the only client-side piece a UI needs when the user types amounts — the signed
 * `liquidity` is otherwise a caller-supplied input.
 */
export function get_liquidity_for_amounts( sqrt_price_x96: bigint, sqrt_lower_x96: bigint, sqrt_upper_x96: bigint, amount0: bigint, amount1: bigint ): bigint
{
    const [ lower, upper ]  =  _ordered( sqrt_lower_x96, sqrt_upper_x96 );

    if(  sqrt_price_x96 <= lower  )  return _liquidity_for_amount0( lower, upper, amount0 );
    if(  sqrt_price_x96 < upper  )
    {
        const liquidity0  =  _liquidity_for_amount0( sqrt_price_x96, upper, amount0 );
        const liquidity1  =  _liquidity_for_amount1( lower, sqrt_price_x96, amount1 );
        return liquidity0 < liquidity1  ?  liquidity0  :  liquidity1;
    }
    return _liquidity_for_amount1( lower, upper, amount1 );
}

/** Stock Uniswap `getAmountsForLiquidity`: the token amounts a `liquidity` occupies at the current price within `[sqrt_lower, sqrt_upper]`. */
export function get_amounts_for_liquidity( sqrt_price_x96: bigint, sqrt_lower_x96: bigint, sqrt_upper_x96: bigint, liquidity: bigint ): { amount0: bigint, amount1: bigint }
{
    const [ lower, upper ]  =  _ordered( sqrt_lower_x96, sqrt_upper_x96 );

    let amount0  =  0n;
    let amount1  =  0n;
    if(  sqrt_price_x96 <= lower  )
    {
        amount0  =  ( ( ( liquidity << 96n ) * ( upper - lower ) ) / upper ) / lower;
    }
    else if(  sqrt_price_x96 < upper  )
    {
        amount0  =  ( ( ( liquidity << 96n ) * ( upper - sqrt_price_x96 ) ) / upper ) / sqrt_price_x96;
        amount1  =  ( liquidity * ( sqrt_price_x96 - lower ) ) / Q96;
    }
    else
    {
        amount1  =  ( liquidity * ( upper - lower ) ) / Q96;
    }
    return { amount0, amount1 };
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// GASLESS  (EIP-7702 relayer)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/** Derive the relayer's base origin from its `/relay` endpoint, so the sibling `/status` and `/activity` URLs can be built. */
function relay_base( relay_url: string ): string
{
    return relay_url.replace( /\/relay\/?$/, "" );
}

/** Sign EIP-712 typed data with the connected wallet (local account or JSON-RPC), mirroring the BondRoute SDK's path. */
async function sign_safeswap_typed_data(
    ctx: SafeSwapContext,
    typed_data: { domain: Record<string, unknown>, types: Record<string, { name: string, type: string }[]>, primaryType: string, message: Record<string, unknown> }
): Promise<Hex>
{
    const sign  =  ( ctx.wallet_client as unknown as { signTypedData?: ( args: unknown ) => Promise<Hex> } ).signTypedData;
    if(  typeof sign === "function"  )  return await sign.call( ctx.wallet_client, { account: ctx.account, ...typed_data } );

    const account  =  ctx.wallet_client.account as unknown as { signTypedData?: ( args: unknown ) => Promise<Hex> } | undefined;
    if(  account !== undefined && typeof account.signTypedData === "function"  )  return await account.signTypedData( typed_data );

    throw new Error( "Connected wallet cannot sign EIP-712 typed data; gasless execution is unavailable." );
}

/**
 * Gasless execution surface (EIP-7702). The user sends ZERO on-chain txns: they sign one `SafeSwapGaslessBond` intent plus a
 * 7702 authorization delegating their EOA to the SafeSwap relayer delegate, and the relayer sponsors the commit + execute
 * gas. The user stakes and funds from their own EOA balance and pays the relayer `relayer_fee` on-chain at commit. See
 * `FRONTEND_SPEC_DECISIONS.md` for the full protocol.
 *
 * Gasless is unavailable only when no relayer is configured; native inbound funding is supported (paid from the EOA's own
 * balance), so the old native-funding restriction no longer applies.
 */
export class SafeSwapGasless {

    readonly #ctx: SafeSwapContext;

    constructor( ctx: SafeSwapContext )
    {
        this.#ctx  =  ctx;
    }

    /** Whether the relayer is configured at all (independent of any particular operation). */
    get is_configured(): boolean
    {
        return this.#ctx.relay !== null;
    }

    /**
     * Whether this operation can be relayed gaslessly. With the EIP-7702 delegate the user's own EOA stakes and funds the
     * bond — native inbound funding is paid from the EOA's balance via `{ value: ... }`, so unlike the old `execute_bond_as`
     * relay there is no native restriction; configuration is the only requirement.
     */
    is_available( _operation: PreparedSafeSwapOperation ): boolean
    {
        return this.is_configured;
    }

    /**
     * Sign the EIP-7702 authorization delegating the user's EOA to the SafeSwap relayer delegate. The relayer (not the user)
     * submits the type-0x04 transaction, so this is a sponsored authorization; viem fills the authority's current nonce.
     */
    async sign_authorization(): Promise<SafeSwapAuthorization>
    {
        const relay  =  this.#require_relay();

        const wallet_client  =  this.#ctx.wallet_client as unknown as {
            signAuthorization: ( args: { account: Account | Address, contractAddress: Address } ) => Promise<{ chainId: number, address: Address, nonce: number, r: Hex, s: Hex, yParity: number }>,
        };
        if(  typeof wallet_client.signAuthorization !== "function"  )  throw new Error( "Connected wallet cannot sign EIP-7702 authorizations; use self-execute instead." );

        const signed  =  await wallet_client.signAuthorization({ account: this.#ctx.account, contractAddress: relay.delegate_address });
        return { chainId: signed.chainId, address: signed.address, nonce: signed.nonce, r: signed.r, s: signed.s, yParity: signed.yParity };
    }

    /**
     * Sign a fresh 7702 authorization only when the EOA is NOT already delegated to this delegate — avoiding a redundant
     * wallet prompt on every op (the 7702 delegation persists once set). A delegated EOA's code is the designator
     * `0xef0100 ++ delegate_address`; if it already points at our delegate, no authorization is needed.
     */
    async #authorization_if_needed( user: Address, relay: RelayConfig ): Promise<SafeSwapAuthorization | null>
    {
        const designator  =  ( "0xef0100" + relay.delegate_address.slice( 2 ) ).toLowerCase();

        const client     =  this.#ctx.bond_route.public_client as unknown as { getCode?: ( args: { address: Address } ) => Promise<Hex | undefined> };
        const code        =  typeof client.getCode === "function"  ?  await client.getCode({ address: user })  :  undefined;
        if(  code !== undefined  &&  code.toLowerCase() === designator  )  return null;

        return await this.sign_authorization();
    }

    /**
     * Sign and relay a prepared operation gaslessly. The user signs only (off-chain): one `SafeSwapGaslessBond` intent and a
     * 7702 authorization. The relayer commits the bond and **returns immediately** with a `GaslessCommit` handle; the reveal
     * delay and execute run server-side. Poll `status(id)` / `await_settlement(id)`, or list `activity(address)` — because the
     * bond is server-tracked, the caller can drop the promise (close the tab) and re-derive state later.
     *
     * @param opts.on_signed  Fired once the user's signatures are collected and just before the relayer round-trip begins, so
     *                        a UI can advance from a "Sign" step to an "In progress" step at the real boundary.
     * @param opts.summary    A human "what / how much" the relayer stores and echoes back in activity.
     * @throws if the relayer is not configured.
     */
    async relay( operation: PreparedSafeSwapOperation, opts?: { on_signed?: () => void, summary?: GaslessSummary } ): Promise<GaslessCommit>
    {
        const relay     =  this.#require_relay();
        const chain_id  =  this.#ctx.bond_route.public_client.chain?.id ?? await this.#ctx.bond_route.public_client.getChainId();
        const user      =  typeof this.#ctx.account === "string"  ?  this.#ctx.account  :  this.#ctx.account.address;

        const { intent, gasless_type_hash, action_struct_hash, signature }  =  await this.#sign_gasless_intent( operation, relay, chain_id, user );
        const authorization  =  await this.#authorization_if_needed( user, relay );

        opts?.on_signed?.();

        const request: RelayRequest  =  {
            chain_id,
            user,
            intent,
            gasless_type_hash,
            action_struct_hash,
            signature,
            execution_data: serialize_execution_data( operation.execution_data ),
            authorization,
            summary: opts?.summary,
        };

        const response  =  await fetch( relay.url, {
            method:  "POST",
            headers: { "content-type": "application/json" },
            body:    JSON.stringify( request ),
        });
        if(  response.ok === false  )  throw new Error( `SafeSwap relayer returned ${ response.status }: ${ await response.text() }` );

        return await response.json() as GaslessCommit;
    }

    /** A single gasless bond's current status by its `GaslessCommit.id`, or `null` if the relayer has no record of it. */
    async status( id: Hex ): Promise<GaslessJob | null>
    {
        const relay     =  this.#require_relay();
        const response  =  await fetch( `${ relay_base( relay.url ) }/status/${ id }` );
        if(  response.status === 404  )  return null;
        if(  response.ok === false  )    throw new Error( `SafeSwap relayer returned ${ response.status }: ${ await response.text() }` );
        return await response.json() as GaslessJob;
    }

    /** The connected user's in-progress + recent gasless activity (defaults to the SDK account's address). */
    async activity( address?: Address ): Promise<GaslessActivity>
    {
        const relay     =  this.#require_relay();
        const user      =  address ?? ( typeof this.#ctx.account === "string"  ?  this.#ctx.account  :  this.#ctx.account.address );
        const response  =  await fetch( `${ relay_base( relay.url ) }/activity/${ user }` );
        if(  response.ok === false  )  throw new Error( `SafeSwap relayer returned ${ response.status }: ${ await response.text() }` );
        return await response.json() as GaslessActivity;
    }

    /**
     * Poll a committed bond until it settles (executed / protocol_reverted / failed) and return the terminal job. Dropping
     * this promise is safe — the relayer drives the bond to settlement regardless, and `status`/`activity` re-derive it.
     */
    async await_settlement( id: Hex, opts?: { on_update?: ( job: GaslessJob ) => void, interval_ms?: number, timeout_ms?: number } ): Promise<GaslessJob>
    {
        const interval  =  opts?.interval_ms ?? 2_000;
        const deadline  =  Date.now() + ( opts?.timeout_ms ?? 600_000 );

        for( ; ; )
        {
            const job  =  await this.status( id );
            if(  job !== null  )
            {
                opts?.on_update?.( job );
                if(  job.status === "executed" || job.status === "protocol_reverted" || job.status === "failed"  )  return job;
            }
            if(  Date.now() > deadline  )  throw new Error( `Timed out awaiting settlement of bond ${ id }.` );
            await new Promise(( resolve ) => setTimeout( resolve, interval ));
        }
    }

    /**
     * Build and sign the user's `SafeSwapGaslessBond` intent. The delegate re-parents the protocol's `ExecuteBondAs` action
     * tail under the gasless struct, so the wallet still renders the human-readable action; the binding to the BondRoute
     * execution is carried by `commitment_hash` (re-derived and equality-checked on-chain at execute).
     */
    async #sign_gasless_intent(
        operation: PreparedSafeSwapOperation,
        relay: RelayConfig,
        chain_id: number,
        user: Address
    ): Promise<{ intent: SerializedGaslessIntent, gasless_type_hash: Hex, action_struct_hash: Hex, signature: Hex }>
    {
        const execution_data  =  operation.execution_data;

        const [ typed_string, action_struct_hash ]  =  await this.#ctx.bond_route.public_client.readContract({
            address:      execution_data.protocol,
            abi:          BONDROUTE_PROTECTED_SIGNING_ABI,
            functionName: "BondRoute_get_signing_info",
            args:         [ execution_data.call ],
        }) as [ string, Hex, bigint ];

        const gasless_type_hash  =  compute_gasless_type_hash( typed_string );
        const commitment_hash    =  this.#ctx.bond_route.calc_commitment_hash({ execution_data, user });
        const create_deadline    =  BigInt( Math.floor( Date.now() / 1000 ) + relay.create_deadline_seconds );

        // Re-parent the DESCRIPTOR-RENDERED action under this delegate's SafeSwapGaslessBond struct. `get_signing_preview`
        // reads the on-chain signing descriptor's human-readable action (e.g. CreatePosition's string fields) and verifies it
        // hashes to the on-chain digest — so the wallet renders the real intent and the action's EIP-712 struct hash matches
        // `action_struct_hash`. (The old path ABI-decoded the raw call against those *string* fields — a type mismatch.)
        const preview      =  await operation.get_signing_preview();
        const action_name  =  preview.action_field;
        const action_type  =  preview.action_type;

        const gasless_types: Record<string, { name: string, type: string }[]>  =  {};
        for(  const [ name, fields ] of Object.entries( preview.typed_data.types )  )
        {
            if(  name !== "ExecuteBondAs"  )  gasless_types[ name ]  =  fields;
        }
        gasless_types.SafeSwapGaslessBond  =  [
            { name: "helper",          type: "address" },
            { name: "relayer",         type: "address" },
            { name: "relayer_fee",     type: "TokenAmount" },
            { name: "stake",           type: "TokenAmount" },
            { name: "create_deadline", type: "uint256" },
            { name: "commitment_hash", type: "bytes32" },
            { name: action_name,       type: action_type },
        ];

        const signature  =  await sign_safeswap_typed_data( this.#ctx, {
            domain:      { name: "SafeSwap Gasless", version: "1", chainId: BigInt( chain_id ), verifyingContract: user },
            types:       gasless_types,
            primaryType: "SafeSwapGaslessBond",
            message:     {
                helper:            relay.delegate_address,
                relayer:           relay.relayer_address,
                relayer_fee:       relay.relayer_fee,
                stake:             execution_data.stake,
                create_deadline,
                commitment_hash,
                [ action_name ]:   preview.typed_data.message[ action_name ],
            },
        });

        const intent: SerializedGaslessIntent  =  {
            helper:          relay.delegate_address,
            relayer:         relay.relayer_address,
            relayer_fee:     { token: relay.relayer_fee.token, amount: relay.relayer_fee.amount.toString() },
            stake:           { token: execution_data.stake.token, amount: execution_data.stake.amount.toString() },
            create_deadline: create_deadline.toString(),
            commitment_hash,
        };

        return { intent, gasless_type_hash, action_struct_hash, signature };
    }

    #require_relay(): RelayConfig
    {
        if(  this.#ctx.relay === null  )  throw new Error( "No SafeSwap relayer is configured; gasless execution is unavailable." );
        return this.#ctx.relay;
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
    readonly gasless: SafeSwapGasless;
    readonly router_address: Address;
    readonly nft_address: Address;

    private constructor( ctx: SafeSwapContext, router_address: Address, nft_address: Address )
    {
        this.#ctx            =  ctx;
        this.router_address  =  router_address;
        this.nft_address     =  nft_address;
        this.swaps           =  new SafeSwapSwaps( ctx, router_address );
        this.positions       =  new SafeSwapPositions( ctx, nft_address );
        this.gasless         =  new SafeSwapGasless( ctx );
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

        const relay: RelayConfig | null  =  opts.relay === undefined
            ?  null
            :  {
                url:                     opts.relay.url,
                delegate_address:        opts.relay.delegate_address ?? SAFESWAP_RELAYER_DELEGATE_ADDRESS,
                relayer_address:         opts.relay.relayer_address,
                relayer_fee:             opts.relay.relayer_fee ?? { token: NATIVE_TOKEN, amount: 0n },
                create_deadline_seconds: opts.relay.create_deadline_seconds ?? 3600,
            };

        const ctx: SafeSwapContext  =  {
            bond_route,
            wallet_client: opts.wallet_client,
            account: opts.account,
            token_metadata_cache: new Map(),
            relay,
        };
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

import type { Address, PublicClient, WalletClient } from "viem";
import type { PreparedSafeSwapOperation, SafeSwap } from "@safeswap/sdk/source";

export type AppView = "swap" | "liquidity" | "donate" | "positions";
export type SwapMode = "exact_input" | "exact_output";
export type LiquidityMode = "add" | "remove";

export type WalletState = {
    address:       Address | null;
    chain_id:      number | null;
    public_client: PublicClient | null;
    wallet_client: WalletClient | null;
};

export type TokenMetadata = {
    address:  Address;
    symbol:   string;
    decimals: number;
};

export type SafeSwapRuntime = {
    safeswap: SafeSwap;
    wallet:   WalletState;
};

export type PreparedOperationState = {
    operation:          PreparedSafeSwapOperation;
    description:        string;
    missing_balances:   Awaited<ReturnType<PreparedSafeSwapOperation["get_missing_balances"]>>;
    missing_approvals:  Awaited<ReturnType<PreparedSafeSwapOperation["get_missing_approvals"]>>;
};

export type TrackedPosition = {
    id:             string;
    token_a:        Address;
    token_b:        Address;
    token_a_symbol: string;
    token_b_symbol: string;
    fee:            number;
    tick_spacing:   number;
    tick_lower:     number;
    tick_upper:     number;
    created_at:     number;
};

export type PositionRow = TrackedPosition & {
    liquidity: bigint | null;
    error:     string | null;
};

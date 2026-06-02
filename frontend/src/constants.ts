import type { Address } from "viem";

export const ZERO_ADDRESS  =  "0x0000000000000000000000000000000000000000" as const;

export const DEFAULT_POOL_FEE          =  "3000";
export const DEFAULT_TICK_SPACING      =  "60";
export const DEFAULT_TICK_LOWER        =  "-887220";
export const DEFAULT_TICK_UPPER        =  "887220";
export const DEFAULT_SLIPPAGE_PERCENT  =  "0.50";

export const SAFESWAP_ADDRESS  =  ( import.meta.env.VITE_SAFESWAP_ADDRESS ?? "" ) as Address | "";
export const BONDROUTE_ADDRESS =  ( import.meta.env.VITE_BONDROUTE_ADDRESS ?? "" ) as Address | "";

export const NATIVE_TOKEN_METADATA = {
    symbol:   "ETH",
    decimals: 18,
};

import type { Address } from "viem";
import {
    SAFESWAP_ROUTER_ADDRESS,
    SAFESWAP_NFT_ADDRESS,
    SAFESWAP_RELAYER_DELEGATE_ADDRESS,
    BONDROUTE_ADDRESS,
} from "@safeswap/sdk/source";

/**
 * Mined SafeSwap / BondRoute addresses — identical on every chain, so they're hardcoded in the SDK (the single source of
 * truth) and re-exported here. No per-deploy address config means no per-chain address mistakes.
 */
export { SAFESWAP_ROUTER_ADDRESS, SAFESWAP_NFT_ADDRESS, SAFESWAP_RELAYER_DELEGATE_ADDRESS, BONDROUTE_ADDRESS };

/** Per-deploy: the relayer's funded EOA — the account that sponsors gas and is the signed `relayer` in the intent. */
export const SAFESWAP_RELAYER_ADDRESS  =  ( import.meta.env.VITE_SAFESWAP_RELAYER_ADDRESS ?? "" ) as Address | "";

/** The relayer endpoint. Served same-origin in production (`/relay`); override for a separately-hosted relayer. */
export const RELAY_URL  =  ( import.meta.env.VITE_RELAY_URL ?? "/relay" ) as string;

/** Default protective-bound pre-fill, applied symmetrically: `Minimum received` = quote − 1.0%, `Maximum to pay/deposit` = quote + 1.0%. */
export const DEFAULT_BOUND_PERCENT  =  1.0;

/** Whether a relayer is configured (gates Gasless). Contract addresses are hardcoded; only the relayer EOA + endpoint are per-deploy. */
export const RELAYER_CONFIGURED  =  SAFESWAP_RELAYER_ADDRESS !== "" && RELAY_URL !== "";

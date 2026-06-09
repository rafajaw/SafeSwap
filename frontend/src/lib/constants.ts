import type { Address } from "viem";

/** Canonical SafeSwap addresses. Set per-deploy via Vite env; empty means "not configured" (the app surfaces a clear gate). */
export const SAFESWAP_ROUTER_ADDRESS           =  ( import.meta.env.VITE_SAFESWAP_ROUTER_ADDRESS ?? "" ) as Address | "";
export const SAFESWAP_NFT_ADDRESS              =  ( import.meta.env.VITE_SAFESWAP_NFT_ADDRESS ?? "" ) as Address | "";
export const BONDROUTE_ADDRESS                 =  ( import.meta.env.VITE_BONDROUTE_ADDRESS ?? "" ) as Address | "";
export const SAFESWAP_RELAYER_DELEGATE_ADDRESS =  ( import.meta.env.VITE_SAFESWAP_RELAYER_DELEGATE_ADDRESS ?? "" ) as Address | "";
/** The relayer's funded EOA — the account that submits the sponsored transactions and is the signed `relayer` in the intent. */
export const SAFESWAP_RELAYER_ADDRESS          =  ( import.meta.env.VITE_SAFESWAP_RELAYER_ADDRESS ?? "" ) as Address | "";

/** The relayer endpoint. Served same-origin in production (`/relay`); override for a separately-hosted relayer. */
export const RELAY_URL  =  ( import.meta.env.VITE_RELAY_URL ?? "/relay" ) as string;

/** Default protective-bound pre-fill, applied symmetrically: `Minimum received` = quote − 1.0%, `Maximum to pay/deposit` = quote + 1.0%. */
export const DEFAULT_BOUND_PERCENT  =  1.0;

/** Whether a relayer is configured at all on this build (gates the Gasless mode availability). */
export const RELAYER_CONFIGURED  =  SAFESWAP_RELAYER_DELEGATE_ADDRESS !== "" && SAFESWAP_RELAYER_ADDRESS !== "" && RELAY_URL !== "";

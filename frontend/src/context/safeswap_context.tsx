import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { SafeSwap, type Bond, type GaslessJob, type SafeSwapProfile } from "@safeswap/sdk/source";
import {
    BONDROUTE_ADDRESS,
    RELAY_URL,
    RELAYER_CONFIGURED,
    SAFESWAP_NFT_ADDRESS,
    SAFESWAP_RELAYER_ADDRESS,
    SAFESWAP_RELAYER_DELEGATE_ADDRESS,
    SAFESWAP_ROUTER_ADDRESS,
} from "../lib/constants";
import { connect_wallet, has_wallet_provider, on_accounts_or_chain_change, type WalletConnection } from "../lib/wallet";
import { curated_tokens, type TokenInfo } from "../lib/tokens";
import { load_receipts, save_receipt, type Receipt } from "../lib/storage";

type ConnectionStatus  =  "idle" | "connecting" | "connected" | "no_wallet" | "error";

type SafeSwapContextValue = {
    status:        ConnectionStatus;
    error:         string | null;
    wallet:        WalletConnection | null;
    safeswap:      SafeSwap | null;
    relayer_configured: boolean;
    profiles:      SafeSwapProfile[];
    tokens:        TokenInfo[];
    pending:       Bond[];
    receipts:      Receipt[];
    gasless_recent: GaslessJob[];
    connect:       () => Promise<void>;
    refresh_pending: () => Promise<void>;
    refresh_activity: () => Promise<void>;
    record_receipt: ( receipt: Receipt ) => void;
};

const SafeSwapContext  =  createContext<SafeSwapContextValue | null>( null );

export function useSafeSwap(): SafeSwapContextValue
{
    const value  =  useContext( SafeSwapContext );
    if(  value === null  )  throw new Error( "useSafeSwap must be used within SafeSwapProvider." );
    return value;
}

function not_configured(): boolean
{
    return SAFESWAP_ROUTER_ADDRESS === "" || SAFESWAP_NFT_ADDRESS === "";
}

export function SafeSwapProvider( props: { children: ReactNode } )
{
    const [ status, set_status ]      =  useState<ConnectionStatus>( "idle" );
    const [ error, set_error ]        =  useState<string | null>( null );
    const [ wallet, set_wallet ]      =  useState<WalletConnection | null>( null );
    const [ safeswap, set_safeswap ]  =  useState<SafeSwap | null>( null );
    const [ profiles, set_profiles ]  =  useState<SafeSwapProfile[]>( [] );
    const [ pending, set_pending ]    =  useState<Bond[]>( [] );
    const [ receipts, set_receipts ]  =  useState<Receipt[]>( [] );
    const [ gasless_recent, set_gasless_recent ]  =  useState<GaslessJob[]>( [] );
    const has_connected               =  useRef( false );

    const tokens  =  useMemo( () => curated_tokens( wallet?.chain_id ?? null ), [ wallet?.chain_id ] );

    const refresh_pending  =  useCallback( async () => {
        if(  safeswap === null  )  return;
        try
        {
            set_pending( await safeswap.list_pending() );
        }
        catch
        {
            /* storage scan best-effort. */
        }
    }, [ safeswap ] );

    const record_receipt  =  useCallback( ( receipt: Receipt ) => {
        if(  wallet === null  )  return;
        set_receipts( save_receipt( wallet.address, receipt ) );
    }, [ wallet ] );

    // Settled gasless history from the relayer (server-authoritative; one-shot, refreshed after an op completes — no polling).
    const refresh_activity  =  useCallback( async () => {
        if(  safeswap === null || wallet === null || RELAYER_CONFIGURED === false  )  return;
        try
        {
            const activity  =  await safeswap.gasless.activity( wallet.address );
            set_gasless_recent( activity.recent );
        }
        catch
        {
            /* relayer is optional; activity is best-effort. */
        }
    }, [ safeswap, wallet ] );

    const connect  =  useCallback( async () => {
        set_error( null );

        if(  not_configured()  )
        {
            set_status( "error" );
            set_error( "SafeSwap is not configured on this build. Set VITE_SAFESWAP_ROUTER_ADDRESS and VITE_SAFESWAP_NFT_ADDRESS." );
            return;
        }
        if(  has_wallet_provider() === false  )
        {
            set_status( "no_wallet" );
            return;
        }

        set_status( "connecting" );
        try
        {
            const connection  =  await connect_wallet();
            const sdk          =  await SafeSwap.init({
                public_client:     connection.public_client,
                wallet_client:     connection.wallet_client,
                account:           connection.address,
                router_address:    SAFESWAP_ROUTER_ADDRESS as `0x${string}`,
                nft_address:       SAFESWAP_NFT_ADDRESS as `0x${string}`,
                bondroute_address: BONDROUTE_ADDRESS === "" ? undefined : BONDROUTE_ADDRESS as `0x${string}`,
                // relayer_fee omitted → the SDK defaults it to zero (no relayer fee for now); create_deadline_seconds → SDK default.
                relay:             RELAYER_CONFIGURED ? {
                    url:             RELAY_URL,
                    delegate_address: SAFESWAP_RELAYER_DELEGATE_ADDRESS as `0x${string}`,
                    relayer_address:  SAFESWAP_RELAYER_ADDRESS as `0x${string}`,
                } : undefined,
                on_pending_bond:   ( bond ) => set_pending(( current ) => [ bond, ...current.filter(( item ) => item.commitment_hash !== bond.commitment_hash ) ]),
            });

            set_wallet( connection );
            set_safeswap( sdk );
            set_receipts( load_receipts( connection.address ) );
            set_status( "connected" );

            // Profile discovery is best-effort: a freshly-deployed network may have no registered profiles yet.
            sdk.swaps.discover_profiles().then( set_profiles ).catch( () => set_profiles( [] ) );
            sdk.list_pending().then( set_pending ).catch( () => {} );
            if(  RELAYER_CONFIGURED  )  sdk.gasless.activity( connection.address ).then(( activity ) => set_gasless_recent( activity.recent )).catch( () => {} );
        }
        catch( cause )
        {
            set_status( "error" );
            set_error( cause instanceof Error ? cause.message : String( cause ) );
        }
    }, [] );

    // On load → immediately fire the connect prompt (wallet connection is the entry gate; FRONTEND_SPEC_DECISIONS).
    useEffect( () => {
        if(  has_connected.current  )  return;
        has_connected.current  =  true;
        void connect();
    }, [ connect ] );

    // A wallet account/chain switch re-bootstraps everything from the new connection.
    useEffect( () => on_accounts_or_chain_change( () => { has_connected.current = false; void connect(); } ), [ connect ] );

    const value: SafeSwapContextValue  =  {
        status,
        error,
        wallet,
        safeswap,
        relayer_configured: RELAYER_CONFIGURED,
        profiles,
        tokens,
        pending,
        receipts,
        gasless_recent,
        connect,
        refresh_pending,
        refresh_activity,
        record_receipt,
    };

    return <SafeSwapContext.Provider value={ value }>{ props.children }</SafeSwapContext.Provider>;
}

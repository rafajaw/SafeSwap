import { useEffect, useState } from "react";
import { sqrt_price_x96_to_price, type PoolState, type SafeSwapProfile } from "@safeswap/sdk/source";
import { useSafeSwap } from "../context/safeswap_context";
import { CreateScreen } from "./create";
import { KeyValue, Pill, Segmented, Spinner } from "../components/ui";
import { bps_to_percent, capture_tag, format_number, short_address } from "../lib/format";
import type { TokenInfo } from "../lib/tokens";

const DEFAULT_TICK_SPACING  =  60;

type Tab  =  "explore" | "launch";

type DiscoveredPool = {
    token0:  TokenInfo;
    token1:  TokenInfo;
    profile: SafeSwapProfile;
    state:   PoolState;
};

export function EarnScreen()
{
    const [ tab, set_tab ]  =  useState<Tab>( "explore" );

    return (
        <div className="stack">
            <div className="between">
                <div>
                    <h2 className="card-title">Earn from protected liquidity</h2>
                    <p className="card-sub">LPs earn normal swap fees plus repricing revenue when their liquidity helps move price.</p>
                </div>
                <Segmented<Tab> value={ tab } onChange={ set_tab } options={ [ { value: "explore", label: "Explore pools" }, { value: "launch", label: "Launch pool" } ] } />
            </div>

            { tab === "explore" ? <Explore onLaunch={ () => set_tab( "launch" ) } /> : <CreateScreen onBack={ () => set_tab( "explore" ) } /> }
        </div>
    );
}

function Explore( props: { onLaunch: () => void } )
{
    const { safeswap, tokens, profiles }  =  useSafeSwap();
    const [ pools, set_pools ]      =  useState<DiscoveredPool[]>( [] );
    const [ loading, set_loading ]  =  useState( false );

    // Candidate pairs (curated list) crossed with discovered profiles, probed for an initialized pool — facts only, no indexer.
    useEffect( () => {
        if(  safeswap === null || profiles.length === 0 || tokens.length < 2  )  { set_pools( [] ); return; }
        let cancelled  =  false;
        set_loading( true );

        ( async () => {
            const found: DiscoveredPool[]  =  [];
            for(  let i = 0  ;  i < tokens.length  ;  i = i + 1  )
            {
                for(  let j = i + 1  ;  j < tokens.length  ;  j = j + 1  )
                {
                    for(  const profile of profiles  )
                    {
                        try
                        {
                            const state  =  await safeswap.swaps.get_pool_state( tokens[i]!.address, tokens[j]!.address, { base_fee_bps: profile.base_fee_bps, rebate_percent: profile.rebate_percent, tick_spacing: DEFAULT_TICK_SPACING } );
                            if(  state.initialized  )  found.push({ token0: tokens[i]!, token1: tokens[j]!, profile, state });
                        }
                        catch
                        {
                            /* unregistered profile or read failure — skip this candidate. */
                        }
                    }
                }
            }
            if(  cancelled === false  )  { set_pools( found ); set_loading( false ); }
        } )();

        return () => { cancelled = true; };
    }, [ safeswap, tokens, profiles ] );

    if(  loading  )  return <div className="card center"><Spinner /> Probing pools…</div>;
    if(  pools.length === 0  )  return (
        <div className="empty">
            <p>No protected pools are available for this pair on this network.</p>
            <button className="btn btn-primary" style={ { marginTop: 12 } } onClick={ props.onLaunch }>Launch a protected pool</button>
        </div>
    );

    return <div className="pools-grid">{ pools.map(( pool, index ) => <PoolCard key={ index } pool={ pool } onAdd={ props.onLaunch } /> ) }</div>;
}

function PoolCard( props: { pool: DiscoveredPool, onAdd: () => void } )
{
    const { token0, token1, profile, state }  =  props.pool;
    const price  =  sqrt_price_x96_to_price( state.sqrt_price_x96, token0.decimals, token1.decimals );

    return (
        <div className="card">
            <div className="between">
                <h3 className="card-title">{ token0.symbol } / { token1.symbol }</h3>
                <Pill tech>{ capture_tag( profile.rebate_percent ) }</Pill>
            </div>
            <KeyValue rows={ [
                { k: "Base fee", v: bps_to_percent( profile.base_fee_bps ) },
                { k: "Repricing rebate", v: `${ profile.rebate_percent }%` },
                { k: "Live price", v: `${ format_number( price ) } ${ token1.symbol }/${ token0.symbol }` },
                { k: "Tick", v: String( state.tick ) },
                { k: "Hook", v: short_address( profile.hook ) },
                { k: "Pool id", v: short_address( state.pool_id ) },
            ] } />
            <button className="btn btn-primary btn-block" style={ { marginTop: 14 } } onClick={ props.onAdd }>Add liquidity</button>
            <p className="tiny muted center" style={ { marginTop: 10 } }>TVL / APR / revenue need an indexer (Phase 2) — only on-chain facts are shown.</p>
        </div>
    );
}

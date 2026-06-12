import { useEffect, useMemo, useState } from "react";
import { formatUnits } from "viem";
import {
    get_amounts_for_liquidity, get_sqrt_ratio_at_tick,
    type PoolState, type SafeSwapPositionInfo,
} from "@safeswap/sdk/source";
import { useSafeSwap } from "../context/safeswap_context";
import { MinimumBound } from "../components/execution";
import { OperationRunner } from "../components/operation_runner";
import { KeyValue, Notice, Segmented, Spinner, ValueCard } from "../components/ui";
import { get_token_metadata, type TokenInfo } from "../lib/tokens";
import { format_amount, parse_amount } from "../lib/format";
import { DEFAULT_BOUND_PERCENT } from "../lib/constants";

const REMOVE_PRESETS  =  [ 25, 50, 75, 100 ];

/** Screen 6 — Remove (BondRoute-protected) and Collect (direct), two different things. */
export function RemoveCollectScreen( props: { token_id: bigint, initial_mode: "remove" | "collect", onBack: () => void } )
{
    const [ mode, set_mode ]  =  useState<"remove" | "collect">( props.initial_mode );

    return (
        <div className="stack" style={ { maxWidth: 560, margin: "0 auto" } }>
            <button className="btn-ghost" onClick={ props.onBack }>← Back</button>
            <Segmented<"remove" | "collect"> value={ mode } onChange={ set_mode } options={ [ { value: "remove", label: "Remove" }, { value: "collect", label: "Collect" } ] } />
            { mode === "remove" ? <Remove token_id={ props.token_id } onBack={ props.onBack } /> : <Collect token_id={ props.token_id } onBack={ props.onBack } /> }
        </div>
    );
}

function usePosition( token_id: bigint )
{
    const { safeswap, wallet }  =  useSafeSwap();
    const [ info, set_info ]    =  useState<SafeSwapPositionInfo | null>( null );
    const [ token0, set_t0 ]    =  useState<TokenInfo | null>( null );
    const [ token1, set_t1 ]    =  useState<TokenInfo | null>( null );
    const [ pool, set_pool ]    =  useState<PoolState | null>( null );
    const [ liquidity, set_liq ] =  useState<bigint | null>( null );
    const [ load_error, set_load_error ]  =  useState<string | null>( null );

    useEffect( () => {
        if(  safeswap === null || wallet === null  )  return;
        let cancelled  =  false;
        set_load_error( null );
        ( async () => {
            // Retry on a stale/transient RPC read (settle 1.5s between tries); surface a real error instead of hanging forever.
            for(  let attempt = 0  ;  attempt < 4 && cancelled === false  ;  attempt = attempt + 1  )
            {
                try
                {
                    const position  =  await safeswap.positions.get_lp_position( token_id );
                    const [ meta0, meta1, state ]  =  await Promise.all([
                        get_token_metadata( wallet.public_client, wallet.chain_id, position.token0 ),
                        get_token_metadata( wallet.public_client, wallet.chain_id, position.token1 ),
                        safeswap.swaps.get_pool_state( position.token0, position.token1, { base_fee_bps: position.base_fee_bps, rebate_percent: position.rebate_percent, tick_spacing: position.tick_spacing } ),
                    ]);
                    const live  =  await safeswap.positions.get_position_state( state.pool_id, token_id, position.tick_lower, position.tick_upper );
                    if(  cancelled  )  return;
                    set_info( position ); set_t0( meta0 ); set_t1( meta1 ); set_pool( state ); set_liq( live.liquidity );
                    return;
                }
                catch( err )
                {
                    if(  attempt === 3  )  { if(  cancelled === false  )  set_load_error( err instanceof Error ? err.message : String( err ) ); return; }
                    await new Promise(( resolve ) => setTimeout( resolve, 1500 ));
                }
            }
        } )();
        return () => { cancelled = true; };
    }, [ safeswap, wallet, token_id ] );

    return { info, token0, token1, pool, liquidity, load_error };
}

function Remove( props: { token_id: bigint, onBack: () => void } )
{
    const { safeswap, relayer_configured, record_receipt, refresh_pending, refresh_activity }  =  useSafeSwap();
    const { info, token0, token1, pool, liquidity, load_error }  =  usePosition( props.token_id );

    const [ percent, set_percent ]  =  useState( 50 );
    const [ run, set_run ]          =  useState( false );

    const remove_liquidity  =  useMemo( () => liquidity === null ? 0n : liquidity * BigInt( percent ) / 100n, [ liquidity, percent ] );

    const expected  =  useMemo( () => {
        if(  info === null || pool === null || pool.initialized === false || remove_liquidity <= 0n  )  return null;
        return get_amounts_for_liquidity( pool.sqrt_price_x96, get_sqrt_ratio_at_tick( info.tick_lower ), get_sqrt_ratio_at_tick( info.tick_upper ), remove_liquidity );
    }, [ info, pool, remove_liquidity ] );

    const [ min0, set_min0 ]  =  useState( "" );
    const [ min1, set_min1 ]  =  useState( "" );
    useEffect( () => {
        if(  expected === null || token0 === null || token1 === null  )  return;
        const dn  =  ( raw: bigint ) => raw * BigInt( Math.round( ( 100 - DEFAULT_BOUND_PERCENT ) * 100 ) ) / 10_000n;
        set_min0( formatUnits( dn( expected.amount0 ), token0.decimals ) );
        set_min1( formatUnits( dn( expected.amount1 ), token1.decimals ) );
    }, [ expected, token0, token1 ] );

    if(  load_error !== null  )  return <div className="card center stack" style={ { gap: 12 } }><Notice tone="warn">Couldn't load this position (the RPC may be lagging): { load_error }</Notice><button className="btn btn-primary" onClick={ props.onBack }>← Back</button></div>;
    if(  info === null || token0 === null || token1 === null  )  return <div className="card center"><Spinner /> Loading…</div>;

    // Remove takes no inbound funding (tokens flow out), so the native rule does NOT fire — gasless works even when ETH is released.
    const gasless_blocked  =  relayer_configured === false ? "No relayer is configured on this network." : null;

    if(  run && safeswap !== null && expected !== null  )
    {
        return (
            <OperationRunner
                title="Liquidity removed"
                receipt_kind="remove_liquidity"
                gasless_blocked_reason={ gasless_blocked }
                build={ async () => await safeswap.positions.prepare_remove_liquidity({
                    token_id:  props.token_id,
                    liquidity: remove_liquidity,
                    a: { token: token0.address, minimum_received: parse_amount( min0, token0.decimals ) },
                    b: { token: token1.address, minimum_received: parse_amount( min1, token1.decimals ) },
                }) }
                summary={ [
                    { label: "Removing", value: `${ percent }% of position #${ props.token_id.toString() }` },
                    { label: "You receive at least", value: `${ min0 } ${ token0.symbol } + ${ min1 } ${ token1.symbol }`, green: true },
                ] }
                onDone={ ( receipt ) => { record_receipt( receipt ); void refresh_pending(); void refresh_activity(); set_run( false ); props.onBack(); } }
                onBack={ () => set_run( false ) }
            />
        );
    }

    return (
        <div className="card">
            <h2 className="card-title">Remove liquidity</h2>
            <p className="card-sub">Protected by BondRoute. Choose how much to remove.</p>

            <div className="row" style={ { gap: 8, flexWrap: "wrap" } }>
                { REMOVE_PRESETS.map(( value ) => (
                    <button key={ value } className={ `btn ${ percent === value ? "btn-primary" : "" }` } style={ { minHeight: 38, padding: "0 14px" } } onClick={ () => set_percent( value ) }>{ value }%</button>
                ) ) }
            </div>

            { expected !== null && (
                <>
                    <div style={ { marginTop: 14 } }>
                        <KeyValue rows={ [
                            { k: "You receive (estimated)", v: `${ format_amount( expected.amount0, token0.decimals ) } ${ token0.symbol } + ${ format_amount( expected.amount1, token1.decimals ) } ${ token1.symbol }` },
                        ] } />
                    </div>
                    <div className="grid-2" style={ { marginTop: 12 } }>
                        <MinimumBound label={ `Minimum received (${ token0.symbol })` } symbol={ token0.symbol } kind="receive" value={ min0 } onChange={ set_min0 } />
                        <MinimumBound label={ `Minimum received (${ token1.symbol })` } symbol={ token1.symbol } kind="receive" value={ min1 } onChange={ set_min1 } />
                    </div>
                </>
            ) }

            <button className="btn btn-primary btn-block" style={ { marginTop: 14 } } disabled={ expected === null } onClick={ () => set_run( true ) }>Review remove</button>
        </div>
    );
}

function Collect( props: { token_id: bigint, onBack: () => void } )
{
    const { safeswap, record_receipt }  =  useSafeSwap();
    const { info, token0, token1, load_error }  =  usePosition( props.token_id );

    const [ claimable, set_claimable ]  =  useState<string>( "—" );
    const [ working, set_working ]      =  useState( false );
    const [ tx, set_tx ]                =  useState<string | null>( null );
    const [ error, set_error ]          =  useState<string | null>( null );

    useEffect( () => {
        if(  safeswap === null  )  return;
        safeswap.positions.get_position_card( props.token_id ).then(( card ) => set_claimable( card.attributes[ "Claimable Fees" ] ?? "—" ) ).catch(() => {});
    }, [ safeswap, props.token_id ] );

    const collect  =  async () => {
        if(  safeswap === null || token0 === null || token1 === null  )  return;
        set_working( true );
        set_error( null );
        try
        {
            const hash  =  await safeswap.positions.collect_fees({
                token_id: props.token_id,
                a: { token: token0.address, minimum_received: 0n },
                b: { token: token1.address, minimum_received: 0n },
            });
            set_tx( hash );
            record_receipt({ id: `collect-${ Date.now() }`, kind: "collect_fees", title: "Fees collected", status: "submitted", tx_hash: hash, created_at: Date.now(), lines: [ { label: "Collected to wallet", value: claimable, green: true } ] });
        }
        catch( cause )
        {
            set_error( cause instanceof Error ? cause.message : String( cause ) );
        }
        finally
        {
            set_working( false );
        }
    };

    if(  load_error !== null  )  return <div className="card center stack" style={ { gap: 12 } }><Notice tone="warn">Couldn't load this position (the RPC may be lagging): { load_error }</Notice><button className="btn btn-primary" onClick={ props.onBack }>← Back</button></div>;
    if(  info === null  )  return <div className="card center"><Spinner /> Loading…</div>;

    return (
        <div className="card">
            <h2 className="card-title">Collect fees</h2>
            <p className="card-sub">A direct transaction — no protection, stake, delay or signing. Realized earnings sent to your wallet.</p>

            <ValueCard label="Available to collect" amount={ claimable } />

            { tx !== null && <div style={ { marginTop: 12 } }><Notice tone="ok">Collected — sent to your wallet. tx { tx.slice( 0, 14 ) }…</Notice></div> }
            { error !== null && <div style={ { marginTop: 12 } }><Notice tone="err">{ error }</Notice></div> }

            <button className="btn btn-primary btn-block" style={ { marginTop: 14 } } disabled={ working } onClick={ collect }>{ working ? <><Spinner /> Collecting…</> : "Collect to wallet" }</button>
        </div>
    );
}

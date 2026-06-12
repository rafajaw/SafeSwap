import { useEffect, useMemo, useState } from "react";
import { formatUnits } from "viem";
import {
    get_amounts_for_liquidity, get_liquidity_for_amounts, get_sqrt_ratio_at_tick,
    type PoolState, type SafeSwapPositionInfo,
} from "@safeswap/sdk/source";
import { useSafeSwap } from "../context/safeswap_context";
import { MinimumBound } from "../components/execution";
import { OperationRunner } from "../components/operation_runner";
import { KeyValue, Notice, Segmented, Spinner } from "../components/ui";
import { get_token_metadata, type TokenInfo } from "../lib/tokens";
import { format_amount, parse_amount } from "../lib/format";
import { DEFAULT_BOUND_PERCENT } from "../lib/constants";

const HUGE_COUNTERPART  =  2n ** 120n;

/** Screen 5 — Add liquidity to an owned position. Range and profile are fixed by the position (read-only). */
export function AddLiquidityScreen( props: { token_id: bigint, onBack: () => void } )
{
    const { safeswap, wallet, relayer_configured, record_receipt, refresh_pending, refresh_activity }  =  useSafeSwap();

    const [ info, set_info ]    =  useState<SafeSwapPositionInfo | null>( null );
    const [ token0, set_t0 ]    =  useState<TokenInfo | null>( null );
    const [ token1, set_t1 ]    =  useState<TokenInfo | null>( null );
    const [ pool, set_pool ]    =  useState<PoolState | null>( null );
    const [ typed, set_typed ]  =  useState( "" );
    const [ side, set_side ]    =  useState<"0" | "1">( "0" );
    const [ run, set_run ]      =  useState( false );
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
                    const position  =  await safeswap.positions.get_lp_position( props.token_id );
                    const [ meta0, meta1, state ]  =  await Promise.all([
                        get_token_metadata( wallet.public_client, wallet.chain_id, position.token0 ),
                        get_token_metadata( wallet.public_client, wallet.chain_id, position.token1 ),
                        safeswap.swaps.get_pool_state( position.token0, position.token1, { base_fee_bps: position.base_fee_bps, rebate_percent: position.rebate_percent, tick_spacing: position.tick_spacing } ),
                    ]);
                    if(  cancelled  )  return;
                    set_info( position ); set_t0( meta0 ); set_t1( meta1 ); set_pool( state );
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
    }, [ safeswap, wallet, props.token_id ] );

    const derived  =  useMemo( () => {
        if(  info === null || token0 === null || token1 === null || pool === null || pool.initialized === false  )  return null;
        const sqrt_lower  =  get_sqrt_ratio_at_tick( info.tick_lower );
        const sqrt_upper  =  get_sqrt_ratio_at_tick( info.tick_upper );
        const typed_raw   =  parse_amount( typed, side === "0" ? token0.decimals : token1.decimals );
        if(  typed_raw <= 0n  )  return null;

        const liquidity  =  side === "0"
            ?  get_liquidity_for_amounts( pool.sqrt_price_x96, sqrt_lower, sqrt_upper, typed_raw, HUGE_COUNTERPART )
            :  get_liquidity_for_amounts( pool.sqrt_price_x96, sqrt_lower, sqrt_upper, HUGE_COUNTERPART, typed_raw );
        if(  liquidity <= 0n  )  return null;

        const amounts  =  get_amounts_for_liquidity( pool.sqrt_price_x96, sqrt_lower, sqrt_upper, liquidity );
        return { liquidity, amount0: amounts.amount0, amount1: amounts.amount1 };
    }, [ info, token0, token1, pool, typed, side ] );

    const [ max0, set_max0 ]  =  useState( "" );
    const [ min0, set_min0 ]  =  useState( "" );
    const [ max1, set_max1 ]  =  useState( "" );
    const [ min1, set_min1 ]  =  useState( "" );

    useEffect( () => {
        if(  derived === null || token0 === null || token1 === null  )  return;
        const up  =  ( raw: bigint ) => raw * BigInt( Math.round( ( 100 + DEFAULT_BOUND_PERCENT ) * 100 ) ) / 10_000n;
        const dn  =  ( raw: bigint ) => raw * BigInt( Math.round( ( 100 - DEFAULT_BOUND_PERCENT ) * 100 ) ) / 10_000n;
        set_max0( formatUnits( up( derived.amount0 ), token0.decimals ) ); set_min0( formatUnits( dn( derived.amount0 ), token0.decimals ) );
        set_max1( formatUnits( up( derived.amount1 ), token1.decimals ) ); set_min1( formatUnits( dn( derived.amount1 ), token1.decimals ) );
    }, [ derived, token0, token1 ] );

    if(  load_error !== null  )  return <div className="card center stack" style={ { gap: 12 } }><Notice tone="warn">Couldn't load this position (the RPC may be lagging): { load_error }</Notice><button className="btn btn-primary" onClick={ props.onBack }>← Back</button></div>;
    if(  info === null || token0 === null || token1 === null  )  return <div className="card center"><Spinner /> Loading position…</div>;

    const gasless_blocked  =  relayer_configured === false ? "No relayer is configured on this network." : null;

    if(  run && safeswap !== null && derived !== null  )
    {
        return (
            <OperationRunner
                title="Liquidity added"
                receipt_kind="add_liquidity"
                gasless_blocked_reason={ gasless_blocked }
                build={ async () => await safeswap.positions.prepare_add_liquidity({
                    token_id:  props.token_id,
                    liquidity: derived.liquidity,
                    a: { token: token0.address, amount: parse_amount( max0, token0.decimals ), minimum_deposited: parse_amount( min0, token0.decimals ) },
                    b: { token: token1.address, amount: parse_amount( max1, token1.decimals ), minimum_deposited: parse_amount( min1, token1.decimals ) },
                }) }
                summary={ [
                    { label: "Position", value: `#${ props.token_id.toString() } · ${ token0.symbol }/${ token1.symbol }` },
                    { label: "Deposit", value: `${ format_amount( derived.amount0, token0.decimals ) } ${ token0.symbol } + ${ format_amount( derived.amount1, token1.decimals ) } ${ token1.symbol }` },
                    { label: "Minimum deposited", value: `${ min0 } ${ token0.symbol } / ${ min1 } ${ token1.symbol }` },
                ] }
                onDone={ ( receipt ) => { record_receipt( receipt ); void refresh_pending(); void refresh_activity(); set_run( false ); props.onBack(); } }
                onBack={ () => set_run( false ) }
            />
        );
    }

    return (
        <div className="card" style={ { maxWidth: 560, margin: "0 auto" } }>
            <button className="btn-ghost" onClick={ props.onBack }>← Back</button>
            <h2 className="card-title" style={ { marginTop: 12 } }>Add liquidity</h2>
            <p className="card-sub">Position #{ props.token_id.toString() } · { token0.symbol }/{ token1.symbol } — range and profile fixed by the position.</p>

            { pool?.initialized === false && <Notice tone="warn">This position's pool is not initialized.</Notice> }

            <div className="amount-row">
                <div>
                    <input inputMode="decimal" placeholder="0.0" value={ typed } onChange={ ( event ) => set_typed( event.target.value ) } />
                    <div className="sub">Add deposit ({ side === "0" ? token0.symbol : token1.symbol }) — the other side is derived</div>
                </div>
                <Segmented<"0" | "1"> value={ side } onChange={ set_side } options={ [ { value: "0", label: token0.symbol }, { value: "1", label: token1.symbol } ] } />
            </div>

            { derived !== null && (
                <>
                    <div style={ { marginTop: 12 } }>
                        <KeyValue rows={ [
                            { k: "Deposit", v: `${ format_amount( derived.amount0, token0.decimals ) } ${ token0.symbol } + ${ format_amount( derived.amount1, token1.decimals ) } ${ token1.symbol }` },
                        ] } />
                    </div>
                    <div className="grid-2" style={ { marginTop: 12 } }>
                        <MinimumBound label={ `Maximum to deposit (${ token0.symbol })` } symbol={ token0.symbol } kind="deposit" value={ max0 } onChange={ set_max0 } />
                        <MinimumBound label={ `Minimum deposited (${ token0.symbol })` } symbol={ token0.symbol } kind="deposit" value={ min0 } onChange={ set_min0 } />
                        <MinimumBound label={ `Maximum to deposit (${ token1.symbol })` } symbol={ token1.symbol } kind="deposit" value={ max1 } onChange={ set_max1 } />
                        <MinimumBound label={ `Minimum deposited (${ token1.symbol })` } symbol={ token1.symbol } kind="deposit" value={ min1 } onChange={ set_min1 } />
                    </div>
                </>
            ) }

            <button className="btn btn-primary btn-block" style={ { marginTop: 14 } } disabled={ derived === null } onClick={ () => set_run( true ) }>Review add liquidity</button>
        </div>
    );
}

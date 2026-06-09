import { useEffect, useMemo, useState } from "react";
import { formatUnits } from "viem";
import {
    MAX_TICK, MIN_TICK,
    get_amounts_for_liquidity, get_liquidity_for_amounts, get_sqrt_ratio_at_tick,
    nearest_usable_tick, price_to_closest_tick, price_to_sqrt_price_x96, sqrt_price_x96_to_price,
    type PoolState, type SafeSwapProfile,
} from "@safeswap/sdk/source";
import { useSafeSwap } from "../context/safeswap_context";
import { TokenSelect } from "../components/token_select";
import { MinimumBound, type ExecutionMode } from "../components/execution";
import { OperationRunner } from "../components/operation_runner";
import { KeyValue, Notice, Segmented, ValueCard } from "../components/ui";
import { type TokenInfo } from "../lib/tokens";
import { bps_to_percent, format_amount, parse_amount } from "../lib/format";
import { DEFAULT_BOUND_PERCENT } from "../lib/constants";

const DEFAULT_TICK_SPACING  =  60;
const HUGE_COUNTERPART       =  2n ** 120n;   // lets get_liquidity_for_amounts pick the typed side when deriving the other.

type RangeMode  =  "full" | "custom";

/** Screen 4 — Create position (launch-pool + create-in-existing, one call). */
export function CreateScreen( props: { onBack: () => void } )
{
    const { safeswap, tokens, profiles, relayer_configured, record_receipt, refresh_pending }  =  useSafeSwap();

    const [ token_a, set_a ]          =  useState<TokenInfo | null>( tokens[0] ?? null );
    const [ token_b, set_b ]          =  useState<TokenInfo | null>( null );
    const [ profile_index, set_prof ] =  useState( 0 );
    const [ range_mode, set_range ]   =  useState<RangeMode>( "full" );
    const [ lower_price, set_lower ]  =  useState( "" );
    const [ upper_price, set_upper ]  =  useState( "" );
    const [ price, set_price ]        =  useState( "" );
    const [ typed_amount, set_typed ] =  useState( "" );
    const [ typed_side, set_side ]    =  useState<"a" | "b">( "a" );
    const [ pool, set_pool ]          =  useState<PoolState | null>( null );
    const [ run, set_run ]            =  useState( false );

    const profile  =  profiles[ profile_index ] ?? null;
    const spacing  =  DEFAULT_TICK_SPACING;

    const ordered  =  useMemo( () => order_tokens( token_a, token_b ), [ token_a, token_b ] );

    // Read live pool state — drives advisory-vs-editable price and the launch-vs-join framing.
    useEffect( () => {
        if(  safeswap === null || token_a === null || token_b === null || profile === null  )  { set_pool( null ); return; }
        let cancelled  =  false;
        safeswap.swaps.get_pool_state( token_a.address, token_b.address, { base_fee_bps: profile.base_fee_bps, rebate_percent: profile.rebate_percent, tick_spacing: spacing } )
            .then(( state ) => { if(  cancelled === false  )  set_pool( state ); })
            .catch(() => { if(  cancelled === false  )  set_pool( null ); });
        return () => { cancelled = true; };
    }, [ safeswap, token_a, token_b, profile ] );

    // Prefill the price field with the live price for an existing pool (advisory) — the deposit band is the real guard.
    useEffect( () => {
        if(  pool !== null && pool.initialized && ordered !== null  )
        {
            set_price( String( sqrt_price_x96_to_price( pool.sqrt_price_x96, ordered.token0.decimals, ordered.token1.decimals ) ) );
        }
    }, [ pool, ordered ] );

    const derived  =  useMemo( () => {
        if(  ordered === null || profile === null  )  return null;
        const human_price  =  Number( price );
        if(  Number.isFinite( human_price ) === false || human_price <= 0  )  return null;

        const sqrt_price  =  pool !== null && pool.initialized
            ?  pool.sqrt_price_x96
            :  price_to_sqrt_price_x96( human_price, ordered.token0.decimals, ordered.token1.decimals );

        const lower_tick  =  range_mode === "full"  ?  nearest_usable_tick( MIN_TICK, spacing )  :  nearest_usable_tick( price_to_closest_tick( Number( lower_price ), ordered.token0.decimals, ordered.token1.decimals ), spacing );
        const upper_tick  =  range_mode === "full"  ?  nearest_usable_tick( MAX_TICK, spacing )  :  nearest_usable_tick( price_to_closest_tick( Number( upper_price ), ordered.token0.decimals, ordered.token1.decimals ), spacing );
        if(  lower_tick >= upper_tick  )  return null;

        const sqrt_lower  =  get_sqrt_ratio_at_tick( lower_tick );
        const sqrt_upper  =  get_sqrt_ratio_at_tick( upper_tick );

        // Derive liquidity from the single typed amount, then both deposit amounts from that liquidity.
        const typed_is_token0  =  ( typed_side === "a" ) === ordered.a_is_token0;
        const typed_decimals   =  typed_side === "a" ? ordered.a.decimals : ordered.b.decimals;
        const typed_raw        =  parse_amount( typed_amount, typed_decimals );
        if(  typed_raw <= 0n  )  return null;

        const liquidity  =  typed_is_token0
            ?  get_liquidity_for_amounts( sqrt_price, sqrt_lower, sqrt_upper, typed_raw, HUGE_COUNTERPART )
            :  get_liquidity_for_amounts( sqrt_price, sqrt_lower, sqrt_upper, HUGE_COUNTERPART, typed_raw );
        if(  liquidity <= 0n  )  return null;

        const amounts  =  get_amounts_for_liquidity( sqrt_price, sqrt_lower, sqrt_upper, liquidity );
        const amount_a  =  ordered.a_is_token0 ? amounts.amount0 : amounts.amount1;
        const amount_b  =  ordered.a_is_token0 ? amounts.amount1 : amounts.amount0;

        return { sqrt_price, sqrt_lower, sqrt_upper, liquidity, amount_a, amount_b };
    }, [ ordered, profile, price, pool, range_mode, lower_price, upper_price, typed_amount, typed_side ] );

    const [ max_a, set_max_a ]  =  useState( "" );
    const [ min_a, set_min_a ]  =  useState( "" );
    const [ max_b, set_max_b ]  =  useState( "" );
    const [ min_b, set_min_b ]  =  useState( "" );

    // Prefill the funded cap (+1%) and the signed floor (−1%) directly from the derived deposit (the minimum-bound model).
    useEffect( () => {
        if(  derived === null || token_a === null || token_b === null  )  return;
        set_max_a( formatUnits( derived.amount_a * BigInt( Math.round( ( 100 + DEFAULT_BOUND_PERCENT ) * 100 ) ) / 10_000n, token_a.decimals ) );
        set_min_a( formatUnits( derived.amount_a * BigInt( Math.round( ( 100 - DEFAULT_BOUND_PERCENT ) * 100 ) ) / 10_000n, token_a.decimals ) );
        set_max_b( formatUnits( derived.amount_b * BigInt( Math.round( ( 100 + DEFAULT_BOUND_PERCENT ) * 100 ) ) / 10_000n, token_b.decimals ) );
        set_min_b( formatUnits( derived.amount_b * BigInt( Math.round( ( 100 - DEFAULT_BOUND_PERCENT ) * 100 ) ) / 10_000n, token_b.decimals ) );
    }, [ derived, token_a, token_b ] );

    const gasless_blocked  =  relayer_configured ? null : "No relayer is configured on this network.";

    if(  profiles.length === 0  )  return <Notice tone="warn">No protected profiles are deployed on this network yet. Profile deployment is an operator workflow.</Notice>;
    if(  token_a === null || token_b === null || profile === null  )  return <PairChooser tokens={ tokens } token_a={ token_a } token_b={ token_b } onA={ set_a } onB={ set_b } />;

    if(  run && safeswap !== null && derived !== null  )
    {
        return (
            <OperationRunner
                title={ pool?.initialized ? "Liquidity added" : "Protected pool launched" }
                receipt_kind="create_position"
                gasless_blocked_reason={ gasless_blocked }
                build={ async () => await safeswap.positions.prepare_create_position({
                    pool_info:            { base_fee_bps: profile.base_fee_bps, rebate_percent: profile.rebate_percent, tick_spacing: spacing },
                    sqrt_price_lower_x96: derived.sqrt_lower,
                    sqrt_price_upper_x96: derived.sqrt_upper,
                    liquidity:            derived.liquidity,
                    sqrt_price_x96:       derived.sqrt_price,
                    a: { token: token_a.address, amount: parse_amount( max_a, token_a.decimals ), minimum_deposited: parse_amount( min_a, token_a.decimals ) },
                    b: { token: token_b.address, amount: parse_amount( max_b, token_b.decimals ), minimum_deposited: parse_amount( min_b, token_b.decimals ) },
                }) }
                summary={ [
                    { label: "Deposit", value: `${ format_amount( derived.amount_a, token_a.decimals ) } ${ token_a.symbol } + ${ format_amount( derived.amount_b, token_b.decimals ) } ${ token_b.symbol }` },
                    { label: "Minimum deposited", value: `${ min_a } ${ token_a.symbol } / ${ min_b } ${ token_b.symbol }` },
                    { label: "Profile", value: `${ bps_to_percent( profile.base_fee_bps ) } base · ${ profile.rebate_percent }% repricing rebate` },
                ] }
                onDone={ ( receipt ) => { record_receipt( receipt ); void refresh_pending(); set_run( false ); props.onBack(); } }
                onBack={ () => set_run( false ) }
            />
        );
    }

    return (
        <div className="card" style={ { maxWidth: 620, margin: "0 auto" } }>
            <button className="btn-ghost" onClick={ props.onBack }>← Back</button>
            <h2 className="card-title" style={ { marginTop: 12 } }>Create position</h2>
            <p className="card-sub">{ pool?.initialized ? "This pool exists — you'll join it at the live price." : "This pool doesn't exist yet — your price initializes it." }</p>

            <div className="stack">
                <div className="grid-2">
                    <div className="field"><span className="label">Token A</span><TokenSelect tokens={ tokens } value={ token_a } exclude={ token_b?.address } onChange={ set_a } /></div>
                    <div className="field"><span className="label">Token B</span><TokenSelect tokens={ tokens } value={ token_b } exclude={ token_a?.address } onChange={ set_b } /></div>
                </div>

                <div className="row" style={ { gap: 8, flexWrap: "wrap" } }>
                    <span className="label">Profile</span>
                    <select className="select" style={ { width: "auto", minWidth: 240 } } value={ profile_index } onChange={ ( event ) => set_prof( Number( event.target.value ) ) }>
                        { profiles.map(( p, index ) => <option key={ p.hook } value={ index }>{ bps_to_percent( p.base_fee_bps ) } base · { p.rebate_percent }% repricing rebate</option> ) }
                    </select>
                </div>

                <div className="field">
                    <span className="label">Range</span>
                    <Segmented<RangeMode> value={ range_mode } onChange={ set_range } options={ [ { value: "full", label: "Full range" }, { value: "custom", label: "Custom" } ] } />
                </div>
                { range_mode === "custom" && (
                    <div className="grid-2">
                        <div className="field"><span className="label">Lower price</span><input className="input mono" value={ lower_price } onChange={ ( event ) => set_lower( event.target.value ) } /></div>
                        <div className="field"><span className="label">Upper price</span><input className="input mono" value={ upper_price } onChange={ ( event ) => set_upper( event.target.value ) } /></div>
                    </div>
                ) }

                <div className="field">
                    <span className="label">Price ({ token_b.symbol } per { token_a.symbol }){ pool?.initialized ? " — live, advisory" : " — initializes the pool" }</span>
                    <input className="input mono" value={ price } readOnly={ pool?.initialized ?? false } onChange={ ( event ) => set_price( event.target.value ) } />
                    { pool?.initialized && <span className="tiny muted">Benign drift is tolerated under BondRoute — the deposit band below is the guard, not this price.</span> }
                </div>

                <div className="amount-row">
                    <div>
                        <input inputMode="decimal" placeholder="0.0" value={ typed_amount } onChange={ ( event ) => set_typed( event.target.value ) } />
                        <div className="sub">Deposit ({ typed_side === "a" ? token_a.symbol : token_b.symbol }) — the other side is derived</div>
                    </div>
                    <Segmented<"a" | "b"> value={ typed_side } onChange={ set_side } options={ [ { value: "a", label: token_a.symbol }, { value: "b", label: token_b.symbol } ] } />
                </div>

                { derived !== null && (
                    <>
                        <KeyValue rows={ [
                            { k: "Deposit A", v: `${ format_amount( derived.amount_a, token_a.decimals ) } ${ token_a.symbol }` },
                            { k: "Deposit B", v: `${ format_amount( derived.amount_b, token_b.decimals ) } ${ token_b.symbol }` },
                        ] } />
                        <div className="grid-2">
                            <MinimumBound label="Maximum to deposit (A)" symbol={ token_a.symbol } kind="deposit" value={ max_a } onChange={ set_max_a } />
                            <MinimumBound label="Minimum deposited (A)" symbol={ token_a.symbol } kind="deposit" value={ min_a } onChange={ set_min_a } />
                            <MinimumBound label="Maximum to deposit (B)" symbol={ token_b.symbol } kind="deposit" value={ max_b } onChange={ set_max_b } />
                            <MinimumBound label="Minimum deposited (B)" symbol={ token_b.symbol } kind="deposit" value={ min_b } onChange={ set_min_b } />
                        </div>
                        <ValueCard label="Protected pool" amount={ `${ profile.rebate_percent }% repricing rebate to LPs` } method="Projected earnings need an indexer and are not shown in Phase 1." />
                    </>
                ) }

                <button className="btn btn-primary btn-block" disabled={ derived === null } onClick={ () => set_run( true ) }>Review create position</button>
            </div>
        </div>
    );
}

function PairChooser( props: { tokens: TokenInfo[], token_a: TokenInfo | null, token_b: TokenInfo | null, onA: ( t: TokenInfo ) => void, onB: ( t: TokenInfo ) => void } )
{
    return (
        <div className="card" style={ { maxWidth: 620, margin: "0 auto" } }>
            <h2 className="card-title">Create position</h2>
            <p className="card-sub">Choose a pair to begin.</p>
            <div className="grid-2">
                <div className="field"><span className="label">Token A</span><TokenSelect tokens={ props.tokens } value={ props.token_a } exclude={ props.token_b?.address } onChange={ props.onA } /></div>
                <div className="field"><span className="label">Token B</span><TokenSelect tokens={ props.tokens } value={ props.token_b } exclude={ props.token_a?.address } onChange={ props.onB } /></div>
            </div>
        </div>
    );
}

function order_tokens( a: TokenInfo | null, b: TokenInfo | null ): { token0: TokenInfo, token1: TokenInfo, a: TokenInfo, b: TokenInfo, a_is_token0: boolean } | null
{
    if(  a === null || b === null  )  return null;
    const a_is_token0  =  BigInt( a.address ) < BigInt( b.address );
    return { token0: a_is_token0 ? a : b, token1: a_is_token0 ? b : a, a, b, a_is_token0 };
}


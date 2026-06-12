import { useEffect, useMemo, useState } from "react";
import type { PreparedSafeSwapOperation, SafeSwapProfile, SwapExactInputQuote } from "@safeswap/sdk/source";
import { useSafeSwap } from "../context/safeswap_context";
import { TokenSelect } from "../components/token_select";
import { ExecutionModeToggle, MinimumBound, ProgressRail, SigningTrustPanel, type ExecutionMode } from "../components/execution";
import { KeyValue, Notice, Pill, Spinner, ValueCard } from "../components/ui";
import { pair_class, type TokenInfo } from "../lib/tokens";
import { bps_to_percent, capture_tag, format_amount, format_number, format_percent, parse_amount, pips_to_percent } from "../lib/format";
import { estimate_value_protected } from "../lib/estimate";
import { DEFAULT_BOUND_PERCENT } from "../lib/constants";
import { formatUnits } from "viem";

const DEFAULT_TICK_SPACING  =  60;

type Phase  =  { kind: "form" } | { kind: "progress" };

export function SwapScreen()
{
    const { safeswap, profiles, tokens, relayer_configured, record_receipt, refresh_pending, refresh_activity }  =  useSafeSwap();

    const [ input, set_input ]            =  useState<TokenInfo | null>( tokens[0] ?? null );
    const [ output, set_output ]          =  useState<TokenInfo | null>( null );
    const [ amount_in, set_amount_in ]    =  useState( "" );
    const [ profile_index, set_profile ]  =  useState( 0 );
    const [ tick_spacing, set_tick ]      =  useState( String( DEFAULT_TICK_SPACING ) );

    const [ quote, set_quote ]            =  useState<SwapExactInputQuote | null>( null );
    const [ quoting, set_quoting ]        =  useState( false );
    const [ quote_error, set_quote_err ]  =  useState<string | null>( null );

    const [ minimum, set_minimum ]        =  useState( "" );
    const [ min_edited, set_min_edited ]  =  useState( false );
    const [ mode, set_mode ]              =  useState<ExecutionMode>( "gasless" );

    const [ phase, set_phase ]            =  useState<Phase>( { kind: "form" } );

    const profile  =  profiles[ profile_index ] ?? null;

    const gasless_blocked  =  useMemo( () => {
        if(  relayer_configured === false  )  return "No relayer is configured on this network.";
        return null;
    }, [ relayer_configured ] );

    const effective_mode  =  gasless_blocked !== null ? "self_execute" : mode;

    // Quote whenever the inputs change.
    useEffect( () => {
        if(  safeswap === null || input === null || output === null || profile === null  )  { set_quote( null ); return; }
        const exact  =  parse_amount( amount_in, input.decimals );
        if(  exact <= 0n  )  { set_quote( null ); set_quote_err( null ); return; }

        let cancelled  =  false;
        set_quoting( true );
        set_quote_err( null );
        safeswap.swaps.quote_swap_exact_input({
            token_in:  input.address,
            token_out: output.address,
            pool_info: { base_fee_bps: profile.base_fee_bps, rebate_percent: profile.rebate_percent, tick_spacing: Number( tick_spacing ) },
            amount_in: exact,
        })
        .then(( result ) => { if(  cancelled === false  )  { set_quote( result ); } })
        .catch(( cause ) => { if(  cancelled === false  )  { set_quote( null ); set_quote_err( cause instanceof Error ? cause.message : String( cause ) ); } })
        .finally(() => { if(  cancelled === false  )  set_quoting( false ); });

        return () => { cancelled = true; };
    }, [ safeswap, input, output, profile, amount_in, tick_spacing ] );

    // Pre-fill the minimum at quote − 1.0% (editable; generous on purpose). Re-prefill until the user edits it.
    useEffect( () => {
        if(  quote === null || output === null || min_edited  )  return;
        const floor  =  quote.expected_net_output * BigInt( Math.round( ( 100 - DEFAULT_BOUND_PERCENT ) * 100 ) ) / 10_000n;
        set_minimum( formatUnits( floor, output.decimals ) );
    }, [ quote, output, min_edited ] );

    const estimate  =  useMemo( () => {
        if(  quote === null || input === null || output === null || profile === null  )  return null;
        const exact  =  parse_amount( amount_in, input.decimals );
        if(  exact <= 0n  )  return null;
        return estimate_value_protected({
            input_amount:   exact,
            input_decimals: input.decimals,
            input_symbol:   input.symbol,
            total_fee_pips: quote.total_fee_pips,
            base_fee_pips:  profile.base_fee_bps * 100,
            pair_class:     pair_class( input.class, output.class ),
        });
    }, [ quote, input, output, profile, amount_in ] );

    // Hide the "estimated value protected" callout when it rounds to zero — a small swap has negligible MEV to protect.
    const has_protected_value  =  estimate !== null && format_number( estimate.value_input_terms ) !== "0";

    if(  phase.kind === "progress" && safeswap !== null && input !== null && output !== null && profile !== null  )
    {
        return (
            <SwapProgress
                build={ async () => await safeswap.swaps.prepare_swap_exact_input({
                    input:  { token: input.address, exact_amount: parse_amount( amount_in, input.decimals ) },
                    output: { token: output.address, minimum_amount: parse_amount( minimum, output.decimals ) },
                    pool_info: { base_fee_bps: profile.base_fee_bps, rebate_percent: profile.rebate_percent, tick_spacing: Number( tick_spacing ) },
                }) }
                mode={ effective_mode }
                summary={ {
                    pay:        `${ amount_in } ${ input.symbol }`,
                    receive:    `≥ ${ minimum } ${ output.symbol }`,
                    protected:  has_protected_value && estimate !== null ? `+${ format_number( estimate.value_input_terms ) } ${ input.symbol }` : "",
                } }
                onDone={ ( receipt ) => { record_receipt( receipt ); void refresh_pending(); void refresh_activity(); } }
                onBack={ () => set_phase( { kind: "form" } ) }
            />
        );
    }

    const can_review  =  safeswap !== null && input !== null && output !== null && profile !== null && quote !== null && parse_amount( amount_in, input.decimals ) > 0n;

    return (
        <div className="swap-layout">
            <div className="card">
                <h2 className="card-title">Swap</h2>
                <p className="card-sub">Protected execution. No sandwiching — set your minimum as safe as you like.</p>

                <div className="stack">
                    <div className="amount-row">
                        <div>
                            <input inputMode="decimal" placeholder="0.0" value={ amount_in } onChange={ ( event ) => set_amount_in( event.target.value ) } />
                            <div className="sub">You pay</div>
                        </div>
                        <TokenSelect tokens={ tokens } value={ input } exclude={ output?.address } onChange={ set_input } />
                    </div>

                    <div className="amount-row">
                        <div>
                            <input readOnly placeholder="0.0" value={ quote !== null && output !== null ? format_amount( quote.expected_net_output, output.decimals ) : "" } />
                            <div className="sub">You receive (estimated, net of protocol fee)</div>
                        </div>
                        <TokenSelect tokens={ tokens } value={ output } exclude={ input?.address } onChange={ set_output } />
                    </div>

                    { profiles.length > 0 ? (
                        <div className="row" style={ { gap: 8, flexWrap: "wrap" } }>
                            <span className="label">Pool</span>
                            <select className="select" style={ { width: "auto", minWidth: 220 } } value={ profile_index } onChange={ ( event ) => set_profile( Number( event.target.value ) ) }>
                                { profiles.map(( p, index ) => <option key={ p.hook } value={ index }>{ bps_to_percent( p.base_fee_bps ) } base · { p.rebate_percent }% repricing rebate</option> ) }
                            </select>
                        </div>
                    ) : <Notice tone="warn">No protected pools discovered on this network yet.</Notice> }

                    { has_protected_value && estimate !== null && (
                        <ValueCard
                            label="Estimated value protected"
                            amount={ `+${ format_number( estimate.value_input_terms ) } ${ estimate.input_symbol }` }
                            delta={ `+${ format_percent( estimate.improvement_fraction ) } versus ordinary execution` }
                            starred
                        />
                    ) }

                    { quoting && <div className="row tiny muted"><Spinner /> Quoting…</div> }
                    { quote_error !== null && <Notice tone="warn">No protected pool for { input?.symbol } / { output?.symbol } at the { profile !== null ? bps_to_percent( profile.base_fee_bps ) : "" } fee tier yet — pick another fee tier above, or launch this pool from Earn.</Notice> }

                    { quote !== null && output !== null && profile !== null && input !== null && (
                        <>
                            <MinimumBound label="Minimum received" symbol={ output.symbol } kind="receive" value={ minimum } onChange={ ( value ) => { set_minimum( value ); set_min_edited( true ); } } />

                            <details className="disclosure">
                                <summary>Quote details</summary>
                                <QuoteDetails quote={ quote } profile={ profile } input={ input } output={ output } minimum={ minimum } mode={ effective_mode } estimate_method={ estimate?.assumption_text } />
                            </details>
                        </>
                    ) }

                    <ExecutionModeToggle mode={ effective_mode } onChange={ set_mode } gasless_blocked_reason={ gasless_blocked } />

                    <button className="btn btn-primary btn-block" disabled={ can_review === false } onClick={ () => set_phase( { kind: "progress" } ) }>
                        Review protected swap
                    </button>
                </div>
            </div>

            <div className="card">
                <h3 className="card-title">Why this is protected</h3>
                <p className="card-sub">
                    On an ordinary DEX your slippage tolerance is the MEV extraction surface — bots take exactly up to it.
                    Under BondRoute there is no sandwiching, so a generous minimum is safe: the gap between quote and minimum
                    is not a target anyone can extract.
                </p>
                <KeyValue rows={ [
                    { k: "MEV protection", v: "BondRoute commit → execute" },
                    { k: "Repricing fee", v: "Grows only when the swap extracts visible surplus" },
                    { k: "LP benefit", v: profile !== null ? `${ profile.rebate_percent }% of repricing surplus to LPs` : "—" },
                ] } />
            </div>
        </div>
    );
}

function QuoteDetails( props: {
    quote: SwapExactInputQuote;
    profile: SafeSwapProfile;
    input: TokenInfo;
    output: TokenInfo;
    minimum: string;
    mode: ExecutionMode;
    estimate_method?: string;
} )
{
    const base_fee_pips   =  props.profile.base_fee_bps * 100;
    const repricing_pips  =  Math.max( 0, props.quote.total_fee_pips - base_fee_pips );

    return (
        <>
            <KeyValue rows={ [
                { k: "Minimum received", v: `${ props.minimum } ${ props.output.symbol }` },
                { k: "Price movement", v: `${ props.quote.movement_bps.toString() } ticks` },
                { k: "Base LP fee", v: bps_to_percent( props.profile.base_fee_bps ) },
                { k: "Estimated repricing fee", v: pips_to_percent( repricing_pips ) },
                { k: "Total LP fee", v: pips_to_percent( props.quote.total_fee_pips ) },
                { k: "Network cost", v: props.mode === "gasless" ? "Sponsored (gasless)" : "You pay gas" },
                { k: "Capture profile", v: <Pill tech>{ capture_tag( props.profile.rebate_percent ) }</Pill> },
            ] } />
            <p className="tiny muted" style={ { marginTop: 10 } }>The repricing fee grows only when this swap extracts visible repricing surplus. { props.estimate_method }</p>
        </>
    );
}

/** Screen 2 — guided protected-execution progress (gasless or self-execute), then the completion receipt. */
function SwapProgress( props: {
    build:    () => Promise<PreparedSafeSwapOperation>;
    mode:     ExecutionMode;
    summary:  { pay: string, receive: string, protected: string };
    onDone:   ( receipt: import("../lib/storage").Receipt ) => void;
    onBack:   () => void;
} )
{
    const { safeswap }  =  useSafeSwap();
    const [ step, set_step ]        =  useState( 0 );
    const [ error, set_error ]      =  useState<string | null>( null );
    const [ done, set_done ]        =  useState<null | { received: string, status: string, tx?: string }>( null );
    const [ preview, set_preview ]  =  useState<Awaited<ReturnType<PreparedSafeSwapOperation["get_signing_preview"]>> | null>( null );
    const [ working, set_working ]  =  useState( false );

    const steps  =  props.mode === "gasless" ? [ "Sign", "In progress", "Done" ] : [ "Commit", "Active", "Execute", "Done" ];

    const run  =  async () => {
        if(  safeswap === null  )  return;
        set_working( true );
        set_error( null );
        try
        {
            const op  =  await props.build();

            if(  props.mode === "gasless"  )
            {
                // Step stays on "Sign" while the wallet prompts; `on_signed` advances to "In progress" for the relayer round-trip.
                // `relay` returns once committed; the bond is then server-tracked, so leaving this page is safe (Activity resumes it).
                const commit  =  await safeswap.gasless.relay( op, {
                    on_signed: () => set_step( 1 ),
                    summary:   { kind: "swap", pay: props.summary.pay, receive: props.summary.receive },
                } );
                const job  =  await safeswap.gasless.await_settlement( commit.id );
                set_step( 2 );
                finish( job.status, job.execute_tx_hash );
            }
            else
            {
                set_preview( await op.get_signing_preview() );
                set_step( 1 );
                await op.dispatch();
                set_step( 3 );
                finish( op.status, undefined );
            }
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

    const finish  =  ( status: string, tx?: string ) => {
        const receipt: import("../lib/storage").Receipt  =  {
            id:         `swap-${ Date.now() }`,
            kind:       "swap",
            title:      status === "executed" ? "Swap protected" : `Swap ${ status }`,
            status:     status as import("../lib/storage").Receipt["status"],
            tx_hash:    tx as `0x${string}` | undefined,
            created_at: Date.now(),
            lines:      [
                { label: "Received", value: props.summary.receive },
                ...( props.summary.protected !== "" ? [ { label: "Estimated value retained", value: `${ props.summary.protected } *`, green: true } ] : [] ),
                { label: "Execution status", value: status === "executed" ? "Protected" : status },
            ],
        };
        set_done({ received: props.summary.receive, status, tx });
        props.onDone( receipt );
    };

    return (
        <div className="card" style={ { maxWidth: 560, margin: "0 auto" } }>
            <button className="btn-ghost" onClick={ props.onBack }>← Back to swap</button>
            <h2 className="card-title" style={ { marginTop: 12 } }>{ done !== null ? ( done.status === "executed" ? "Swap protected" : "Swap settled" ) : "Securing your execution" }</h2>
            <ProgressRail steps={ steps } current={ done !== null ? steps.length : step } />

            { done === null && (
                <>
                    <div className="card" style={ { background: "var(--surface-2)" } }>
                        <KeyValue rows={ [
                            { k: "Pay", v: props.summary.pay },
                            { k: "Receive", v: props.summary.receive },
                            ...( props.summary.protected !== "" ? [ { k: "Estimated value protected", v: `${ props.summary.protected } *`, tone: "green" as const } ] : [] ),
                        ] } />
                        { props.mode === "self_execute" && <p className="tiny muted" style={ { marginTop: 8 } }>Your wallet will show raw transaction data; this summary is the human-readable review.</p> }
                    </div>

                    { preview !== null && props.mode === "self_execute" && <div style={ { marginTop: 12 } }><SigningTrustPanel preview={ preview } /></div> }

                    { error !== null && <div style={ { marginTop: 12 } }><Notice tone="err">{ error }</Notice></div> }

                    <button className="btn btn-primary btn-block" style={ { marginTop: 14 } } disabled={ working } onClick={ run }>
                        { working ? <><Spinner /> { props.mode === "gasless" ? ( step === 0 ? "Pending signature…" : "Relaying…" ) : "Submitting…" }</> : props.mode === "gasless" ? "Sign & relay" : "Confirm protected swap" }
                    </button>
                    <p className="tiny muted center" style={ { marginTop: 10 } }>
                        { props.mode === "gasless" ? "The relayer is completing this on-chain — keep this tab open to see the result." : "Status is in progress — it is safe to leave and return." }
                    </p>
                </>
            ) }

            { done !== null && (
                <>
                    { props.summary.protected !== "" && <ValueCard label="Estimated value retained" amount={ props.summary.protected } starred /> }
                    <div style={ { marginTop: 12 } }>
                        <KeyValue rows={ [
                            { k: "Received", v: props.summary.receive },
                            { k: "Execution status", v: done.status === "executed" ? "Protected" : done.status },
                        ] } />
                    </div>
                    <div className="row" style={ { marginTop: 14, gap: 10 } }>
                        <button className="btn btn-primary" onClick={ props.onBack }>Make another swap</button>
                        { done.tx !== undefined && <span className="tiny mono muted">tx { done.tx.slice( 0, 14 ) }…</span> }
                    </div>
                </>
            ) }
        </div>
    );
}

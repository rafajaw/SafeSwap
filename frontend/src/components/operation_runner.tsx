import { useState } from "react";
import type { PreparedSafeSwapOperation } from "@safeswap/sdk/source";
import { useSafeSwap } from "../context/safeswap_context";
import { ExecutionModeToggle, ProgressRail, SigningTrustPanel, type ExecutionMode } from "./execution";
import { KeyValue, Notice, Spinner, ValueCard } from "./ui";
import type { Receipt } from "../lib/storage";

export type RunnerSummaryLine  =  { label: string, value: string, green?: boolean };

/**
 * Generic guided runner for a BondRoute-protected operation (create / add / remove). Drives gasless (Sign → In progress →
 * Done) or self-execute (Commit → Active → Execute → Done), shows the signing trust panel and an in-app summary for the
 * self-execute case (temporary, until wallets clear-sign these plain txns), and emits a shared completion receipt.
 */
export function OperationRunner( props: {
    title:        string;
    build:        () => Promise<PreparedSafeSwapOperation>;
    summary:      RunnerSummaryLine[];
    receipt_kind: Receipt["kind"];
    gasless_blocked_reason: string | null;
    onDone:       ( receipt: Receipt ) => void;
    onBack:       () => void;
    completion_value?: { label: string, amount: string, starred?: boolean };
} )
{
    const { safeswap }  =  useSafeSwap();

    const forced_self  =  props.gasless_blocked_reason !== null;
    const [ mode, set_mode ]        =  useState<ExecutionMode>( forced_self ? "self_execute" : "gasless" );
    const effective_mode            =  forced_self ? "self_execute" : mode;

    const [ step, set_step ]        =  useState( 0 );
    const [ working, set_working ]  =  useState( false );
    const [ error, set_error ]      =  useState<string | null>( null );
    const [ preview, set_preview ]  =  useState<Awaited<ReturnType<PreparedSafeSwapOperation["get_signing_preview"]>> | null>( null );
    const [ done, set_done ]        =  useState<{ status: string, tx?: string } | null>( null );

    const steps  =  effective_mode === "gasless" ? [ "Sign", "In progress", "Done" ] : [ "Commit", "Active", "Execute", "Done" ];

    const run  =  async () => {
        if(  safeswap === null  )  return;
        set_working( true );
        set_error( null );
        try
        {
            const op  =  await props.build();

            if(  effective_mode === "gasless"  )
            {
                // Step stays on "Sign" while the wallet prompts; `on_signed` advances to "In progress" for the relayer round-trip.
                // `relay` returns once committed; the bond is then server-tracked, so leaving this page is safe (Activity resumes it).
                const commit  =  await safeswap.gasless.relay( op, { on_signed: () => set_step( 1 ), summary: { kind: props.receipt_kind } } );
                const job     =  await safeswap.gasless.await_settlement( commit.id );
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
        const receipt: Receipt  =  {
            id:         `${ props.receipt_kind }-${ Date.now() }`,
            kind:       props.receipt_kind,
            title:      props.title,
            status:     status as Receipt["status"],
            tx_hash:    tx as `0x${string}` | undefined,
            created_at: Date.now(),
            lines:      props.summary,
        };
        set_done({ status, tx });
        props.onDone( receipt );
    };

    return (
        <div className="card" style={ { maxWidth: 560, margin: "0 auto" } }>
            <button className="btn-ghost" onClick={ props.onBack }>← Back</button>
            <h2 className="card-title" style={ { marginTop: 12 } }>{ done !== null ? props.title : "Securing your action" }</h2>
            <ProgressRail steps={ steps } current={ done !== null ? steps.length : step } />

            { done === null && (
                <>
                    <div className="card" style={ { background: "var(--surface-2)" } }>
                        <KeyValue rows={ props.summary.map(( line ) => ({ k: line.label, v: line.value, tone: line.green ? "green" as const : undefined })) } />
                        { effective_mode === "self_execute" && <p className="tiny muted" style={ { marginTop: 8 } }>Your wallet will show raw transaction data; this summary is the human-readable review.</p> }
                    </div>

                    { preview !== null && effective_mode === "self_execute" && <div style={ { marginTop: 12 } }><SigningTrustPanel preview={ preview } /></div> }

                    <div style={ { marginTop: 12 } }>
                        <ExecutionModeToggle mode={ effective_mode } onChange={ set_mode } gasless_blocked_reason={ props.gasless_blocked_reason } />
                    </div>

                    { error !== null && <div style={ { marginTop: 12 } }><Notice tone="err">{ error }</Notice></div> }

                    <button className="btn btn-primary btn-block" style={ { marginTop: 14 } } disabled={ working } onClick={ run }>
                        { working ? <><Spinner /> { effective_mode === "gasless" ? ( step === 0 ? "Pending signature…" : "Relaying…" ) : "Submitting…" }</> : "Confirm protected action" }
                    </button>
                    <p className="tiny muted center" style={ { marginTop: 10 } }>
                        { effective_mode === "gasless" ? "The relayer is completing this on-chain — keep this tab open to see the result." : "Status is in progress — it is safe to leave and return." }
                    </p>
                </>
            ) }

            { done !== null && (
                <>
                    { props.completion_value !== undefined && <ValueCard label={ props.completion_value.label } amount={ props.completion_value.amount } starred={ props.completion_value.starred } /> }
                    <div style={ { marginTop: 12 } }>
                        <KeyValue rows={ [ ...props.summary.map(( line ) => ({ k: line.label, v: line.value, tone: line.green ? "green" as const : undefined })), { k: "Status", v: done.status === "executed" ? "Protected" : done.status } ] } />
                    </div>
                    <button className="btn btn-primary" style={ { marginTop: 14 } } onClick={ props.onBack }>Done</button>
                </>
            ) }
        </div>
    );
}

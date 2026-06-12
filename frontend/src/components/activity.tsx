import { useState } from "react";
import type { Bond, GaslessJob } from "@safeswap/sdk/source";
import { Pill, Spinner } from "./ui";

/**
 * Activity center (handoff §17 / FRONTEND_SPEC_DECISIONS): in-flight BondRoute actions persist across refresh/reconnect
 * (the SDK scans storage at init and surfaces them via `on_pending_bond`). Resume re-enters the action's progress flow.
 */
export function ActivityCenter( props: { pending: Bond[], onResume: ( bond: Bond ) => Promise<void> } )
{
    if(  props.pending.length === 0  )  return null;

    return (
        <div className="card">
            <h3 className="card-title">In-flight protected actions</h3>
            <p className="card-sub">These survive refresh — it is safe to leave and return. Resume to continue.</p>
            <div className="stack" style={ { gap: 10 } }>
                { props.pending.map(( bond ) => <ActivityRow key={ bond.commitment_hash } bond={ bond } onResume={ props.onResume } /> ) }
            </div>
        </div>
    );
}

function ActivityRow( props: { bond: Bond, onResume: ( bond: Bond ) => Promise<void> } )
{
    const [ busy, set_busy ]  =  useState( false );

    const resume  =  async () => {
        set_busy( true );
        try { await props.onResume( props.bond ); }
        finally { set_busy( false ); }
    };

    return (
        <div className="between" style={ { padding: "12px 14px", border: "1px solid var(--hairline)", borderRadius: "var(--radius-sm)" } }>
            <div className="stack" style={ { gap: 4 } }>
                <span className="mono tiny">{ props.bond.commitment_hash.slice( 0, 18 ) }…</span>
                <Pill tone={ props.bond.status === "active" ? "amber" : "default" }>{ props.bond.state }</Pill>
            </div>
            <button className="btn" disabled={ busy } onClick={ resume }>{ busy ? <Spinner /> : "Resume" }</button>
        </div>
    );
}


/**
 * Settled gasless ops for the connected address, straight from the relayer (server-authoritative — survives any device, no
 * local storage). History only; the in-flight + live-ETA view is intentionally deferred until the gasless flow is verified
 * on-chain.
 */
export function GaslessHistory( props: { jobs: GaslessJob[] } )
{
    if(  props.jobs.length === 0  )  return null;

    return (
        <div className="card">
            <h3 className="card-title">Recent gasless activity</h3>
            <div className="stack" style={ { gap: 10 } }>
                { props.jobs.map(( job ) => <GaslessHistoryRow key={ job.id } job={ job } /> ) }
            </div>
        </div>
    );
}

const GASLESS_STATUS_LABEL: Record<GaslessJob[ "status" ], string>  =  {
    received:          "Submitting",
    committed:         "Committing",
    executing:         "Executing",
    executed:          "Protected",
    protocol_reverted: "Reverted",
    failed:            "Failed",
};

function GaslessHistoryRow( props: { job: GaslessJob } )
{
    const { job }  =  props;
    const detail   =  job.summary.pay !== undefined && job.summary.receive !== undefined
        ?  `${ job.summary.pay } → ${ job.summary.receive }`
        :  job.summary.kind;

    return (
        <div className="between" style={ { borderTop: "1px solid var(--rule-faint)", paddingTop: 10 } }>
            <div className="stack" style={ { gap: 4 } }>
                <span className="val" style={ { textTransform: "capitalize" } }>{ job.summary.kind }</span>
                <span className="tiny muted">{ detail }</span>
            </div>
            <div className="stack" style={ { gap: 4, alignItems: "flex-end" } }>
                <Pill tone={ job.status === "executed" ? "green" : "amber" }>{ GASLESS_STATUS_LABEL[ job.status ] }</Pill>
                <span className="tiny mono muted">{ time_ago( job.settled_at ?? job.committed_at ) }</span>
            </div>
        </div>
    );
}

function time_ago( ms: number ): string
{
    const seconds  =  Math.max( 0, Math.floor( ( Date.now() - ms ) / 1000 ) );
    if(  seconds < 60  )  return `${ seconds }s ago`;
    const minutes  =  Math.floor( seconds / 60 );
    if(  minutes < 60  )  return `${ minutes }m ago`;
    const hours    =  Math.floor( minutes / 60 );
    if(  hours < 24  )    return `${ hours }h ago`;
    return `${ Math.floor( hours / 24 ) }d ago`;
}

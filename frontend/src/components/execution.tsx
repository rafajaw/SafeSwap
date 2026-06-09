import { useState } from "react";
import type { SafeSwapSigningPreview } from "@safeswap/sdk/source";
import { Segmented } from "./ui";

export type ExecutionMode  =  "gasless" | "self_execute";

/**
 * Execution-mode toggle (FRONTEND_SPEC_DECISIONS "Two execution modes"). Gasless is the default. It is disabled — forcing
 * self-execute — when no relayer is configured or the wallet can't sign 7702. (Native funding is supported gaslessly now.)
 */
export function ExecutionModeToggle( props: {
    mode:           ExecutionMode;
    onChange:       ( mode: ExecutionMode ) => void;
    gasless_blocked_reason: string | null;
} )
{
    const blocked  =  props.gasless_blocked_reason !== null;

    return (
        <div className="stack" style={ { gap: 6 } }>
            <span className="label">Execution</span>
            <Segmented<ExecutionMode>
                value={ props.mode }
                onChange={ props.onChange }
                options={ [
                    { value: "gasless", label: "Gasless", disabled: blocked, disabled_hint: props.gasless_blocked_reason ?? undefined },
                    { value: "self_execute", label: "Self-execute" },
                ] }
            />
            { blocked && <span className="tiny muted">{ props.gasless_blocked_reason }</span> }
            { blocked === false && props.mode === "gasless" && <span className="tiny muted">You sign only — the relayer sponsors gas. Zero on-chain transactions.</span> }
        </div>
    );
}

/**
 * The protective bound, set directly and explicitly by the user (the spec's core product statement — not "slippage"). Whatever
 * the user sets IS the signed/enforced value; below it the action reverts. Under BondRoute a generous bound cannot be extracted.
 */
export function MinimumBound( props: {
    label:    string;
    value:    string;
    onChange: ( value: string ) => void;
    symbol:   string;
    kind:     "receive" | "pay" | "deposit";
} )
{
    const verb  =  props.kind === "receive" ? "You'll get at least this or the action reverts."
                :  props.kind === "pay"     ? "You'll pay at most this or the action reverts."
                :                             "You'll deposit at least this or the action reverts.";

    return (
        <div className="stack" style={ { gap: 6 } }>
            <div className="between">
                <span className="label">{ props.label }</span>
                <span className="tiny muted">{ props.symbol }</span>
            </div>
            <input className="input mono" value={ props.value } onChange={ ( event ) => props.onChange( event.target.value ) } />
            <span className="tiny muted">{ verb }</span>
            <span className="tiny" style={ { color: "var(--green-dim)" } }>Protected execution means no bots can take the gap — set it as safe as you like.</span>
        </div>
    );
}

/**
 * The wallet signing preview as a trust panel (handoff §8): human fields first, raw digest / protocol / token anchors / stake
 * / salt under "Advanced verification". These values are verified against the on-chain BondRoute signing digest by the SDK.
 */
export function SigningTrustPanel( props: { preview: SafeSwapSigningPreview } )
{
    const [ open, set_open ]  =  useState( false );
    const { preview }         =  props;

    return (
        <div className="card" style={ { background: "var(--surface-2)" } }>
            <div className="between">
                <h3 className="card-title" style={ { fontSize: 15 } }>Wallet will show</h3>
                <span className="pill green">Verified digest</span>
            </div>
            <div className="kv" style={ { marginTop: 12 } }>
                { preview.fields.map(( field ) => (
                    <div className="line" key={ field.name }>
                        <span className="k">{ field.name }</span>
                        <span className="v">{ field.value }</span>
                    </div>
                ) ) }
            </div>
            <details className="disclosure" open={ open } onToggle={ ( event ) => set_open( ( event.target as HTMLDetailsElement ).open ) }>
                <summary>Advanced verification</summary>
                <div className="kv">
                    <div className="line"><span className="k">Digest</span><span className="v">{ preview.digest }</span></div>
                    <div className="line"><span className="k">Protocol</span><span className="v">{ preview.protocol }</span></div>
                    { preview.fundings.map(( funding, index ) => (
                        <div className="line" key={ index }><span className="k">Funding { index }</span><span className="v">{ funding.amount.toString() } @ { funding.token }</span></div>
                    ) ) }
                    <div className="line"><span className="k">Stake</span><span className="v">{ preview.stake.amount.toString() } @ { preview.stake.token }</span></div>
                    <div className="line"><span className="k">Salt</span><span className="v">{ preview.salt.toString() }</span></div>
                </div>
            </details>
        </div>
    );
}

/** The guided progress rail. Gasless: Sign → In progress → Done. Self-execute: Commit → Active → Execute → Done. */
export function ProgressRail( props: { steps: string[], current: number } )
{
    return (
        <div className="rail">
            { props.steps.map(( name, index ) => {
                const state  =  index < props.current ? "done" : index === props.current ? "active" : "";
                const is_last  =  index === props.steps.length - 1;
                return (
                    <div className={ `step ${ state }` } key={ name } style={ { flex: is_last ? "none" : 1 } }>
                        <span className="node">{ index < props.current ? "✓" : index + 1 }</span>
                        <span className="name">{ name }</span>
                        { is_last === false && <span className={ `bar ${ index < props.current ? "done" : "" }` } /> }
                    </div>
                );
            } ) }
        </div>
    );
}

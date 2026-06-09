import type { ReactNode } from "react";

export function Wordmark()
{
    return <span className="wordmark"><span className="safe">Safe</span><span className="swap">Swap</span></span>;
}

export function Spinner()
{
    return <span className="spinner" aria-label="loading" />;
}

export function Pill( props: { children: ReactNode, tone?: "default" | "green" | "amber", tech?: boolean } )
{
    return <span className={ `pill ${ props.tone ?? "default" } ${ props.tech ? "tech" : "" }` }>{ props.children }</span>;
}

export function Notice( props: { tone: "err" | "ok" | "warn", children: ReactNode } )
{
    return <div className={ `notice ${ props.tone }` }>{ props.children }</div>;
}

/** Info icon with a hover bubble — the spec's "info icon / hover" for term explanations (e.g. Repricing rebate). */
export function InfoHint( props: { text: string } )
{
    return (
        <span className="info-hint" tabIndex={ 0 }>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <circle cx="12" cy="12" r="10" /><line x1="12" y1="11" x2="12" y2="16" /><circle cx="12" cy="7.5" r="0.6" fill="currentColor" />
            </svg>
            <span className="bubble">{ props.text }</span>
        </span>
    );
}

export function Field( props: { label: ReactNode, children: ReactNode, hint?: string } )
{
    return (
        <label className="field">
            <span className="label">{ props.label }{ props.hint !== undefined && <> <InfoHint text={ props.hint } /></> }</span>
            { props.children }
        </label>
    );
}

export function TextInput( props: { value: string, onChange: ( value: string ) => void, placeholder?: string, mono?: boolean, disabled?: boolean } )
{
    return (
        <input
            className={ `input ${ props.mono ? "mono" : "" }` }
            value={ props.value }
            placeholder={ props.placeholder }
            disabled={ props.disabled }
            onChange={ ( event ) => props.onChange( event.target.value ) }
        />
    );
}

export function Segmented<T extends string>( props: {
    options: { value: T, label: string, disabled?: boolean, disabled_hint?: string }[];
    value:   T;
    onChange: ( value: T ) => void;
} )
{
    return (
        <div className="segmented">
            { props.options.map(( option ) => (
                <button
                    key={ option.value }
                    type="button"
                    title={ option.disabled ? option.disabled_hint : undefined }
                    disabled={ option.disabled }
                    className={ option.value === props.value ? "active" : "" }
                    onClick={ () => props.onChange( option.value ) }
                >
                    { option.label }
                </button>
            ) ) }
        </div>
    );
}

/**
 * The green value block (handoff §3/§14): small label, large green value, green delta, muted methodology line. Estimated
 * green numbers are starred; realized/collectible green values are not (and carry no % or "vs ordinary" markers).
 */
export function ValueCard( props: { label: string, amount: string, delta?: string, method?: string, starred?: boolean } )
{
    return (
        <div className="value-card">
            <span className={ `label ${ props.starred ? "starred" : "" }` }>{ props.label }</span>
            <span className="amount">{ props.amount }</span>
            { props.delta !== undefined && <span className="delta">{ props.delta }</span> }
            { props.method !== undefined && <span className="method">{ props.method }</span> }
        </div>
    );
}

export function KeyValue( props: { rows: { k: ReactNode, v: ReactNode, tone?: "green" | "red" }[] } )
{
    return (
        <div className="kv">
            { props.rows.map(( row, index ) => (
                <div className="line" key={ index }>
                    <span className="k">{ row.k }</span>
                    <span className={ `v ${ row.tone ?? "" }` }>{ row.v }</span>
                </div>
            ) ) }
        </div>
    );
}

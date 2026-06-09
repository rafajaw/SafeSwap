import { useState } from "react";
import type { SafeSwapPositionCard } from "@safeswap/sdk/source";
import { Pill } from "./ui";

/**
 * The LP position card — its visual identity and text fields come straight from the on-chain `tokenURI` (handoff §9 /
 * FRONTEND_SPEC_DECISIONS "Position card = the on-chain NFT"). The SVG `image` is the identity; attribute values are the
 * on-chain truth. No fabricated metrics, and intentionally no base/repricing fee split (combined figures only, no indexer).
 */
export function PositionCard( props: {
    card:       SafeSwapPositionCard;
    onAdd?:     () => void;
    onRemove?:  () => void;
    onCollect?: () => void;
} )
{
    const [ verify_open, set_verify_open ]  =  useState( false );
    const attr  =  ( key: string ): string => props.card.attributes[ key ] ?? "—";
    const status  =  attr( "Status" );

    return (
        <div className="card">
            <div className="row" style={ { gap: 18, alignItems: "flex-start", flexWrap: "wrap" } }>
                { props.card.image !== "" && (
                    <div className="nft-frame">
                        <img src={ props.card.image } alt={ `SafeSwap position ${ props.card.token_id.toString() }` } />
                    </div>
                ) }
                <div className="stack" style={ { flex: 1, minWidth: 240 } }>
                    <div className="between">
                        <h3 className="card-title">{ attr( "Pair" ) }</h3>
                        <Pill tone={ status === "In Range" ? "green" : status === "Out of Range" ? "amber" : "default" }>{ status }</Pill>
                    </div>

                    <Attribute label="Current Position" value={ attr( "Current Position" ) } />
                    <Attribute label="Claimable fees" value={ attr( "Claimable Fees" ) } green />
                    <Attribute label="Lifetime fees" value={ attr( "Lifetime Fees" ) } />
                    <Attribute label="Annualized fee yield estimate" value={ attr( "Annualized Fee Yield Estimate" ) } starred />

                    <div className="row" style={ { gap: 8, marginTop: 4 } }>
                        <Pill tech>Base fee { attr( "Base Fee" ) }</Pill>
                        <Pill tech>Repricing rebate { attr( "LP Rebate" ) }</Pill>
                    </div>

                    { ( props.onAdd || props.onRemove || props.onCollect ) && (
                        <div className="row" style={ { gap: 8, marginTop: 6 } }>
                            { props.onAdd     && <button className="btn" onClick={ props.onAdd }>Add</button> }
                            { props.onRemove  && <button className="btn" onClick={ props.onRemove }>Remove</button> }
                            { props.onCollect && <button className="btn" onClick={ props.onCollect }>Collect</button> }
                        </div>
                    ) }

                    <details className="disclosure" open={ verify_open } onToggle={ ( event ) => set_verify_open( ( event.target as HTMLDetailsElement ).open ) }>
                        <summary>Verify on-chain</summary>
                        <div className="kv">
                            { [ "Pool Id", "Hook", "NFT Contract", "Token Id", "Tick Spacing", "Tick Lower", "Tick Upper", "Chain Id" ].map(( key ) => (
                                <div className="line" key={ key }><span className="k">{ key }</span><span className="v">{ attr( key ) }</span></div>
                            ) ) }
                        </div>
                    </details>
                </div>
            </div>
        </div>
    );
}

function Attribute( props: { label: string, value: string, green?: boolean, starred?: boolean } )
{
    return (
        <div className="between">
            <span className={ `label ${ props.starred ? "starred" : "" }` }>{ props.label }</span>
            <span className="mono" style={ { color: props.green ? "var(--green)" : "var(--t-90)", fontSize: 14 } }>{ props.value }</span>
        </div>
    );
}

import { useCallback, useEffect, useState } from "react";
import type { Bond, SafeSwapPositionCard } from "@safeswap/sdk/source";
import { useSafeSwap } from "../context/safeswap_context";
import { PositionCard } from "../components/position_card";
import { ActivityCenter, GaslessHistory } from "../components/activity";
import { KeyValue, Notice, Pill, Spinner } from "../components/ui";
import { load_remembered_token_ids } from "../lib/storage";
import { AddLiquidityScreen } from "./add_liquidity";
import { RemoveCollectScreen } from "./remove_collect";

type SubView =
    | { kind: "list" }
    | { kind: "add", token_id: bigint }
    | { kind: "remove_collect", token_id: bigint, mode: "remove" | "collect" };

export function PortfolioScreen()
{
    const { safeswap, wallet, pending, receipts, gasless_recent, refresh_pending, refresh_activity }  =  useSafeSwap();

    const [ cards, set_cards ]      =  useState<SafeSwapPositionCard[]>( [] );
    const [ loading, set_loading ]  =  useState( false );
    const [ error, set_error ]      =  useState<string | null>( null );
    const [ sub, set_sub ]          =  useState<SubView>( { kind: "list" } );

    const load  =  useCallback( async () => {
        if(  safeswap === null || wallet === null  )  return;
        set_loading( true );
        set_error( null );
        try
        {
            const discovered  =  await safeswap.positions.discover_owned_positions( wallet.address );
            const remembered  =  load_remembered_token_ids( wallet.address ).map(( id ) => BigInt( id ) );
            const ids         =  [ ...new Set([ ...discovered, ...remembered ].map( String ) ) ].map(( id ) => BigInt( id ) );

            const loaded  =  await Promise.all( ids.map( async ( id ) => {
                try { return await safeswap.positions.get_position_card( id ); }
                catch { return null; }   // not owned anymore / burned — drop.
            } ) );
            set_cards( loaded.filter(( card ): card is SafeSwapPositionCard => card !== null ) );
        }
        catch( cause )
        {
            set_error( cause instanceof Error ? cause.message : String( cause ) );
        }
        finally
        {
            set_loading( false );
        }
    }, [ safeswap, wallet ] );

    useEffect( () => { void load(); void refresh_activity(); }, [ load, refresh_activity ] );

    const resume  =  async ( bond: Bond ) => { await bond.resume(); await refresh_pending(); await load(); };

    if(  sub.kind === "add"  )             return <AddLiquidityScreen token_id={ sub.token_id } onBack={ () => { set_sub( { kind: "list" } ); void load(); } } />;
    if(  sub.kind === "remove_collect"  )  return <RemoveCollectScreen token_id={ sub.token_id } initial_mode={ sub.mode } onBack={ () => { set_sub( { kind: "list" } ); void load(); } } />;

    return (
        <div className="stack">
            <ActivityCenter pending={ pending } onResume={ resume } />
            <GaslessHistory jobs={ gasless_recent } />

            <div className="between">
                <h2 className="card-title">Your positions</h2>
                <button className="btn" onClick={ () => void load() }>Refresh</button>
            </div>

            { loading && <div className="card center"><Spinner /> Discovering positions…</div> }
            { error !== null && <Notice tone="warn">Could not load positions. { error }</Notice> }

            { loading === false && cards.length === 0 && (
                <div className="empty">
                    <p className="val" style={ { color: "var(--t-90)" } }>No positions yet.</p>
                    <p>Put your liquidity to work earning swap fees and repricing revenue.</p>
                </div>
            ) }

            <div className="positions-grid">
                { cards.map(( card ) => (
                    <PositionCard
                        key={ card.token_id.toString() }
                        card={ card }
                        onAdd={ () => set_sub( { kind: "add", token_id: card.token_id } ) }
                        onRemove={ () => set_sub( { kind: "remove_collect", token_id: card.token_id, mode: "remove" } ) }
                        onCollect={ () => set_sub( { kind: "remove_collect", token_id: card.token_id, mode: "collect" } ) }
                    />
                ) ) }
            </div>

            { receipts.length > 0 && (
                <div className="card">
                    <h3 className="card-title">Recent activity</h3>
                    <div className="stack" style={ { gap: 12 } }>
                        { receipts.map(( receipt ) => (
                            <div key={ receipt.id } style={ { borderTop: "1px solid var(--rule-faint)", paddingTop: 12 } }>
                                <div className="between">
                                    <span className="val">{ receipt.title }</span>
                                    <Pill tone={ receipt.status === "executed" || receipt.status === "submitted" ? "green" : "amber" }>{ receipt.status }</Pill>
                                </div>
                                <KeyValue rows={ receipt.lines.map(( line ) => ({ k: line.label, v: line.value, tone: line.green ? "green" as const : undefined })) } />
                            </div>
                        ) ) }
                    </div>
                </div>
            ) }
        </div>
    );
}

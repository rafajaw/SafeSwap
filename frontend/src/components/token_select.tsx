import { useState } from "react";
import type { TokenInfo } from "../lib/tokens";
import { require_address } from "../lib/tokens";

/** Token picker over the curated list, with a custom-address fallback (the app accepts any pasted ERC-20). */
export function TokenSelect( props: { tokens: TokenInfo[], value: TokenInfo | null, onChange: ( token: TokenInfo ) => void, exclude?: string } )
{
    const [ custom_open, set_custom_open ]  =  useState( false );
    const [ custom, set_custom ]            =  useState( "" );
    const [ error, set_error ]              =  useState<string | null>( null );

    const choices  =  props.tokens.filter(( token ) => token.address.toLowerCase() !== props.exclude?.toLowerCase() );

    const pick  =  ( address: string ) => {
        if(  address === "__custom__"  )  { set_custom_open( true ); return; }
        const token  =  props.tokens.find(( item ) => item.address === address );
        if(  token !== undefined  )  props.onChange( token );
    };

    const add_custom  =  () => {
        try
        {
            const address  =  require_address( "Token", custom );
            props.onChange({ address, symbol: "TOKEN", decimals: 18, class: "longtail" });
            set_custom_open( false );
            set_custom( "" );
            set_error( null );
        }
        catch( cause )
        {
            set_error( cause instanceof Error ? cause.message : "Invalid address." );
        }
    };

    return (
        <div className="stack" style={ { gap: 6 } }>
            <select className="select" value={ props.value?.address ?? "" } onChange={ ( event ) => pick( event.target.value ) }>
                <option value="" disabled>Select token</option>
                { choices.map(( token ) => <option key={ token.address } value={ token.address }>{ token.symbol }</option> ) }
                <option value="__custom__">Custom address…</option>
            </select>
            { custom_open && (
                <div className="row" style={ { gap: 8 } }>
                    <input className="input mono" placeholder="0x…" value={ custom } onChange={ ( event ) => set_custom( event.target.value ) } />
                    <button className="btn" onClick={ add_custom }>Add</button>
                </div>
            ) }
            { error !== null && <span className="tiny" style={ { color: "var(--red)" } }>{ error }</span> }
        </div>
    );
}

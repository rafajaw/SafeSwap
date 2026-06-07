import { useState } from "react";
import {
    SafeSwap,
    parse_safeswap_revert,
    type PoolInfo,
    type PreparedSafeSwapOperation,
    type SafeSwapOperationKind,
    type SafeSwapSigningPreview,
} from "@safeswap/sdk/source";
import type { Address, PublicClient } from "viem";
import { BONDROUTE_ADDRESS, SAFESWAP_NFT_ADDRESS, SAFESWAP_ROUTER_ADDRESS } from "./constants";
import { parse_token_amount, require_address } from "./token_metadata";
import { connect_wallet, has_wallet_provider, short_address } from "./wallet";
import type { WalletState } from "./types";
import { signing_preview_rows } from "./signing_preview";

type FormState = {
    action: SafeSwapOperationKind;
    token_a: string;
    token_b: string;
    amount_a: string;
    amount_b: string;
    minimum_a: string;
    minimum_b: string;
    token_id: string;
    liquidity: string;
    sqrt_price_lower_x96: string;
    sqrt_price_upper_x96: string;
    sqrt_price_x96: string;
    base_fee_bps: string;
    rebate_percent: string;
    tick_spacing: string;
    preferred_stake_token: string;
};

type ReviewState = {
    operation: PreparedSafeSwapOperation;
    preview:   SafeSwapSigningPreview;
};

const EMPTY_WALLET: WalletState  =  {
    address: null, chain_id: null, public_client: null, wallet_client: null,
};

const DEFAULT_FORM: FormState  =  {
    action: "swap_exact_input",
    token_a: "",
    token_b: "",
    amount_a: "",
    amount_b: "",
    minimum_a: "0",
    minimum_b: "0",
    token_id: "",
    liquidity: "",
    sqrt_price_lower_x96: "",
    sqrt_price_upper_x96: "",
    sqrt_price_x96: "",
    base_fee_bps: "30",
    rebate_percent: "50",
    tick_spacing: "60",
    preferred_stake_token: "",
};

const ACTION_LABELS: Record<SafeSwapOperationKind, string>  =  {
    swap_exact_input:  "Swap exact input",
    swap_exact_output: "Swap exact output",
    create_position:   "Create position",
    add_liquidity:     "Add liquidity",
    remove_liquidity:  "Remove liquidity",
    collect_fees:      "Collect fees",
};

export function App()
{
    const [ wallet, set_wallet ]              =  useState<WalletState>( EMPTY_WALLET );
    const [ safeswap, set_safeswap ]          =  useState<SafeSwap | null>( null );
    const [ form, set_form ]                   =  useState<FormState>( DEFAULT_FORM );
    const [ review, set_review ]               =  useState<ReviewState | null>( null );
    const [ is_working, set_is_working ]       =  useState( false );
    const [ error, set_error ]                 =  useState<string | null>( null );
    const [ status, set_status ]               =  useState<string | null>( null );

    async function connect()
    {
        set_error( null );
        try
        {
            if(  SAFESWAP_ROUTER_ADDRESS === "" || SAFESWAP_NFT_ADDRESS === ""  )
            {
                throw new Error( "Set VITE_SAFESWAP_ROUTER_ADDRESS and VITE_SAFESWAP_NFT_ADDRESS." );
            }
            if(  ! has_wallet_provider()  )  throw new Error( "Install or unlock an injected wallet." );

            const connected  =  await connect_wallet();
            if(  connected.address === null || connected.public_client === null || connected.wallet_client === null  )
            {
                throw new Error( "Wallet connection is incomplete." );
            }

            const sdk  =  await SafeSwap.init({
                public_client: connected.public_client,
                wallet_client: connected.wallet_client,
                account: connected.address,
                router_address: SAFESWAP_ROUTER_ADDRESS,
                nft_address: SAFESWAP_NFT_ADDRESS,
                bondroute_address: BONDROUTE_ADDRESS === "" ? undefined : BONDROUTE_ADDRESS,
                on_pending_bond: ( bond ) => set_status( `Recovered pending operation ${ bond.commitment_hash }.` ),
            });

            set_wallet( connected );
            set_safeswap( sdk );
        }
        catch( cause )
        {
            set_error( error_message( cause ) );
        }
    }

    async function prepare()
    {
        if(  safeswap === null || wallet.public_client === null  )
        {
            set_error( "Connect a wallet first." );
            return;
        }

        set_is_working( true );
        set_error( null );
        set_status( null );
        try
        {
            const operation  =  await prepare_operation( safeswap, wallet.public_client, form );
            const preview    =  await operation.get_signing_preview();
            set_review({ operation, preview });
            set_status( "Verified against the on-chain BondRoute signing digest." );
        }
        catch( cause )
        {
            set_error( error_message( cause ) );
        }
        finally
        {
            set_is_working( false );
        }
    }

    async function dispatch()
    {
        if(  review === null  )  return;
        set_is_working( true );
        set_error( null );
        try
        {
            await review.operation.dispatch();
            if(  review.operation.status === "protocol_reverted"  )
            {
                set_error( parse_safeswap_revert( review.operation.revert_output ).description );
            }
            else
            {
                set_status( `Operation settled as ${ review.operation.status }.` );
            }
        }
        catch( cause )
        {
            set_error( error_message( cause ) );
        }
        finally
        {
            set_is_working( false );
        }
    }

    return (
        <main className="app_shell">
            <header className="top_bar">
                <div>
                    <p className="eyebrow">SafeSwap</p>
                    <h1>MEV protection for traders. Repricing revenue for LPs.</h1>
                </div>
                <div className="wallet_box">
                    { wallet.address === null
                        ? <button className="primary_button" onClick={ connect }>Connect wallet</button>
                        : <><span>{ short_address( wallet.address ) }</span><span>Chain { wallet.chain_id }</span></> }
                </div>
            </header>

            <section className="workspace">
                <div className="operation_panel">
                    <label className="text_field">
                        <span>Protected action</span>
                        <select value={ form.action } onChange={ ( event ) => set_form({ ...form, action: event.target.value as SafeSwapOperationKind }) }>
                            { Object.entries( ACTION_LABELS ).map(( [ value, label ] ) => <option value={ value } key={ value }>{ label }</option> ) }
                        </select>
                    </label>

                    <div className="field_grid">
                        <Field label="Token A / input" value={ form.token_a } set_value={ ( value ) => set_form({ ...form, token_a: value }) } />
                        <Field label="Token B / output" value={ form.token_b } set_value={ ( value ) => set_form({ ...form, token_b: value }) } />
                    </div>
                    <div className="field_grid">
                        <Field label={ amount_a_label( form.action ) } value={ form.amount_a } set_value={ ( value ) => set_form({ ...form, amount_a: value }) } />
                        <Field label={ amount_b_label( form.action ) } value={ form.amount_b } set_value={ ( value ) => set_form({ ...form, amount_b: value }) } />
                    </div>

                    { is_position_action( form.action ) && form.action !== "create_position" && (
                        <Field label="Position token ID" value={ form.token_id } set_value={ ( value ) => set_form({ ...form, token_id: value }) } />
                    ) }
                    { is_liquidity_amount_action( form.action ) && (
                        <Field label="Liquidity" value={ form.liquidity } set_value={ ( value ) => set_form({ ...form, liquidity: value }) } />
                    ) }
                    { form.action === "create_position" && (
                        <>
                            <Field label="Lower sqrt price X96" value={ form.sqrt_price_lower_x96 } set_value={ ( value ) => set_form({ ...form, sqrt_price_lower_x96: value }) } />
                            <Field label="Upper sqrt price X96" value={ form.sqrt_price_upper_x96 } set_value={ ( value ) => set_form({ ...form, sqrt_price_upper_x96: value }) } />
                            <Field label="Initial sqrt price X96" value={ form.sqrt_price_x96 } set_value={ ( value ) => set_form({ ...form, sqrt_price_x96: value }) } />
                        </>
                    ) }
                    { is_position_action( form.action ) && (
                        <div className="field_grid">
                            <Field label="Minimum token A" value={ form.minimum_a } set_value={ ( value ) => set_form({ ...form, minimum_a: value }) } />
                            <Field label="Minimum token B" value={ form.minimum_b } set_value={ ( value ) => set_form({ ...form, minimum_b: value }) } />
                        </div>
                    ) }

                    <div className="field_grid">
                        <Field label="Base fee (bps)" value={ form.base_fee_bps } set_value={ ( value ) => set_form({ ...form, base_fee_bps: value }) } />
                        <Field label="Repricing capture (%)" value={ form.rebate_percent } set_value={ ( value ) => set_form({ ...form, rebate_percent: value }) } />
                    </div>
                    <Field label="Tick spacing" value={ form.tick_spacing } set_value={ ( value ) => set_form({ ...form, tick_spacing: value }) } />
                    { is_position_action( form.action ) && (
                        <Field label="Preferred stake token (optional)" value={ form.preferred_stake_token } set_value={ ( value ) => set_form({ ...form, preferred_stake_token: value }) } />
                    ) }

                    <button className="primary_button full_width" disabled={ is_working } onClick={ prepare }>
                        { is_working ? "Preparing..." : "Prepare and verify" }
                    </button>
                </div>

                <Review review={ review } is_working={ is_working } dispatch={ dispatch } />
            </section>

            { error !== null && <div className="notice error_notice">{ error }</div> }
            { status !== null && <div className="notice status_notice">{ status }</div> }
        </main>
    );
}

function Review( props: { review: ReviewState | null, is_working: boolean, dispatch: () => Promise<void> } )
{
    if(  props.review === null  )
    {
        return <aside className="review_panel empty_review"><h2>Verified signing preview</h2><p>Prepare an action to load the exact REFERENCE_2 values committed by BondRoute.</p></aside>;
    }

    const { operation, preview }  =  props.review;
    return (
        <aside className="review_panel">
            <div className="review_header">
                <div><p className="eyebrow">Digest verified</p><h2>{ ACTION_LABELS[ operation.kind ] }</h2></div>
                <span className="status_pill">REFERENCE_2</span>
            </div>
            <dl className="detail_rows">
                <Row label="Protocol" value={ preview.protocol } />
                <Row label="Action type" value={ preview.action_type } />
                <Row label="Digest" value={ preview.digest } />
            </dl>
            <section className="detail_section">
                <h3>Wallet message</h3>
                <dl className="signing_fields">
                    { signing_preview_rows( preview ).map(( field ) => <Row label={ field.label } value={ field.value } key={ field.label } />) }
                </dl>
            </section>
            <section className="detail_section">
                <h3>Raw commitments</h3>
                <p className="muted_text">Fundings: { preview.fundings.map(( item ) => `${ item.amount } @ ${ item.token }`).join( ", " ) || "none" }</p>
                <p className="muted_text">Stake: { preview.stake.amount } @ { preview.stake.token }</p>
                <p className="muted_text">Salt: { preview.salt.toString() }</p>
            </section>
            <button className="primary_button full_width" disabled={ props.is_working } onClick={ props.dispatch }>
                { props.is_working ? "Dispatching..." : "Dispatch verified operation" }
            </button>
        </aside>
    );
}

function Row( props: { label: string, value: string } )
{
    return <div><dt>{ props.label }</dt><dd>{ props.value }</dd></div>;
}

function Field( props: { label: string, value: string, set_value: ( value: string ) => void } )
{
    return <label className="text_field"><span>{ props.label }</span><input value={ props.value } onChange={ ( event ) => props.set_value( event.target.value ) } /></label>;
}

async function prepare_operation( sdk: SafeSwap, public_client: PublicClient, form: FormState ): Promise<PreparedSafeSwapOperation>
{
    const token_a  =  require_address( "Token A", form.token_a );
    const token_b  =  require_address( "Token B", form.token_b );
    const pool_info  =  parse_pool_info( form );
    const preferred_stake_token  =  form.preferred_stake_token.trim() === "" ? undefined : require_address( "Preferred stake token", form.preferred_stake_token );

    if(  form.action === "swap_exact_input"  )
    {
        return await sdk.swaps.prepare_swap_exact_input({
            input: { token: token_a, exact_amount: await parse_token_amount( public_client, token_a, form.amount_a ) },
            output: { token: token_b, minimum_amount: await parse_token_amount( public_client, token_b, form.amount_b ) },
            pool_info,
        });
    }
    if(  form.action === "swap_exact_output"  )
    {
        return await sdk.swaps.prepare_swap_exact_output({
            input: { token: token_a, maximum_amount: await parse_token_amount( public_client, token_a, form.amount_a ) },
            output: { token: token_b, exact_amount: await parse_token_amount( public_client, token_b, form.amount_b ) },
            pool_info,
        });
    }

    const minimum_a  =  await parse_token_amount( public_client, token_a, form.minimum_a );
    const minimum_b  =  await parse_token_amount( public_client, token_b, form.minimum_b );
    if(  form.action === "create_position"  )
    {
        return await sdk.positions.prepare_create_position({
            pool_info,
            sqrt_price_lower_x96: parse_bigint( "Lower sqrt price", form.sqrt_price_lower_x96 ),
            sqrt_price_upper_x96: parse_bigint( "Upper sqrt price", form.sqrt_price_upper_x96 ),
            sqrt_price_x96: parse_bigint( "Initial sqrt price", form.sqrt_price_x96 ),
            liquidity: parse_bigint( "Liquidity", form.liquidity ),
            a: { token: token_a, amount: await parse_token_amount( public_client, token_a, form.amount_a ), minimum_deposited: minimum_a },
            b: { token: token_b, amount: await parse_token_amount( public_client, token_b, form.amount_b ), minimum_deposited: minimum_b },
            preferred_stake_token,
        });
    }

    const token_id  =  parse_bigint( "Token ID", form.token_id );
    if(  form.action === "add_liquidity"  )
    {
        return await sdk.positions.prepare_add_liquidity({
            token_id, liquidity: parse_bigint( "Liquidity", form.liquidity ),
            a: { token: token_a, amount: await parse_token_amount( public_client, token_a, form.amount_a ), minimum_deposited: minimum_a },
            b: { token: token_b, amount: await parse_token_amount( public_client, token_b, form.amount_b ), minimum_deposited: minimum_b },
            preferred_stake_token,
        });
    }
    if(  form.action === "remove_liquidity"  )
    {
        return await sdk.positions.prepare_remove_liquidity({
            token_id, liquidity: parse_bigint( "Liquidity", form.liquidity ),
            a: { token: token_a, minimum_received: minimum_a },
            b: { token: token_b, minimum_received: minimum_b },
            preferred_stake_token,
        });
    }
    return await sdk.positions.prepare_collect_fees({
        token_id,
        a: { token: token_a, minimum_received: minimum_a },
        b: { token: token_b, minimum_received: minimum_b },
        preferred_stake_token,
    });
}

function parse_pool_info( form: FormState ): PoolInfo
{
    return {
        base_fee_bps: parse_number( "Base fee", form.base_fee_bps ),
        rebate_percent: parse_number( "Repricing capture", form.rebate_percent ),
        tick_spacing: parse_number( "Tick spacing", form.tick_spacing ),
    };
}

function parse_number( label: string, value: string ): number
{
    const parsed  =  Number( value );
    if(  ! Number.isInteger( parsed )  )  throw new Error( `${ label } must be an integer.` );
    return parsed;
}

function parse_bigint( label: string, value: string ): bigint
{
    if(  value.trim() === ""  )  throw new Error( `${ label } is required.` );
    return BigInt( value );
}

function is_position_action( action: SafeSwapOperationKind ): boolean
{
    return action !== "swap_exact_input" && action !== "swap_exact_output";
}

function is_liquidity_amount_action( action: SafeSwapOperationKind ): boolean
{
    return action === "create_position" || action === "add_liquidity" || action === "remove_liquidity";
}

function amount_a_label( action: SafeSwapOperationKind ): string
{
    if(  action === "swap_exact_input"  )  return "Exact input";
    if(  action === "swap_exact_output"  ) return "Maximum input";
    if(  action === "create_position" || action === "add_liquidity"  )  return "Token A funding cap";
    return "Token A amount (unused)";
}

function amount_b_label( action: SafeSwapOperationKind ): string
{
    if(  action === "swap_exact_input"  )  return "Minimum output";
    if(  action === "swap_exact_output"  ) return "Exact output";
    if(  action === "create_position" || action === "add_liquidity"  )  return "Token B funding cap";
    return "Token B amount (unused)";
}

function error_message( cause: unknown ): string
{
    return cause instanceof Error ? cause.message : String( cause );
}

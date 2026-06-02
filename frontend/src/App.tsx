import { useEffect, useMemo, useState } from "react";
import { SafeSwap, parse_safeswap_revert, type PoolInfo, type PreparedSafeSwapOperation } from "@safeswap/sdk/source";
import type { Address } from "viem";
import {
    BONDROUTE_ADDRESS,
    DEFAULT_POOL_FEE,
    DEFAULT_SLIPPAGE_PERCENT,
    DEFAULT_TICK_LOWER,
    DEFAULT_TICK_SPACING,
    DEFAULT_TICK_UPPER,
    SAFESWAP_ADDRESS,
} from "./constants";
import { empty_position_row, load_tracked_positions, remove_tracked_position, save_tracked_position } from "./positions";
import { get_token_metadata, parse_token_amount, render_token_amount, require_address } from "./token_metadata";
import type { AppView, LiquidityMode, PositionRow, PreparedOperationState, SafeSwapRuntime, SwapMode, TrackedPosition, WalletState } from "./types";
import { connect_wallet, has_wallet_provider, short_address } from "./wallet";

type SwapFormState = {
    mode:                  SwapMode;
    input_token:           string;
    output_token:          string;
    input_amount:          string;
    output_amount:         string;
    output_minimum_amount: string;
    input_maximum_amount:  string;
    fee:                   string;
    tick_spacing:          string;
};

type LiquidityFormState = {
    mode:                      LiquidityMode;
    token_a:                   string;
    token_b:                   string;
    amount_a:                  string;
    amount_b:                  string;
    minimum_added_a:           string;
    minimum_added_b:           string;
    minimum_received_a:        string;
    minimum_received_b:        string;
    liquidity:                 string;
    fee:                       string;
    tick_spacing:              string;
    tick_lower:                string;
    tick_upper:                string;
    preferred_stake_token:     string;
};

type DonateFormState = {
    token_a:               string;
    token_b:               string;
    amount_a:              string;
    amount_b:              string;
    fee:                   string;
    tick_spacing:          string;
    preferred_stake_token: string;
};

type ImpactStory = {
    headline:          string;
    primary_label:     string;
    primary_value:     string;
    secondary_label:   string;
    secondary_value:   string;
    proof_label:       string;
    proof_value:       string;
};

type MomentumEvent = {
    label: string;
    value: string;
};

const default_swap_form: SwapFormState = {
    mode:                  "exact_input",
    input_token:           "",
    output_token:          "",
    input_amount:          "",
    output_amount:         "",
    output_minimum_amount: "",
    input_maximum_amount:  "",
    fee:                   DEFAULT_POOL_FEE,
    tick_spacing:          DEFAULT_TICK_SPACING,
};

const default_liquidity_form: LiquidityFormState = {
    mode:                  "add",
    token_a:               "",
    token_b:               "",
    amount_a:              "",
    amount_b:              "",
    minimum_added_a:       "",
    minimum_added_b:       "",
    minimum_received_a:    "",
    minimum_received_b:    "",
    liquidity:             "",
    fee:                   DEFAULT_POOL_FEE,
    tick_spacing:          DEFAULT_TICK_SPACING,
    tick_lower:            DEFAULT_TICK_LOWER,
    tick_upper:            DEFAULT_TICK_UPPER,
    preferred_stake_token: "",
};

const default_donate_form: DonateFormState = {
    token_a:               "",
    token_b:               "",
    amount_a:              "",
    amount_b:              "",
    fee:                   DEFAULT_POOL_FEE,
    tick_spacing:          DEFAULT_TICK_SPACING,
    preferred_stake_token: "",
};

export function App()
{
    const empty_wallet_state: WalletState                     =  { address: null, chain_id: null, public_client: null, wallet_client: null };
    const [ wallet, set_wallet ]                              =  useState<WalletState>( empty_wallet_state );
    const [ safeswap, set_safeswap ]                          =  useState<SafeSwap | null>( null );
    const [ active_view, set_active_view ]                    =  useState<AppView>( "swap" );
    const [ swap_form, set_swap_form ]                        =  useState<SwapFormState>( default_swap_form );
    const [ liquidity_form, set_liquidity_form ]              =  useState<LiquidityFormState>( default_liquidity_form );
    const [ donate_form, set_donate_form ]                    =  useState<DonateFormState>( default_donate_form );
    const [ prepared_operation, set_prepared_operation ]      =  useState<PreparedOperationState | null>( null );
    const [ tracked_positions, set_tracked_positions ]        =  useState<TrackedPosition[]>( [] );
    const [ position_rows, set_position_rows ]                =  useState<PositionRow[]>( [] );
    const [ is_preparing, set_is_preparing ]                  =  useState( false );
    const [ is_dispatching, set_is_dispatching ]              =  useState( false );
    const [ app_error, set_app_error ]                        =  useState<string | null>( null );
    const [ status_message, set_status_message ]              =  useState<string | null>( null );
    const [ celebration_key, set_celebration_key ]            =  useState( 0 );

    const runtime  =  useMemo<SafeSwapRuntime | null>(() => {
        if(  safeswap === null  )  return null;
        return { safeswap, wallet };
    }, [ safeswap, wallet ]);

    const impact_story  =  useMemo(() => {
        return build_impact_story({
            active_view,
            swap_form,
            liquidity_form,
            donate_form,
            tracked_positions_count: tracked_positions.length,
        });
    }, [ active_view, swap_form, liquidity_form, donate_form, tracked_positions.length ]);

    useEffect(() => {
        set_tracked_positions( load_tracked_positions( wallet.address ) );
    }, [ wallet.address ]);

    useEffect(() => {
        void refresh_position_rows();
    }, [ tracked_positions, safeswap, wallet.address ]);

    async function connect()
    {
        clear_feedback();

        try
        {
            if(  SAFESWAP_ADDRESS === ""  )  throw_ui_error( "Set VITE_SAFESWAP_ADDRESS before using the app." );
            if(  has_wallet_provider() == false  )  throw_ui_error( "Install or unlock an injected wallet." );

            const connected_wallet  =  await connect_wallet();
            if(  connected_wallet.address === null  )       throw new Error( "Wallet connection is incomplete." );
            if(  connected_wallet.public_client === null  ) throw new Error( "Wallet connection is incomplete." );
            if(  connected_wallet.wallet_client === null  ) throw new Error( "Wallet connection is incomplete." );

            const initialized       =  await SafeSwap.init({
                public_client:     connected_wallet.public_client,
                wallet_client:     connected_wallet.wallet_client,
                account:           connected_wallet.address,
                safeswap_address:  SAFESWAP_ADDRESS,
                bondroute_address: BONDROUTE_ADDRESS === ""  ?  undefined  :  BONDROUTE_ADDRESS,
                on_pending_bond:   ( operation ) => set_status_message( `Recovered pending operation ${ operation.commitment_hash }.` ),
            });

            set_wallet( connected_wallet );
            set_safeswap( initialized );
        }
        catch( error )
        {
            set_app_error( error_message( error ) );
        }
    }

    async function prepare_active_operation()
    {
        if(  runtime === null  )  return set_app_error( "Connect a wallet first." );

        clear_feedback();
        set_is_preparing( true );

        try
        {
            const operation  =  await prepare_operation( runtime );
            const reviewed   =  await review_operation( operation );

            set_prepared_operation( reviewed );
            set_status_message( "Operation prepared. Review details before dispatching." );

            if(  active_view === "liquidity"  )  await remember_liquidity_range( runtime );
        }
        catch( error )
        {
            set_app_error( error_message( error ) );
        }
        finally
        {
            set_is_preparing( false );
        }
    }

    async function dispatch_prepared_operation()
    {
        if(  prepared_operation === null  )  return;

        clear_feedback();
        set_is_dispatching( true );

        try
        {
            await prepared_operation.operation.dispatch();
            await refresh_prepared_operation( prepared_operation.operation );

            if(  prepared_operation.operation.status === "executed"  )
            {
                set_status_message( "Operation executed. Protected value stayed with the user." );
                set_celebration_key( celebration_key + 1 );
            }
            if(  prepared_operation.operation.status === "protocol_reverted"  )
            {
                const parsed  =  parse_safeswap_revert( prepared_operation.operation.revert_output );
                set_app_error( parsed.description );
            }
            if(  prepared_operation.operation.status === "invalid_bond"  )  set_app_error( prepared_operation.operation.invalid_reason );
        }
        catch( error )
        {
            set_app_error( error_message( error ) );
        }
        finally
        {
            set_is_dispatching( false );
            await refresh_position_rows();
        }
    }

    async function prepare_operation( current_runtime: SafeSwapRuntime ): Promise<PreparedSafeSwapOperation>
    {
        if(  active_view === "swap"  )      return await prepare_swap_operation( current_runtime );
        if(  active_view === "liquidity"  ) return await prepare_liquidity_operation( current_runtime );
        if(  active_view === "donate"  )    return await prepare_donate_operation( current_runtime );
        throw new Error( "Select an operation first." );
    }

    async function prepare_swap_operation( current_runtime: SafeSwapRuntime ): Promise<PreparedSafeSwapOperation>
    {
        const public_client  =  require_public_client( current_runtime.wallet );
        const input_token    =  require_address( "Input token", swap_form.input_token );
        const output_token   =  require_address( "Output token", swap_form.output_token );
        const pool_info      =  pool_info_from_form( swap_form.fee, swap_form.tick_spacing );

        if(  swap_form.mode === "exact_input"  )
        {
            return await current_runtime.safeswap.prepare_swap_exact_input({
                input:     { token: input_token, exact_amount: await parse_token_amount( public_client, input_token, swap_form.input_amount ) },
                output:    { token: output_token, minimum_amount: await parse_token_amount( public_client, output_token, swap_form.output_minimum_amount ) },
                pool_info,
            });
        }

        return await current_runtime.safeswap.prepare_swap_exact_output({
            input:     { token: input_token, maximum_amount: await parse_token_amount( public_client, input_token, swap_form.input_maximum_amount ) },
            output:    { token: output_token, exact_amount: await parse_token_amount( public_client, output_token, swap_form.output_amount ) },
            pool_info,
        });
    }

    async function prepare_liquidity_operation( current_runtime: SafeSwapRuntime ): Promise<PreparedSafeSwapOperation>
    {
        const public_client          =  require_public_client( current_runtime.wallet );
        const token_a                =  require_address( "Token A", liquidity_form.token_a );
        const token_b                =  require_address( "Token B", liquidity_form.token_b );
        const pool_info              =  pool_info_from_form( liquidity_form.fee, liquidity_form.tick_spacing );
        const preferred_stake_token  =  optional_address( "Preferred stake token", liquidity_form.preferred_stake_token );

        if(  liquidity_form.mode === "add"  )
        {
            const amount_a         =  await parse_token_amount( public_client, token_a, liquidity_form.amount_a );
            const amount_b         =  await parse_token_amount( public_client, token_b, liquidity_form.amount_b );
            const minimum_added_a  =  await parse_token_amount( public_client, token_a, fallback_to_zero( liquidity_form.minimum_added_a ) );
            const minimum_added_b  =  await parse_token_amount( public_client, token_b, fallback_to_zero( liquidity_form.minimum_added_b ) );

            return await current_runtime.safeswap.prepare_add_liquidity({
                a:                     { token: token_a, amount: amount_a, minimum_added: minimum_added_a },
                b:                     { token: token_b, amount: amount_b, minimum_added: minimum_added_b },
                pool_info,
                tick_lower:            number_from_form( "Tick lower", liquidity_form.tick_lower ),
                tick_upper:            number_from_form( "Tick upper", liquidity_form.tick_upper ),
                preferred_stake_token,
            });
        }

        const minimum_received_a  =  await parse_token_amount( public_client, token_a, fallback_to_zero( liquidity_form.minimum_received_a ) );
        const minimum_received_b  =  await parse_token_amount( public_client, token_b, fallback_to_zero( liquidity_form.minimum_received_b ) );

        return await current_runtime.safeswap.prepare_remove_liquidity({
            a:                     { token: token_a, minimum_received: minimum_received_a },
            b:                     { token: token_b, minimum_received: minimum_received_b },
            pool_info,
            tick_lower:            number_from_form( "Tick lower", liquidity_form.tick_lower ),
            tick_upper:            number_from_form( "Tick upper", liquidity_form.tick_upper ),
            liquidity:             bigint_from_form( "Liquidity", liquidity_form.liquidity ),
            preferred_stake_token,
        });
    }

    async function prepare_donate_operation( current_runtime: SafeSwapRuntime ): Promise<PreparedSafeSwapOperation>
    {
        const public_client          =  require_public_client( current_runtime.wallet );
        const token_a                =  require_address( "Token A", donate_form.token_a );
        const token_b                =  require_address( "Token B", donate_form.token_b );
        const preferred_stake_token  =  optional_address( "Preferred stake token", donate_form.preferred_stake_token );

        return await current_runtime.safeswap.prepare_donate({
            a:                     { token: token_a, amount: await parse_token_amount( public_client, token_a, donate_form.amount_a ) },
            b:                     { token: token_b, amount: await parse_token_amount( public_client, token_b, donate_form.amount_b ) },
            pool_info:             pool_info_from_form( donate_form.fee, donate_form.tick_spacing ),
            preferred_stake_token,
        });
    }

    async function review_operation( operation: PreparedSafeSwapOperation ): Promise<PreparedOperationState>
    {
        const description        =  await operation.render_description();
        const missing_balances   =  await operation.get_missing_balances();
        const missing_approvals  =  await operation.get_missing_approvals();

        return { operation, description, missing_balances, missing_approvals };
    }

    async function refresh_prepared_operation( operation: PreparedSafeSwapOperation )
    {
        set_prepared_operation( await review_operation( operation ) );
    }

    async function remember_liquidity_range( current_runtime: SafeSwapRuntime )
    {
        if(  current_runtime.wallet.address === null  )  return;

        const public_client     =  require_public_client( current_runtime.wallet );
        const token_a           =  require_address( "Token A", liquidity_form.token_a );
        const token_b           =  require_address( "Token B", liquidity_form.token_b );
        const token_a_metadata  =  await get_token_metadata( public_client, token_a );
        const token_b_metadata  =  await get_token_metadata( public_client, token_b );
        const next_positions    =  save_tracked_position( current_runtime.wallet.address, {
            token_a,
            token_b,
            token_a_symbol: token_a_metadata.symbol,
            token_b_symbol: token_b_metadata.symbol,
            fee:            number_from_form( "Fee", liquidity_form.fee ),
            tick_spacing:   number_from_form( "Tick spacing", liquidity_form.tick_spacing ),
            tick_lower:     number_from_form( "Tick lower", liquidity_form.tick_lower ),
            tick_upper:     number_from_form( "Tick upper", liquidity_form.tick_upper ),
        });

        set_tracked_positions( next_positions );
    }

    async function refresh_position_rows()
    {
        if(  safeswap === null  ||  wallet.address === null  )
        {
            set_position_rows( tracked_positions.map( empty_position_row ) );
            return;
        }

        const rows  =  await Promise.all( tracked_positions.map( async ( position ) => {
            try
            {
                const pool_info      =  { fee: position.fee, tick_spacing: position.tick_spacing };
                const pool_id        =  await safeswap.get_pool_id( position.token_a, position.token_b, pool_info );
                const position_info  =  await safeswap.get_position_info( pool_id, wallet.address as Address, position.tick_lower, position.tick_upper );
                return { ...position, liquidity: position_info.liquidity, error: null };
            }
            catch( error )
            {
                return { ...position, liquidity: null, error: error_message( error ) };
            }
        }));

        set_position_rows( rows );
    }

    function forget_position( id: string )
    {
        if(  wallet.address === null  )  return;
        set_tracked_positions( remove_tracked_position( wallet.address, id ) );
    }

    function clear_feedback()
    {
        set_app_error( null );
        set_status_message( null );
    }

    return (
        <main className="app_shell">
            <LiveBackground />

            <header className="top_bar">
                <div>
                    <p className="eyebrow">SafeSwap</p>
                    <h1>Trade through the dark. Keep the spread.</h1>
                </div>

                <div className="wallet_box">
                    { wallet.address === null ? (
                        <button className="primary_button" onClick={ connect }>Connect wallet</button>
                    ) : (
                        <>
                            <span>{ short_address( wallet.address ) }</span>
                            <span>Chain { wallet.chain_id }</span>
                        </>
                    )}
                </div>
            </header>

            <section className="story_stage">
                <div className="story_copy">
                    <div className="live_badge">
                        <span></span>
                        Commit-reveal shield live
                    </div>
                    <h2>{ impact_story.headline }</h2>
                    <p>
                        SafeSwap hides the intent first, then reveals only when execution is ready. The user sees the stake,
                        fundings, approvals, and estimated value retained before signing.
                    </p>
                </div>

                <ImpactConsole story={ impact_story } celebration_key={ celebration_key } />
            </section>

            <section className="workspace">
                <div className="operation_panel">
                    <ValueRail active_view={ active_view } />

                    <nav className="tabs" aria-label="Operation type">
                        <TabButton active_view={ active_view } view="swap" set_active_view={ set_active_view }>Swap</TabButton>
                        <TabButton active_view={ active_view } view="liquidity" set_active_view={ set_active_view }>Liquidity</TabButton>
                        <TabButton active_view={ active_view } view="donate" set_active_view={ set_active_view }>Donate</TabButton>
                        <TabButton active_view={ active_view } view="positions" set_active_view={ set_active_view }>Positions</TabButton>
                    </nav>

                    { active_view === "swap"      &&  <SwapForm form={ swap_form } set_form={ set_swap_form } /> }
                    { active_view === "liquidity" &&  <LiquidityForm form={ liquidity_form } set_form={ set_liquidity_form } /> }
                    { active_view === "donate"    &&  <DonateForm form={ donate_form } set_form={ set_donate_form } /> }
                    { active_view === "positions" && (
                        <PositionsTable rows={ position_rows } forget_position={ forget_position } refresh={ refresh_position_rows } />
                    )}

                    { active_view !== "positions" && (
                        <button className="primary_button full_width" disabled={ is_preparing } onClick={ prepare_active_operation }>
                            { is_preparing ? "Preparing..." : "Prepare operation" }
                        </button>
                    )}
                </div>

                <OperationReview
                    prepared_operation={ prepared_operation }
                    is_dispatching={ is_dispatching }
                    dispatch_prepared_operation={ dispatch_prepared_operation }
                    wallet={ wallet }
                    impact_story={ impact_story }
                />
            </section>

            { app_error !== null && <div className="notice error_notice">{ app_error }</div> }
            { status_message !== null && <div className="notice status_notice">{ status_message }</div> }
        </main>
    );
}

function SwapForm( props: { form: SwapFormState, set_form: ( form: SwapFormState ) => void } )
{
    const { form, set_form }  =  props;

    return (
        <div className="form_stack">
            <SegmentedControl
                value={ form.mode }
                options={[ [ "exact_input", "Exact input" ], [ "exact_output", "Exact output" ] ]}
                set_value={ ( value ) => set_form({ ...form, mode: value as SwapMode }) }
            />

            <TokenAmountField
                label="Sell"
                token={ form.input_token }
                amount={ form.mode === "exact_input" ? form.input_amount : form.input_maximum_amount }
                amount_label={ form.mode === "exact_input" ? "Exact amount" : "Maximum amount" }
                set_token={ ( value ) => set_form({ ...form, input_token: value }) }
                set_amount={ ( value ) => set_form( form.mode === "exact_input" ? { ...form, input_amount: value } : { ...form, input_maximum_amount: value }) }
            />
            <TokenAmountField
                label="Buy"
                token={ form.output_token }
                amount={ form.mode === "exact_input" ? form.output_minimum_amount : form.output_amount }
                amount_label={ form.mode === "exact_input" ? "Minimum amount" : "Exact amount" }
                set_token={ ( value ) => set_form({ ...form, output_token: value }) }
                set_amount={ ( value ) => set_form(
                    form.mode === "exact_input"  ?  { ...form, output_minimum_amount: value }  :  { ...form, output_amount: value }
                ) }
            />

            <PoolFields
                fee={ form.fee }
                tick_spacing={ form.tick_spacing }
                set_fee={ ( value ) => set_form({ ...form, fee: value }) }
                set_tick_spacing={ ( value ) => set_form({ ...form, tick_spacing: value }) }
            />
        </div>
    );
}

function LiquidityForm( props: { form: LiquidityFormState, set_form: ( form: LiquidityFormState ) => void } )
{
    const { form, set_form }  =  props;

    return (
        <div className="form_stack">
            <SegmentedControl
                value={ form.mode }
                options={[ [ "add", "Add" ], [ "remove", "Remove" ] ]}
                set_value={ ( value ) => set_form({ ...form, mode: value as LiquidityMode }) }
            />

            <PoolPairFields
                token_a={ form.token_a }
                token_b={ form.token_b }
                set_token_a={ ( value ) => set_form({ ...form, token_a: value }) }
                set_token_b={ ( value ) => set_form({ ...form, token_b: value }) }
            />

            { form.mode === "add" ? (
                <>
                    <div className="field_grid">
                        <TextField label="Token A amount" value={ form.amount_a } set_value={ ( value ) => set_form({ ...form, amount_a: value }) } />
                        <TextField label="Token B amount" value={ form.amount_b } set_value={ ( value ) => set_form({ ...form, amount_b: value }) } />
                    </div>
                    <div className="field_grid">
                        <TextField
                            label="Minimum A added"
                            value={ form.minimum_added_a }
                            placeholder={ slippage_placeholder() }
                            set_value={ ( value ) => set_form({ ...form, minimum_added_a: value }) }
                        />
                        <TextField
                            label="Minimum B added"
                            value={ form.minimum_added_b }
                            placeholder={ slippage_placeholder() }
                            set_value={ ( value ) => set_form({ ...form, minimum_added_b: value }) }
                        />
                    </div>
                </>
            ) : (
                <>
                    <TextField label="Liquidity amount" value={ form.liquidity } set_value={ ( value ) => set_form({ ...form, liquidity: value }) } />
                    <div className="field_grid">
                        <TextField
                            label="Minimum A received"
                            value={ form.minimum_received_a }
                            placeholder={ slippage_placeholder() }
                            set_value={ ( value ) => set_form({ ...form, minimum_received_a: value }) }
                        />
                        <TextField
                            label="Minimum B received"
                            value={ form.minimum_received_b }
                            placeholder={ slippage_placeholder() }
                            set_value={ ( value ) => set_form({ ...form, minimum_received_b: value }) }
                        />
                    </div>
                </>
            )}

            <TickFields form={ form } set_form={ set_form } />
            <PoolFields
                fee={ form.fee }
                tick_spacing={ form.tick_spacing }
                set_fee={ ( value ) => set_form({ ...form, fee: value }) }
                set_tick_spacing={ ( value ) => set_form({ ...form, tick_spacing: value }) }
            />
            <TextField
                label="Preferred stake token"
                value={ form.preferred_stake_token }
                placeholder="Optional pool token address"
                set_value={ ( value ) => set_form({ ...form, preferred_stake_token: value }) }
            />
        </div>
    );
}

function DonateForm( props: { form: DonateFormState, set_form: ( form: DonateFormState ) => void } )
{
    const { form, set_form }  =  props;

    return (
        <div className="form_stack">
            <PoolPairFields
                token_a={ form.token_a }
                token_b={ form.token_b }
                set_token_a={ ( value ) => set_form({ ...form, token_a: value }) }
                set_token_b={ ( value ) => set_form({ ...form, token_b: value }) }
            />
            <div className="field_grid">
                <TextField label="Token A amount" value={ form.amount_a } set_value={ ( value ) => set_form({ ...form, amount_a: value }) } />
                <TextField label="Token B amount" value={ form.amount_b } set_value={ ( value ) => set_form({ ...form, amount_b: value }) } />
            </div>
            <PoolFields
                fee={ form.fee }
                tick_spacing={ form.tick_spacing }
                set_fee={ ( value ) => set_form({ ...form, fee: value }) }
                set_tick_spacing={ ( value ) => set_form({ ...form, tick_spacing: value }) }
            />
            <TextField
                label="Preferred stake token"
                value={ form.preferred_stake_token }
                placeholder="Optional pool token address"
                set_value={ ( value ) => set_form({ ...form, preferred_stake_token: value }) }
            />
        </div>
    );
}

function LiveBackground()
{
    return (
        <div className="live_background" aria-hidden="true">
            <div className="field_line line_a"></div>
            <div className="field_line line_b"></div>
            <div className="field_line line_c"></div>
            <div className="value_orb orb_a"></div>
            <div className="value_orb orb_b"></div>
            <div className="ticker_stream">
                <span>sealed intent</span>
                <span>stake posted</span>
                <span>execution window</span>
                <span>spread retained</span>
                <span>LP fees protected</span>
            </div>
        </div>
    );
}

function ImpactConsole( props: { story: ImpactStory, celebration_key: number } )
{
    return (
        <div className="impact_console" key={ props.celebration_key }>
            <div className="impact_ring">
                <div className="impact_core">
                    <span>{ props.story.primary_label }</span>
                    <strong>{ props.story.primary_value }</strong>
                </div>
            </div>

            <div className="impact_metrics">
                <MetricTile label={ props.story.secondary_label } value={ props.story.secondary_value } />
                <MetricTile label={ props.story.proof_label } value={ props.story.proof_value } />
            </div>
        </div>
    );
}

function MetricTile( props: { label: string, value: string } )
{
    return (
        <div className="metric_tile">
            <span>{ props.label }</span>
            <strong>{ props.value }</strong>
        </div>
    );
}

function ValueRail( props: { active_view: AppView } )
{
    const events  =  value_events_for_view( props.active_view );

    return (
        <div className="value_rail">
            { events.map(( event, index ) => (
                <div className="value_step" style={{ animationDelay: `${ index * 180 }ms` }} key={ event.label }>
                    <span>{ event.label }</span>
                    <strong>{ event.value }</strong>
                </div>
            ))}
        </div>
    );
}

type OperationReviewProps = {
    prepared_operation:        PreparedOperationState | null;
    is_dispatching:            boolean;
    dispatch_prepared_operation: () => Promise<void>;
    wallet:                    WalletState;
    impact_story:              ImpactStory;
};

function OperationReview( props: OperationReviewProps )
{
    const { prepared_operation, is_dispatching, dispatch_prepared_operation, wallet, impact_story }  =  props;

    if(  prepared_operation === null  )
    {
        return (
            <aside className="review_panel empty_review">
                <h2>Review</h2>
                <p>
                    Prepare an operation to see the exact SafeSwap action, BondRoute stake, funded tokens, wallet requirements,
                    and execution window before signing.
                </p>
                <div className="empty_review_animation">
                    <span></span>
                    <span></span>
                    <span></span>
                </div>
            </aside>
        );
    }

    const operation  =  prepared_operation.operation;

    return (
        <aside className="review_panel">
            <div className="review_header">
                <div>
                    <p className="eyebrow">Prepared operation</p>
                    <h2>{ title_for_kind( operation.kind ) }</h2>
                </div>
                <span className="status_pill">{ operation.status }</span>
            </div>

            <p className="description_text">{ prepared_operation.description }</p>

            <div className="retained_value_card">
                <span>{ impact_story.primary_label }</span>
                <strong>{ impact_story.primary_value }</strong>
                <small>{ impact_story.secondary_label }: { impact_story.secondary_value }</small>
            </div>

            <DetailRows
                rows={[
                    [ "Commitment", operation.commitment_hash ],
                    [ "Create value", `${ operation.get_native_value_for_create().toString() } wei` ],
                    [ "Execute value", `${ operation.get_native_value_for_execute().toString() } wei` ],
                    [
                        "Execution delay",
                        operation.constraints === undefined ? "Quoted by BondRoute" : `${ operation.constraints.min_execution_delay_in_blocks } blocks`,
                    ],
                ]}
            />

            <TokenAmountList title="Fundings" items={ operation.execution_data.fundings } wallet={ wallet } />
            <TokenAmountList title="Stake" items={[ operation.execution_data.stake ]} wallet={ wallet } />

            <RequirementList
                title="Missing balances"
                empty_text="Wallet has the required balances."
                items={ prepared_operation.missing_balances.map(( item ) => `${ item.required - item.current } short ${ item.token }` ) }
            />
            <RequirementList
                title="Missing approvals"
                empty_text="No ERC20 approvals needed before dispatch."
                items={ prepared_operation.missing_approvals.map(( item ) => `${ item.token } approval for ${ item.spender }` ) }
            />

            <button className="primary_button full_width" disabled={ is_dispatching } onClick={ dispatch_prepared_operation }>
                { is_dispatching ? "Dispatching..." : "Dispatch operation" }
            </button>
        </aside>
    );
}

function PositionsTable( props: { rows: PositionRow[], forget_position: ( id: string ) => void, refresh: () => Promise<void> } )
{
    const { rows, forget_position, refresh }  =  props;

    return (
        <div className="positions_block">
            <div className="section_header">
                <div>
                    <h2>Your tracked positions</h2>
                    <p>SafeSwap reads position balances for ranges this browser has tracked.</p>
                </div>
                <button className="secondary_button" onClick={ () => void refresh() }>Refresh</button>
            </div>

            { rows.length === 0 ? (
                <div className="empty_table">Prepare an add or remove liquidity operation to track its pool range here.</div>
            ) : (
                <table>
                    <thead>
                        <tr>
                            <th>Pool</th>
                            <th>Fee</th>
                            <th>Range</th>
                            <th>Liquidity</th>
                            <th></th>
                        </tr>
                    </thead>
                    <tbody>
                        { rows.map(( row ) => (
                            <tr key={ row.id }>
                                <td>{ row.token_a_symbol } / { row.token_b_symbol }</td>
                                <td>{ row.fee }</td>
                                <td>{ row.tick_lower } → { row.tick_upper }</td>
                                <td>{ row.error ?? ( row.liquidity === null ? "Not loaded" : row.liquidity.toString() ) }</td>
                                <td><button className="text_button" onClick={ () => forget_position( row.id ) }>Forget</button></td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </div>
    );
}

function TokenAmountList( props: { title: string, items: Array<{ token: Address, amount: bigint }>, wallet: WalletState } )
{
    const [ rendered_items, set_rendered_items ]  =  useState<string[]>( [] );

    useEffect(() => {
        let is_cancelled  =  false;

        async function render_items()
        {
            if(  props.wallet.public_client === null  )
            {
                set_rendered_items( props.items.map(( item ) => `${ item.amount.toString() } ${ item.token }` ) );
                return;
            }

            const next_items  =  await Promise.all( props.items.map(( item ) => render_token_amount( props.wallet.public_client!, item.token, item.amount ) ) );
            if(  is_cancelled == false  )  set_rendered_items( next_items );
        }

        void render_items();
        return () => { is_cancelled = true; };
    }, [ props.items, props.wallet.public_client ]);

    return <RequirementList title={ props.title } empty_text="None" items={ rendered_items } />;
}

function RequirementList( props: { title: string, empty_text: string, items: string[] } )
{
    return (
        <section className="detail_section">
            <h3>{ props.title }</h3>
            { props.items.length === 0 ? <p className="muted_text">{ props.empty_text }</p> : (
                <ul>
                    { props.items.map(( item ) => <li key={ item }>{ item }</li> ) }
                </ul>
            )}
        </section>
    );
}

function DetailRows( props: { rows: Array<[ string, string ]> } )
{
    return (
        <dl className="detail_rows">
            { props.rows.map(( [ label, value ] ) => (
                <div key={ label }>
                    <dt>{ label }</dt>
                    <dd>{ value }</dd>
                </div>
            ))}
        </dl>
    );
}

function TabButton( props: { active_view: AppView, view: AppView, set_active_view: ( view: AppView ) => void, children: string } )
{
    return (
        <button className={ props.active_view === props.view ? "active" : "" } onClick={ () => props.set_active_view( props.view ) }>
            { props.children }
        </button>
    );
}

function SegmentedControl( props: { value: string, options: Array<[ string, string ]>, set_value: ( value: string ) => void } )
{
    return (
        <div className="segmented_control">
            { props.options.map(( [ value, label ] ) => (
                <button key={ value } className={ props.value === value ? "active" : "" } onClick={ () => props.set_value( value ) }>{ label }</button>
            ))}
        </div>
    );
}

type TokenAmountFieldProps = {
    label:        string;
    token:        string;
    amount:       string;
    amount_label: string;
    set_token:    ( value: string ) => void;
    set_amount:   ( value: string ) => void;
};

function TokenAmountField( props: TokenAmountFieldProps )
{
    return (
        <div className="token_amount_field">
            <TextField label={ `${ props.label } token` } value={ props.token } placeholder="0x..." set_value={ props.set_token } />
            <TextField label={ props.amount_label } value={ props.amount } placeholder="0.0" set_value={ props.set_amount } />
        </div>
    );
}

function PoolPairFields( props: { token_a: string, token_b: string, set_token_a: ( value: string ) => void, set_token_b: ( value: string ) => void } )
{
    return (
        <div className="field_grid">
            <TextField label="Token A" value={ props.token_a } placeholder="0x..." set_value={ props.set_token_a } />
            <TextField label="Token B" value={ props.token_b } placeholder="0x..." set_value={ props.set_token_b } />
        </div>
    );
}

function PoolFields( props: { fee: string, tick_spacing: string, set_fee: ( value: string ) => void, set_tick_spacing: ( value: string ) => void } )
{
    return (
        <div className="field_grid">
            <TextField label="Pool fee" value={ props.fee } set_value={ props.set_fee } />
            <TextField label="Tick spacing" value={ props.tick_spacing } set_value={ props.set_tick_spacing } />
        </div>
    );
}

function TickFields( props: { form: LiquidityFormState, set_form: ( form: LiquidityFormState ) => void } )
{
    return (
        <div className="field_grid">
            <TextField label="Tick lower" value={ props.form.tick_lower } set_value={ ( value ) => props.set_form({ ...props.form, tick_lower: value }) } />
            <TextField label="Tick upper" value={ props.form.tick_upper } set_value={ ( value ) => props.set_form({ ...props.form, tick_upper: value }) } />
        </div>
    );
}

function TextField( props: { label: string, value: string, placeholder?: string, set_value: ( value: string ) => void } )
{
    return (
        <label className="text_field">
            <span>{ props.label }</span>
            <input value={ props.value } placeholder={ props.placeholder } onChange={ ( event ) => props.set_value( event.target.value ) } />
        </label>
    );
}

function pool_info_from_form( fee: string, tick_spacing: string ): PoolInfo
{
    return { fee: number_from_form( "Fee", fee ), tick_spacing: number_from_form( "Tick spacing", tick_spacing ) };
}

function number_from_form( label: string, value: string ): number
{
    const parsed  =  Number( value );
    if(  Number.isFinite( parsed ) == false  )  throw new Error( `${ label } must be a number.` );
    if(  Number.isInteger( parsed ) == false  ) throw new Error( `${ label } must be an integer.` );
    return parsed;
}

function bigint_from_form( label: string, value: string ): bigint
{
    const trimmed_value  =  value.trim();
    if(  trimmed_value === ""  )  throw new Error( `${ label } is required.` );
    return BigInt( trimmed_value );
}

function optional_address( label: string, value: string ): Address | undefined
{
    if(  value.trim() === ""  )  return undefined;
    return require_address( label, value );
}

function fallback_to_zero( value: string ): string
{
    return value.trim() === ""  ?  "0"  :  value;
}

function require_public_client( wallet: WalletState )
{
    if(  wallet.public_client === null  )  throw new Error( "Connect a wallet first." );
    return wallet.public_client;
}

function title_for_kind( kind: string ): string
{
    if(  kind === "swap_exact_input"  )  return "Swap exact input";
    if(  kind === "swap_exact_output"  )  return "Swap exact output";
    if(  kind === "add_liquidity"  )     return "Add liquidity";
    if(  kind === "remove_liquidity"  )  return "Remove liquidity";
    if(  kind === "donate"  )            return "Donate";
    return "Operation";
}

function build_impact_story( params: {
    active_view: AppView;
    swap_form: SwapFormState;
    liquidity_form: LiquidityFormState;
    donate_form: DonateFormState;
    tracked_positions_count: number;
}): ImpactStory
{
    if(  params.active_view === "liquidity"  )  return liquidity_impact_story( params.liquidity_form, params.tracked_positions_count );
    if(  params.active_view === "donate"  )     return donate_impact_story( params.donate_form );
    if(  params.active_view === "positions"  )  return positions_impact_story( params.tracked_positions_count );
    return swap_impact_story( params.swap_form );
}

function swap_impact_story( form: SwapFormState ): ImpactStory
{
    const reference_amount  =  form.mode === "exact_input"  ?  form.output_minimum_amount  :  form.output_amount;
    const estimated_saved   =  estimate_percent_amount( reference_amount, estimated_mev_rate_for_fee( form.fee ) );

    return {
        headline:        "The quote becomes a defended outcome.",
        primary_label:   "Estimated extra kept",
        primary_value:   estimated_saved,
        secondary_label: "Unprotected MEV estimate",
        secondary_value: `${ format_percent( estimated_mev_rate_for_fee( form.fee ) ) } of output`,
        proof_label:     "User asks",
        proof_value:     reference_amount.trim() === ""  ?  "Enter output target"  :  reference_amount,
    };
}

function liquidity_impact_story( form: LiquidityFormState, tracked_positions_count: number ): ImpactStory
{
    const amount_a       =  form.mode === "add"  ?  form.amount_a  :  form.minimum_received_a;
    const amount_b       =  form.mode === "add"  ?  form.amount_b  :  form.minimum_received_b;
    const estimated_fee  =  estimate_percent_amount( first_non_empty( amount_a, amount_b ), fee_rate_to_percent( form.fee ) );

    return {
        headline:        form.mode === "add"  ?  "Turn idle tokens into a fee stream."  :  "Exit the range without leaking value.",
        primary_label:   form.mode === "add"  ?  "Fee engine armed"  :  "Withdrawal shielded",
        primary_value:   estimated_fee,
        secondary_label: "Tracked LP ranges",
        secondary_value: String( tracked_positions_count ),
        proof_label:     "Range",
        proof_value:     `${ form.tick_lower } to ${ form.tick_upper }`,
    };
}

function donate_impact_story( form: DonateFormState ): ImpactStory
{
    const donated_value  =  first_non_empty( form.amount_a, form.amount_b );

    return {
        headline:        "Push yield directly to active LPs.",
        primary_label:   "Donation routed",
        primary_value:   donated_value === ""  ?  "Enter amount"  :  donated_value,
        secondary_label: "LP side effect",
        secondary_value: "More fees in range",
        proof_label:     "Pool fee",
        proof_value:     `${ form.fee }`,
    };
}

function positions_impact_story( tracked_positions_count: number ): ImpactStory
{
    return {
        headline:        "Your earning ranges stay visible.",
        primary_label:   "Tracked positions",
        primary_value:   String( tracked_positions_count ),
        secondary_label: "On-chain reads",
        secondary_value: "Live liquidity",
        proof_label:     "Action",
        proof_value:     "Refresh table",
    };
}

function value_events_for_view( active_view: AppView ): MomentumEvent[]
{
    if(  active_view === "liquidity"  )
    {
        return [
            { label: "Capital", value: "Deposited" },
            { label: "Range", value: "Tracked" },
            { label: "Fees", value: "Accruing" },
        ];
    }

    if(  active_view === "donate"  )
    {
        return [
            { label: "Tokens", value: "Donated" },
            { label: "LPs", value: "Rewarded" },
            { label: "Pool", value: "Strengthened" },
        ];
    }

    if(  active_view === "positions"  )
    {
        return [
            { label: "Ranges", value: "Stored" },
            { label: "Liquidity", value: "Read" },
            { label: "Fees", value: "Visible" },
        ];
    }

    return [
        { label: "Intent", value: "Hidden" },
        { label: "Stake", value: "Posted" },
        { label: "Spread", value: "Kept" },
    ];
}

function estimated_mev_rate_for_fee( fee: string ): number
{
    const fee_number  =  Number( fee );
    if(  Number.isFinite( fee_number ) == false  )  return 0.005;
    if(  fee_number <= 100  )   return 0.0025;
    if(  fee_number <= 500  )   return 0.0060;
    if(  fee_number <= 3000  )  return 0.0120;
    return 0.0250;
}

function fee_rate_to_percent( fee: string ): number
{
    const fee_number  =  Number( fee );
    if(  Number.isFinite( fee_number ) == false  )  return 0;
    return fee_number / 1_000_000;
}

function estimate_percent_amount( amount: string, percent: number ): string
{
    const amount_number  =  Number( amount );
    if(  amount.trim() === ""  ||  Number.isFinite( amount_number ) == false  )  return "Waiting for amount";

    const estimated  =  amount_number * percent;
    if(  estimated === 0  )  return "0";
    if(  estimated < 0.000001  )  return "<0.000001";
    return trim_decimal( estimated.toFixed( 6 ) );
}

function format_percent( percent: number ): string
{
    return `${ trim_decimal( ( percent * 100 ).toFixed( 2 ) ) }%`;
}

function first_non_empty( first: string, second: string ): string
{
    if(  first.trim() !== ""  )  return first;
    return second;
}

function trim_decimal( value: string ): string
{
    return value.replace( /0+$/, "" ).replace( /\.$/, "" );
}

function slippage_placeholder(): string
{
    return `Optional, default 0 (${ DEFAULT_SLIPPAGE_PERCENT }% UI hint)`;
}

function throw_ui_error( message: string ): never
{
    throw new Error( message );
}

function error_message( error: unknown ): string
{
    return error instanceof Error  ?  error.message  :  String( error );
}

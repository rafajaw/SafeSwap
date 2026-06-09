import { useState } from "react";
import { SafeSwapProvider, useSafeSwap } from "./context/safeswap_context";
import { Notice, Spinner, Wordmark } from "./components/ui";
import { short_address } from "./lib/format";
import { SwapScreen } from "./screens/swap";
import { EarnScreen } from "./screens/earn";
import { PortfolioScreen } from "./screens/portfolio";

type View  =  "swap" | "earn" | "portfolio";

export function App()
{
    return (
        <SafeSwapProvider>
            <Shell />
        </SafeSwapProvider>
    );
}

function Shell()
{
    const { status, wallet }  =  useSafeSwap();
    const [ view, set_view ]  =  useState<View>( "swap" );

    if(  status !== "connected" || wallet === null  )  return <ConnectGate />;

    return (
        <div className="shell">
            <header className="topbar">
                <Wordmark />
                <nav className="nav">
                    <button className={ view === "swap" ? "active" : "" } onClick={ () => set_view( "swap" ) }>Swap</button>
                    <button className={ view === "earn" ? "active" : "" } onClick={ () => set_view( "earn" ) }>Earn</button>
                    <button className={ view === "portfolio" ? "active" : "" } onClick={ () => set_view( "portfolio" ) }>Portfolio</button>
                </nav>
                <span className="wallet-chip"><span className="dot" />{ short_address( wallet.address ) } · chain { wallet.chain_id }</span>
            </header>

            <main>
                { view === "swap"      && <SwapScreen /> }
                { view === "earn"      && <EarnScreen /> }
                { view === "portfolio" && <PortfolioScreen /> }
            </main>
        </div>
    );
}

/** Wallet connection is the entry gate — on load we immediately fire the connect prompt; only static brand exists pre-connect. */
function ConnectGate()
{
    const { status, error, connect }  =  useSafeSwap();

    return (
        <div className="scrim">
            <div className="card modal center">
                <div style={ { marginBottom: 18 } }><Wordmark /></div>

                { status === "connecting" && (
                    <>
                        <p className="card-title">Connecting wallet…</p>
                        <p className="card-sub">Approve the connection in your wallet to continue.</p>
                        <Spinner />
                    </>
                ) }

                { status === "no_wallet" && (
                    <>
                        <p className="card-title">Connect your wallet</p>
                        <p className="card-sub">Connect your wallet to swap protected or manage liquidity. No injected wallet was found — install or unlock one.</p>
                        <button className="btn btn-primary btn-block" onClick={ () => void connect() }>Try again</button>
                    </>
                ) }

                { ( status === "idle" || status === "error" ) && (
                    <>
                        <p className="card-title">Keep more when you trade.</p>
                        <p className="card-sub">MEV-protected pools. Repricing revenue for LPs.</p>
                        { error !== null && <div style={ { margin: "12px 0" } }><Notice tone="err">{ error }</Notice></div> }
                        <button className="btn btn-primary btn-block" onClick={ () => void connect() }>Connect wallet</button>
                    </>
                ) }
            </div>
        </div>
    );
}

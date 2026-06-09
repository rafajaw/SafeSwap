import { createPublicClient, createWalletClient, custom, type Address, type Chain, type EIP1193Provider, type PublicClient, type WalletClient } from "viem";
import * as chains from "viem/chains";

declare global {
    interface Window {
        ethereum?: EIP1193Provider;
    }
}

export type WalletConnection = {
    address:       Address;
    chain_id:      number;
    public_client: PublicClient;
    wallet_client: WalletClient;
};

export function has_wallet_provider(): boolean
{
    return typeof window !== "undefined" && window.ethereum !== undefined;
}

/** Connect the injected wallet. Every meaningful screen is chain-dependent, so this is the app's entry gate. */
export async function connect_wallet(): Promise<WalletConnection>
{
    if(  window.ethereum === undefined  )  throw new Error( "No injected wallet found. Install or unlock a wallet." );

    const provider  =  window.ethereum;
    const accounts  =  await provider.request({ method: "eth_requestAccounts" }) as Address[];
    const account   =  accounts[0];
    if(  account === undefined  )  throw new Error( "Wallet did not return an account." );

    const chain_id  =  Number( await provider.request({ method: "eth_chainId" }) );
    const chain     =  ( Object.values( chains ) as Chain[] ).find(( candidate ) => candidate.id === chain_id );

    const public_client  =  createPublicClient({ chain, transport: custom( provider ) });
    const wallet_client  =  createWalletClient({ account, chain, transport: custom( provider ) });

    return { address: account, chain_id, public_client, wallet_client };
}

// NOTE: there is no standard way to detect whether an injected wallet supports EIP-7702 authorization signing — viem's
// WalletClient always exposes `signAuthorization`, so any capability check gives a false positive. We use a try/catch model
// instead: Gasless is always offered, and if the wallet rejects the authorization at sign time the relay surfaces that error
// so the user can fall back to Self-execute.

export function on_accounts_or_chain_change( handler: () => void ): () => void
{
    if(  window.ethereum === undefined  )  return () => {};

    const provider  =  window.ethereum as EIP1193Provider & { on?: ( event: string, fn: () => void ) => void, removeListener?: ( event: string, fn: () => void ) => void };
    provider.on?.( "accountsChanged", handler );
    provider.on?.( "chainChanged", handler );
    return () => {
        provider.removeListener?.( "accountsChanged", handler );
        provider.removeListener?.( "chainChanged", handler );
    };
}

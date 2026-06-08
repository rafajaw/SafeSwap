import { createPublicClient, createWalletClient, custom, type Address, type Chain, type EIP1193Provider } from "viem";
import * as chains from "viem/chains";
import type { WalletState } from "./types";

declare global {
    interface Window {
        ethereum?: EIP1193Provider;
    }
}

export function has_wallet_provider(): boolean
{
    return window.ethereum !== undefined;
}

export async function connect_wallet(): Promise<WalletState>
{
    if(  window.ethereum === undefined  )  throw new Error( "No injected wallet found." );

    const provider       =  window.ethereum;
    const accounts       =  await provider.request({ method: "eth_requestAccounts" }) as Address[];
    const account        =  accounts[0];
    if(  account === undefined  )  throw new Error( "Wallet did not return an account." );

    // Resolve the connected chain so the clients carry `chain.nativeCurrency` (the standard source for the native gas token's
    // symbol / decimals). An unknown chain leaves `chain` undefined; the SDK then falls back to ETH/18.
    const chain_id       =  Number( await provider.request({ method: "eth_chainId" }) );
    const chain          =  ( Object.values( chains ) as Chain[] ).find(( candidate ) => candidate.id === chain_id );

    const public_client  =  createPublicClient({ chain, transport: custom( provider ) });
    const wallet_client  =  createWalletClient({ account, chain, transport: custom( provider ) });

    return { address: account, chain_id, public_client, wallet_client };
}

export function short_address( address: Address ): string
{
    return `${ address.slice( 0, 6 ) }...${ address.slice( -4 ) }`;
}

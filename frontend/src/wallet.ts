import { createPublicClient, createWalletClient, custom, type Address, type EIP1193Provider } from "viem";
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

    const public_client  =  createPublicClient({ transport: custom( provider ) });
    const wallet_client  =  createWalletClient({ account, transport: custom( provider ) });
    const chain_id       =  await public_client.getChainId();

    return { address: account, chain_id, public_client, wallet_client };
}

export function short_address( address: Address ): string
{
    return `${ address.slice( 0, 6 ) }...${ address.slice( -4 ) }`;
}

// SPDX-License-Identifier: MIT
//
// SafeSwap single backend: serves the built frontend (`STATIC_DIR`) and exposes `POST /relay`, the gasless EIP-7702 relayer.
// One server, one secret (the relayer key). Phase-2 indexing/caching is separate and not part of this process.

import { contentType } from "jsr:@std/media-types@^1.0.0";
import { extname, join, normalize } from "jsr:@std/path@^1.0.0";
import { Relayer, RelayRejected } from "./relayer.ts";
import type { RelayRequest } from "@safeswap/sdk";

const relayer  =  await Relayer.init();
const config   =  relayer.config;

console.log( `SafeSwap relayer ready on chain ${ config.chain_id }; serving ${ config.static_dir } on :${ config.port }.` );

// Finish any bonds a previous run committed but did not execute, so a crash never strands the user's locked stake. Runs in
// the background so serving starts immediately.
relayer.resume_pending().catch(( error ) => console.error( "SafeSwap relayer resume pass failed:", error ) );

Deno.serve({ port: config.port }, async ( request ) => {
    const url  =  new URL( request.url );

    if(  request.method === "OPTIONS"  )  return cors( new Response( null, { status: 204 } ) );
    if(  url.pathname === "/relay"  )     return cors( await handle_relay( request ) );

    return await serve_static( url.pathname );
});


async function handle_relay( request: Request ): Promise<Response>
{
    if(  request.method !== "POST"  )  return json({ error: "Use POST." }, 405);

    let relay_request: RelayRequest;
    try
    {
        relay_request  =  await request.json() as RelayRequest;
    }
    catch
    {
        return json({ error: "Request body must be JSON." }, 400);
    }

    try
    {
        return json( await relayer.relay( relay_request ) );
    }
    catch( cause )
    {
        if(  cause instanceof RelayRejected  )  return json({ error: cause.message }, 400);

        console.error( "Relay failed:", cause );
        return json({ error: cause instanceof Error ? cause.message : "Internal relayer error." }, 500);
    }
}


// ━━━━  STATIC FILE SERVING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function serve_static( pathname: string ): Promise<Response>
{
    const relative  =  pathname === "/"  ?  "index.html"  :  normalize( pathname ).replace( /^(\.\.[/\\])+/, "" ).replace( /^[/\\]+/, "" );
    const file_path =  join( config.static_dir, relative );

    const served  =  await try_serve_file( file_path );
    if(  served !== null  )  return served;

    // SPA fallback: unknown non-asset routes resolve to index.html so client-side navigation works on reload.
    const index  =  await try_serve_file( join( config.static_dir, "index.html" ) );
    if(  index !== null  )  return index;

    return new Response( "Not found.", { status: 404 } );
}

async function try_serve_file( file_path: string ): Promise<Response | null>
{
    try
    {
        const data  =  await Deno.readFile( file_path );
        const type  =  contentType( extname( file_path ) ) ?? "application/octet-stream";
        return new Response( data, { headers: { "content-type": type } } );
    }
    catch
    {
        return null;
    }
}


// ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function json( body: unknown, status: number = 200 ): Response
{
    return new Response( JSON.stringify( body ), { status, headers: { "content-type": "application/json" } } );
}

/** Permissive CORS so the Vite dev server (a different origin) can reach `/relay`; in production the app is same-origin. */
function cors( response: Response ): Response
{
    response.headers.set( "access-control-allow-origin", "*" );
    response.headers.set( "access-control-allow-methods", "POST, OPTIONS" );
    response.headers.set( "access-control-allow-headers", "content-type" );
    return response;
}

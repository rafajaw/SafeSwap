import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath, URL } from "node:url";

export default defineConfig({
    plugins: [ react() ],
    build: {
        rollupOptions: {
            output: {
                manualChunks: {
                    react: [ "react", "react-dom" ],
                    viem:  [ "viem" ],
                },
            },
        },
    },
    resolve: {
        alias: {
            "@safeswap/sdk/source": fileURLToPath( new URL( "../sdk/SafeSwap.ts", import.meta.url ) ),
            "@bondroute/sdk":       fileURLToPath( new URL( "../lib/BondRoute/sdk/BondRoute.ts", import.meta.url ) ),
            "viem":                 fileURLToPath( new URL( "./node_modules/viem", import.meta.url ) ),
        },
    },
});

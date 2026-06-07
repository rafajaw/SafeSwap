import type { SafeSwapSigningPreview } from "@safeswap/sdk/source";

export type SigningPreviewRow = {
    label: string;
    value: string;
};

export function signing_preview_rows( preview: SafeSwapSigningPreview ): SigningPreviewRow[]
{
    return preview.fields.map(( field ) => ({ label: field.name, value: field.value }));
}

export function signing_preview_snapshot( preview: SafeSwapSigningPreview ): string
{
    return [
        `${ preview.action_type } (${ preview.action_field })`,
        ...signing_preview_rows( preview ).map(( row ) => `${ row.label }: ${ row.value }`),
    ].join( "\n" );
}

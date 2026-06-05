// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;


/**
 * @title HookAddress
 * @notice Encoding and decoding of a SafeSwap config-hook address. Every SafeSwap pool's hook is a tiny delegatecall clone
 *         of one audited implementation whose CREATE2 address carries the pool economics as readable binary-coded decimal:
 *
 *             0x F d2 d1 d0 C r .......................... PPPP
 *                │ └──┬───┘ │ │                            └─ low 14 bits: Uniswap V4 hook permission bitmap
 *                │    │     │ └─ rebate digit r        → capture percent = r × 10        (0..90, in 10% steps)
 *                │    │     └─── capture marker (0xC)
 *                │    └───────── 3 base-fee digits     → base fee bps = 100·d2 + 10·d1 + d0   (0..999 → 0.00%..9.99%)
 *                └────────────── fee marker (0xF), also marks the address as a SafeSwap config hook
 *
 *         Example: 0xF030C5… → base fee 0.3%, capture 50%. The markers 0xF and 0xC are both greater than 9, so they can
 *         never be confused with a 0..9 data digit. Base fee is open (any value the digits express); capture is 10%-quantized.
 */
library HookAddress {

    error InvalidHookConfig( address hook );

    uint8   internal constant FEE_MARKER         =   0xF;   // Leading nibble: "Fee" — base-fee digits follow; marks a SafeSwap hook.
    uint8   internal constant CAPTURE_MARKER     =   0xC;   // Separator nibble: "Capture" — the rebate digit follows.
    uint8   internal constant MAX_DECIMAL_DIGIT  =   9;
    uint160 internal constant NIBBLE_MASK        =   0xF;

    uint256 internal constant FEE_MARKER_SHIFT      =   156;
    uint256 internal constant BASE_FEE_D2_SHIFT     =   152;
    uint256 internal constant BASE_FEE_D1_SHIFT     =   148;
    uint256 internal constant BASE_FEE_D0_SHIFT     =   144;
    uint256 internal constant CAPTURE_MARKER_SHIFT  =   140;
    uint256 internal constant REBATE_SHIFT          =   136;

    uint160 internal constant PERMISSIONS_MASK      =   0x3FFF;     // (1 << 14) - 1, matches Hooks.ALL_HOOK_MASK.

    // beforeInitialize | beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap
    //   = (1<<13) | (1<<11) | (1<<9) | (1<<7)
    // (beforeDonate is intentionally NOT required: SafeSwap exposes no bonded donate, and a pool accepting permissionless
    //  donations to its in-range LPs is harmless — it cannot move price or extract value.)
    uint160 internal constant REQUIRED_PERMISSIONS  =   0x2A80;

    /**
     * @notice Decode the base fee (in basis points) and the LP capture share (in percent) from a config-hook address.
     * @dev Reverts if the address does not carry the `0xF` fee marker and `0xC` capture marker, or if any base/rebate nibble
     *      is not a decimal digit (greater than 9).
     */
    function decode( address hook ) internal pure returns ( uint16 base_fee_bps, uint8 rebate_percent )
    {
        uint160 bits  =  uint160(hook);

        uint8 fee_marker      =  uint8( (bits >> FEE_MARKER_SHIFT)     & NIBBLE_MASK );
        uint8 capture_marker  =  uint8( (bits >> CAPTURE_MARKER_SHIFT) & NIBBLE_MASK );
        if(  fee_marker != FEE_MARKER  ||  capture_marker != CAPTURE_MARKER  )  revert InvalidHookConfig( hook );

        uint8 base_fee_hundreds  =  uint8( (bits >> BASE_FEE_D2_SHIFT) & NIBBLE_MASK );
        uint8 base_fee_tens      =  uint8( (bits >> BASE_FEE_D1_SHIFT) & NIBBLE_MASK );
        uint8 base_fee_ones      =  uint8( (bits >> BASE_FEE_D0_SHIFT) & NIBBLE_MASK );
        uint8 rebate_digit       =  uint8( (bits >> REBATE_SHIFT)      & NIBBLE_MASK );

        bool any_digit_invalid  =  base_fee_hundreds > MAX_DECIMAL_DIGIT
                                   ||  base_fee_tens > MAX_DECIMAL_DIGIT
                                   ||  base_fee_ones > MAX_DECIMAL_DIGIT
                                   ||  rebate_digit > MAX_DECIMAL_DIGIT;
        if(  any_digit_invalid  )  revert InvalidHookConfig( hook );

        base_fee_bps    =  uint16(base_fee_hundreds) * 100  +  uint16(base_fee_tens) * 10  +  uint16(base_fee_ones);
        rebate_percent  =  rebate_digit * 10;
    }

    /**
     * @notice Whether `hook`'s low 14 bits carry exactly the Uniswap V4 permission bitmap a SafeSwap hook requires.
     */
    function has_required_permissions( address hook ) internal pure returns ( bool )
    {
        return ( uint160(hook) & PERMISSIONS_MASK ) == REQUIRED_PERMISSIONS;
    }
}

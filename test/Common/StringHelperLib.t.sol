// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, stdError } from "forge-std/Test.sol";
import { IStringHelperLibTests } from "@test/Common/TestManifest.sol";
import { StringHelperLib } from "@SafeSwapCommon/StringHelperLib.sol";


contract StringHelperLibTest is IStringHelperLibTests, Test {

    // ━━━━  UTC datetime stamp  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_epoch_zero( ) external pure
    {
        assertEq( StringHelperLib.format_utc_datetime( 0 ), "1970-01-01 00:00 UTC" );
    }

    function test_one_day( ) external pure
    {
        assertEq( StringHelperLib.format_utc_datetime( 86400 ), "1970-01-02 00:00 UTC" );
    }

    function test_leap_year_date( ) external pure
    {
        // 1717545600 = 2024-06-05 00:00:00 UTC (past Feb-29 in a leap year)
        assertEq( StringHelperLib.format_utc_datetime( 1717545600 ), "2024-06-05 00:00 UTC" );
    }

    function test_time_of_day( ) external pure
    {
        // 1700000000 = 2023-11-14 22:13:20 UTC
        assertEq( StringHelperLib.format_utc_datetime( 1700000000 ), "2023-11-14 22:13 UTC" );
    }

    function test_zero_padding( ) external pure
    {
        // 1704067200 = 2024-01-01 00:00:00 UTC -> single-digit month/day/hour/minute all padded
        assertEq( StringHelperLib.format_utc_datetime( 1704067200 ), "2024-01-01 00:00 UTC" );
    }

    // ━━━━  Basis point percent formatting  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_format_bps_as_percent_trims_insignificant_zeroes( ) external pure
    {
        assertEq( StringHelperLib.format_bps_as_percent( 5 ), "0.05", "five bps should keep the leading fractional zero." );
        assertEq( StringHelperLib.format_bps_as_percent( 30 ), "0.3", "thirty bps should not render cosmetic precision." );
        assertEq( StringHelperLib.format_bps_as_percent( 100 ), "1", "one hundred bps should render as one percent." );
        assertEq( StringHelperLib.format_bps_as_percent( 125 ), "1.25", "one hundred twenty five bps should keep meaningful decimals." );
    }

    function test_format_bps_as_percent_string_trims_insignificant_zeroes( ) external pure
    {
        assertEq( StringHelperLib.format_bps_as_percent_string( 5 ), "0.05%", "five bps should keep the leading fractional zero." );
        assertEq( StringHelperLib.format_bps_as_percent_string( 30 ), "0.3%", "thirty bps should not render cosmetic precision." );
        assertEq( StringHelperLib.format_bps_as_percent_string( 100 ), "1%", "one hundred bps should render as one percent." );
        assertEq( StringHelperLib.format_bps_as_percent_string( 125 ), "1.25%", "one hundred twenty five bps should keep meaningful decimals." );
    }

    // ━━━━  Token amount formatting  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //
    // The cosmetic card caps fractional digits for readability; signed display strings must instead render at
    // FULL_PRECISION so that two distinct raw amounts can never share a string (a canonical commitment). These
    // tests pin both modes side by side, because the gap between them is the security-critical property.

    uint8 internal constant CARD_CAP  =  4;

    function test_format_token_amount_handles_zero_and_zero_decimal_tokens( ) external pure
    {
        assertEq( StringHelperLib.format_token_amount( 0, 18, CARD_CAP ), "0", "zero amount renders as 0 under a cap." );
        assertEq( StringHelperLib.format_token_amount( 0, 18, StringHelperLib.FULL_PRECISION ), "0", "zero amount renders as 0 at full precision." );

        // A zero-decimal token has no fractional part, so the cap is irrelevant and the integer prints verbatim.
        assertEq( StringHelperLib.format_token_amount( 12345, 0, CARD_CAP ), "12345", "zero-decimal token prints the integer." );
        assertEq( StringHelperLib.format_token_amount( 12345, 0, StringHelperLib.FULL_PRECISION ), "12345", "zero-decimal token is unaffected by full precision." );
    }

    function test_format_token_amount_caps_fraction_at_max_decimals( ) external pure
    {
        // 18-decimal value with more precision than the cap: keep exactly the first `max_decimals` digits.
        assertEq( StringHelperLib.format_token_amount( 1_234567890000000000, 18, CARD_CAP ), "1.2345", "cap keeps the first four fractional digits." );
        // Trailing zeros inside the cap window are trimmed.
        assertEq( StringHelperLib.format_token_amount( 1_500000000000000000, 18, CARD_CAP ), "1.5", "trailing zeros are trimmed under the cap." );
        // A cap wider than the token's own decimals is harmless (clamped down to `decimals`).
        assertEq( StringHelperLib.format_token_amount( 1_500000, 6, CARD_CAP ), "1.5", "USDC-style six-decimal value caps cleanly." );
    }

    function test_format_token_amount_full_precision_is_lossless( ) external pure
    {
        // Every fractional digit survives at full precision, with only trailing zeros trimmed.
        assertEq( StringHelperLib.format_token_amount( 1_500000000000000000, 18, StringHelperLib.FULL_PRECISION ), "1.5", "full precision trims only trailing zeros." );
        assertEq( StringHelperLib.format_token_amount( 1_234567890123456789, 18, StringHelperLib.FULL_PRECISION ), "1.234567890123456789", "full precision keeps all eighteen digits." );
        assertEq( StringHelperLib.format_token_amount( 123456_000001, 6, StringHelperLib.FULL_PRECISION ), "123,456.000001", "full precision keeps a tiny tail on a grouped whole part." );
    }

    function test_format_token_amount_full_precision_distinguishes_sub_cap_amounts( ) external pure
    {
        // THE security property: two amounts differing only below the display cap.
        uint256 a  =  1e18 + 1;
        uint256 b  =  1e18 + 2;

        // Under the cosmetic cap both collapse to the same string — proof the cap must never anchor a signature.
        assertEq( StringHelperLib.format_token_amount( a, 18, CARD_CAP ), "1", "capped display drops sub-cap precision (a)." );
        assertEq( StringHelperLib.format_token_amount( b, 18, CARD_CAP ), "1", "capped display drops sub-cap precision (b)." );

        // At full precision they are distinct and exact — the canonical-commitment guarantee.
        assertEq( StringHelperLib.format_token_amount( a, 18, StringHelperLib.FULL_PRECISION ), "1.000000000000000001", "full precision pins amount a exactly." );
        assertEq( StringHelperLib.format_token_amount( b, 18, StringHelperLib.FULL_PRECISION ), "1.000000000000000002", "full precision pins amount b exactly." );
        assertTrue(
            keccak256( bytes( StringHelperLib.format_token_amount( a, 18, StringHelperLib.FULL_PRECISION ) ) )
                != keccak256( bytes( StringHelperLib.format_token_amount( b, 18, StringHelperLib.FULL_PRECISION ) ) ),
            "distinct amounts must hash to distinct full-precision strings."
        );
    }

    function test_format_token_amount_full_precision_renders_exact_sub_unit( ) external pure
    {
        // A sub-unit amount under the cap degrades to the lossy floor marker; full precision shows it exactly.
        assertEq( StringHelperLib.format_token_amount( 1, 18, CARD_CAP ), "<0.0001", "capped sub-unit shows the floor marker." );
        assertEq( StringHelperLib.format_token_amount( 1, 18, StringHelperLib.FULL_PRECISION ), "0.000000000000000001", "full precision shows one wei exactly." );
    }

    function test_format_token_amount_groups_thousands( ) external pure
    {
        assertEq( StringHelperLib.format_token_amount( 12450000 * 1e18, 18, StringHelperLib.FULL_PRECISION ), "12,450,000", "whole part is thousands-grouped." );
        assertEq( StringHelperLib.format_token_amount( 8900000000 * 1e6, 6, CARD_CAP ), "8,900,000,000", "grouping is independent of the fractional cap." );
    }

    function test_format_token_amount_zero_max_decimals_renders_integer_only( ) external pure
    {
        // 0 means "I don't care about fractional digits": render only the (floored) integer part.
        assertEq( StringHelperLib.format_token_amount( 1234_567890000000000000, 18, 0 ), "1,234", "zero cap renders the whole part only." );
        assertEq( StringHelperLib.format_token_amount( 1_999999999999999999, 18, 0 ), "1", "zero cap floors to the integer part." );
        // A sub-unit nonzero amount must not read as the integer 0 (that would look like nothing) -> floor marker.
        assertEq( StringHelperLib.format_token_amount( 1, 18, 0 ), "<1", "zero cap marks a sub-unit nonzero amount as <1." );
    }

    function test_format_token_amount_reverts_on_unsupported_decimals( ) external
    {
        // 78+ decimals overflow 10^decimals in uint256; no real token reaches this, so it is an assert invariant.
        vm.expectRevert( stdError.assertionError );
        this.call_format_token_amount( 1, 78, StringHelperLib.FULL_PRECISION );
    }

    function test_format_symbol_amount_appends_symbol( ) external pure
    {
        assertEq( StringHelperLib.format_symbol_amount( 1_250000000000000000, 18, CARD_CAP, "WETH" ), "1.25 WETH", "symbol form caps then appends the symbol." );
        assertEq( StringHelperLib.format_symbol_amount( 1e18 + 1, 18, StringHelperLib.FULL_PRECISION, "WETH" ), "1.000000000000000001 WETH", "symbol form preserves full precision." );
    }

    // External wrapper so `vm.expectRevert` observes a real call frame for the inlined internal library function.
    function call_format_token_amount( uint256 amount, uint8 decimals, uint8 max_decimals ) external pure returns ( string memory )
    {
        return StringHelperLib.format_token_amount( amount, decimals, max_decimals );
    }
}

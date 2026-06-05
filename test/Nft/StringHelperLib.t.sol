// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { StringHelperLib } from "@SafeSwapNft/libraries/StringHelperLib.sol";


contract StringHelperLibTest is Test {

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
}

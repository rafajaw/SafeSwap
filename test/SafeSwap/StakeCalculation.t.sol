// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract StakeCalculationTest is SafeSwapTestBase {

    // ━━━━  Swap Stake  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_swap_stake_token_is_input_token( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_swap_stake( token0, 100 ether );

        assertEq(
            address(stake.token),
            address(token0),
            "Swap stake token should be the input token."
        );
    }

    function test_swap_stake_is_1_percent( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_swap_stake( token0, 100 ether );

        assertEq(
            stake.amount,
            1 ether,
            "Swap stake should be 1% of value."
        );
    }

    function test_swap_stake_rounds_down( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_swap_stake( token0, 99 );

        assertEq(
            stake.amount,
            0,
            "Swap stake should round down for small amounts."
        );
    }

    function test_swap_stake_zero_input( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_swap_stake( token0, 0 );

        assertEq(
            stake.amount,
            0,
            "Swap stake should be 0 when input is 0."
        );
    }


    // ━━━━  Liquidity Stake  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_liquidity_stake_is_1_percent( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_liquidity_stake( token0, 100 ether );

        assertEq(
            stake.amount,
            1 ether,
            "Liquidity stake should be 1% of normalized value."
        );
    }

    function test_liquidity_stake_matches_swap_stake_rate( ) external view
    {
        TokenAmount memory swap_stake       =  hook.harness_calculate_swap_stake( token0, 100 ether );
        TokenAmount memory liquidity_stake  =  hook.harness_calculate_liquidity_stake( token0, 100 ether );

        assertEq(
            liquidity_stake.amount,
            swap_stake.amount,
            "Liquidity stake should use the same percentage rate as swaps."
        );
    }

    function test_liquidity_stake_token_is_token0( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_liquidity_stake( token0, 100 ether );

        assertEq(
            address(stake.token),
            address(token0),
            "Liquidity stake token should be token0."
        );
    }

    function test_liquidity_stake_large_value( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_liquidity_stake( token0, 1_000_000 ether );

        assertEq(
            stake.amount,
            10_000 ether,
            "Liquidity stake should be 1% of large value."
        );
    }
}

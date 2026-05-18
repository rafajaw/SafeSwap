// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";


contract StakeCalculationTest is SafeSwapTestBase {

    // ━━━━  Swap Stake  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_swap_stake_token_is_input_token( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_swap_stake( TokenAmount({ token: token0, amount: 100 ether }) );

        assertEq(
            address(stake.token),
            address(token0),
            "Swap stake token should be the input token."
        );
    }

    function test_swap_stake_is_1_percent( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_swap_stake( TokenAmount({ token: token0, amount: 100 ether }) );

        assertEq(
            stake.amount,
            1 ether,
            "Swap stake should be 1% of value."
        );
    }

    function test_swap_stake_rounds_down( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_swap_stake( TokenAmount({ token: token0, amount: 99 }) );

        assertEq(
            stake.amount,
            0,
            "Swap stake should round down for small amounts."
        );
    }

    function test_swap_stake_zero_input( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_swap_stake( TokenAmount({ token: token0, amount: 0 }) );

        assertEq(
            stake.amount,
            0,
            "Swap stake should be 0 when input is 0."
        );
    }
}

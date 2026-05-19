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

    function test_swap_stake_bumps_dust_to_one_wei( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_swap_stake( TokenAmount({ token: token0, amount: 99 }) );

        assertEq(
            stake.amount,
            1,
            "Sub-100-wei swaps bump to 1 wei so 0-decimal / low-decimal tokens still attach real stake."
        );
    }

    function test_swap_stake_zero_input_still_bumps_to_one_wei( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_swap_stake( TokenAmount({ token: token0, amount: 0 }) );

        // The bump applies unconditionally to dust; a 0-amount bond is malformed and BondRoute refunds it anyway,
        // so the stake value here is never enforced.
        assertEq(
            stake.amount,
            1,
            "Zero-input swap bumps to 1 wei like any other dust input (degenerate path, never executes)."
        );
    }
}

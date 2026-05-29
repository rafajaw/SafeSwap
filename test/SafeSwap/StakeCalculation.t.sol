// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";
import { FixedPoint96 } from "@UniswapV4Core/libraries/FixedPoint96.sol";


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


    // ━━━━  Liquidity Stake  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_liquidity_stake_defaults_to_token0( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_normalized_liquidity_stake(
            uint160( 2 * FixedPoint96.Q96 ),
            token0,
            token1,
            token0,
            100 ether,
            200 ether
        );

        assertEq( address(stake.token), address(token0), "Liquidity stake should default to token0." );
        assertEq( stake.amount, 1.5 ether, "At price 4 token1/token0, token0 stake is 1% of (100 + 200 / 4)." );
    }

    function test_liquidity_stake_honors_token1_preference( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_normalized_liquidity_stake(
            uint160( 2 * FixedPoint96.Q96 ),
            token0,
            token1,
            token1,
            100 ether,
            200 ether
        );

        assertEq( address(stake.token), address(token1), "Liquidity stake should use token1 when token1 is explicitly preferred." );
        assertEq( stake.amount, 6 ether, "At price 4 token1/token0, token1 stake is 1% of (200 + 100 * 4)." );
    }

    function test_liquidity_stake_ignores_unknown_preference_and_defaults_to_token0( ) external view
    {
        TokenAmount memory stake  =  hook.harness_calculate_normalized_liquidity_stake(
            uint160( 2 * FixedPoint96.Q96 ),
            token0,
            token1,
            token2,
            100 ether,
            200 ether
        );

        assertEq( address(stake.token), address(token0), "Unknown preferred stake token should be ignored, not reverted." );
        assertEq( stake.amount, 1.5 ether, "Unknown preference should use the token0-denominated default stake." );
    }
}

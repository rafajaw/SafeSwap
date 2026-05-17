// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";
import {
    PROTOCOL_FEE_DIVISOR as SAFESWAP_PROTOCOL_FEE_DIVISOR,
    MIN_PROTOCOL_FEE_RATE as SAFESWAP_MIN_PROTOCOL_FEE_RATE
} from "@SafeSwap/Definitions.sol";


contract ProtocolFeeTest is SafeSwapTestBase {

    function setUp( ) public override
    {
        super.setUp( );

        // Enable real token transfers via BondRoute for fee distribution tests.
        MockBondRoute(payable(BONDROUTE_ADDRESS)).set_skip_actual_transfer( false );

        vm.startPrank( user );
        token0.approve( BONDROUTE_ADDRESS, type(uint256).max );
        token1.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );
    }


    // ━━━━  Fee Calculation  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_protocol_fee_is_10_percent_of_lp_fee_rate( ) external pure
    {
        // For a 0.3% pool (3000), protocol fee = 3000 / 10_000_000 = 0.03%.
        uint256 pool_fee    =  3000;
        uint256 amount_out  =  1_000_000 ether;

        uint256 protocol_fee  =  amount_out * pool_fee / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // Expected: 1_000_000 * 3000 / 10_000_000 = 300 ether.
        assertEq(
            protocol_fee,
            300 ether,
            "Protocol fee should be 10% of LP fee rate."
        );
    }

    function test_protocol_fee_uses_floor_for_low_fee_pools( ) external pure
    {
        // For a 0.01% pool (100), floor kicks in.
        uint256 pool_fee    =  100;
        uint256 amount_out  =  1_000_000 ether;

        uint256 effective_fee_rate  =  pool_fee < SAFESWAP_MIN_PROTOCOL_FEE_RATE  ?  SAFESWAP_MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        uint256 protocol_fee  =  amount_out * effective_fee_rate / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // With floor: 1_000_000 * 1000 / 10_000_000 = 100 ether (0.01%).
        assertEq(
            protocol_fee,
            100 ether,
            "Protocol fee should use floor for low fee pools."
        );
    }

    function test_protocol_fee_floor_is_001_percent( ) external pure
    {
        // Floor rate is 1000 out of 10_000_000 = 0.01%.
        uint256 floor_percentage  =  SAFESWAP_MIN_PROTOCOL_FEE_RATE * 100 / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // 1000 * 100 / 10_000_000 = 0 (integer division).
        // Better check: 1000 / 10_000_000 = 0.0001 = 0.01%.
        uint256 amount  =  10_000 ether;
        uint256 fee     =  amount * SAFESWAP_MIN_PROTOCOL_FEE_RATE / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // 10_000 * 1000 / 10_000_000 = 1 ether.
        assertEq(
            fee,
            1 ether,
            "0.01% floor on 10,000 should be 1."
        );
    }

    function test_protocol_fee_floor_kicks_in_below_010_percent_pool( ) external pure
    {
        // 0.10% = 1000 in Uniswap fee units.
        // Below this, floor applies.
        uint256 pool_fee_009  =  900;   // 0.09%.
        uint256 pool_fee_010  =  1000;  // 0.10% = floor threshold.
        uint256 pool_fee_011  =  1100;  // 0.11%.

        // 0.09% pool uses floor.
        uint256 effective_009  =  pool_fee_009 < SAFESWAP_MIN_PROTOCOL_FEE_RATE  ?  SAFESWAP_MIN_PROTOCOL_FEE_RATE  :  pool_fee_009;
        assertEq( effective_009, SAFESWAP_MIN_PROTOCOL_FEE_RATE, "0.09% pool should use floor." );

        // 0.10% pool is at floor (no change).
        uint256 effective_010  =  pool_fee_010 < SAFESWAP_MIN_PROTOCOL_FEE_RATE  ?  SAFESWAP_MIN_PROTOCOL_FEE_RATE  :  pool_fee_010;
        assertEq( effective_010, pool_fee_010, "0.10% pool should equal floor." );

        // 0.11% pool uses own rate.
        uint256 effective_011  =  pool_fee_011 < SAFESWAP_MIN_PROTOCOL_FEE_RATE  ?  SAFESWAP_MIN_PROTOCOL_FEE_RATE  :  pool_fee_011;
        assertEq( effective_011, pool_fee_011, "0.11% pool should use own rate." );
    }


    // ━━━━  Fee by Pool Type  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_protocol_fee_stable_pool_001_percent_uses_floor( ) external pure
    {
        // Stable pool: 0.01% LP fee.
        uint256 pool_fee    =  100;
        uint256 amount_out  =  100_000 ether;

        uint256 effective_fee_rate  =  pool_fee < SAFESWAP_MIN_PROTOCOL_FEE_RATE  ?  SAFESWAP_MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        uint256 protocol_fee  =  amount_out * effective_fee_rate / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // With floor: 100_000 * 1000 / 10_000_000 = 10 ether.
        assertEq(
            protocol_fee,
            10 ether,
            "Stable pool 0.01% should use floor."
        );
    }

    function test_protocol_fee_semi_stable_pool_005_percent_uses_floor( ) external pure
    {
        // Semi-stable pool: 0.05% LP fee.
        uint256 pool_fee    =  500;
        uint256 amount_out  =  100_000 ether;

        uint256 effective_fee_rate  =  pool_fee < SAFESWAP_MIN_PROTOCOL_FEE_RATE  ?  SAFESWAP_MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        uint256 protocol_fee  =  amount_out * effective_fee_rate / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // 0.05% < 0.10%, so floor applies: 100_000 * 1000 / 10_000_000 = 10 ether.
        assertEq(
            protocol_fee,
            10 ether,
            "Semi-stable pool 0.05% should use floor."
        );
    }

    function test_protocol_fee_standard_pool_030_percent_no_floor( ) external pure
    {
        // Standard pool: 0.30% LP fee.
        uint256 pool_fee    =  3000;
        uint256 amount_out  =  100_000 ether;

        uint256 effective_fee_rate  =  pool_fee < SAFESWAP_MIN_PROTOCOL_FEE_RATE  ?  SAFESWAP_MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        uint256 protocol_fee  =  amount_out * effective_fee_rate / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // 0.30% > 0.10%, no floor: 100_000 * 3000 / 10_000_000 = 30 ether.
        assertEq(
            protocol_fee,
            30 ether,
            "Standard pool 0.30% should not use floor."
        );
    }

    function test_protocol_fee_exotic_pool_100_percent_no_floor( ) external pure
    {
        // Exotic pool: 1.00% LP fee.
        uint256 pool_fee    =  10000;
        uint256 amount_out  =  100_000 ether;

        uint256 effective_fee_rate  =  pool_fee < SAFESWAP_MIN_PROTOCOL_FEE_RATE  ?  SAFESWAP_MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        uint256 protocol_fee  =  amount_out * effective_fee_rate / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // 1.00% > 0.10%, no floor: 100_000 * 10000 / 10_000_000 = 100 ether.
        assertEq(
            protocol_fee,
            100 ether,
            "Exotic pool 1.00% should not use floor."
        );
    }


    // ━━━━  Fee Distribution  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_protocol_fee_sent_to_contract( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        // Mock returns 100 ether output.
        pool_manager.set_mock_swap_amounts( -100 ether, 100 ether );

        uint256 hook_balance_before  =  token1.balanceOf( address(hook) );

        vm.prank( address(pool_manager) );
        hook.test_execute_exact_input_swap( context, params );

        // Protocol fee = 100 * 3000 / 10_000_000 = 0.03 ether.
        assertEq(
            token1.balanceOf( address(hook) ) - hook_balance_before,
            0.03 ether,
            "Hook should receive 0.03 ether protocol fee via pool_manager.take()."
        );
    }

    function test_user_receives_output_minus_protocol_fee( ) external
    {
        BondContext memory context  =  _create_bond_context( user, 100 ether );
        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        pool_manager.set_mock_swap_amounts( -100 ether, 100 ether );

        uint256 user_balance_before  =  token1.balanceOf( user );

        vm.prank( address(pool_manager) );
        hook.test_execute_exact_input_swap( context, params );

        // User receives: 100 - (100 * 3000 / 10_000_000) = 100 - 0.03 = 99.97 ether.
        assertEq(
            token1.balanceOf( user ) - user_balance_before,
            99.97 ether,
            "User should receive 99.97 ether (output minus protocol fee)."
        );
    }


    // ━━━━  Edge Cases  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_protocol_fee_on_minimum_swap_amount( ) external pure
    {
        uint256 pool_fee    =  3000;
        uint256 amount_out  =  1;  // Minimum: 1 wei.

        uint256 protocol_fee  =  amount_out * pool_fee / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // 1 * 3000 / 10_000_000 = 0 (rounds down).
        assertEq(
            protocol_fee,
            0,
            "Protocol fee on 1 wei should round to 0."
        );
    }

    function test_protocol_fee_on_maximum_swap_amount( ) external pure
    {
        uint256 pool_fee    =  3000;
        uint256 amount_out  =  type(uint128).max;  // Large but safe amount.

        uint256 protocol_fee  =  amount_out * pool_fee / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // Should not overflow.
        assertGt(
            protocol_fee,
            0,
            "Protocol fee on large amount should be positive."
        );

        // Fee should be < amount_out.
        assertLt(
            protocol_fee,
            amount_out,
            "Protocol fee should be less than output amount."
        );
    }

    function test_protocol_fee_exactly_at_floor_threshold( ) external pure
    {
        // Pool fee exactly at floor threshold.
        uint256 pool_fee    =  1000;  // 0.10% = floor.
        uint256 amount_out  =  100_000 ether;

        uint256 effective_fee_rate  =  pool_fee < SAFESWAP_MIN_PROTOCOL_FEE_RATE  ?  SAFESWAP_MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        uint256 protocol_fee  =  amount_out * effective_fee_rate / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // At threshold: 100_000 * 1000 / 10_000_000 = 10 ether.
        assertEq(
            protocol_fee,
            10 ether,
            "Protocol fee at threshold should equal floor calculation."
        );

        // Effective rate should equal pool fee (not changed by floor).
        assertEq(
            effective_fee_rate,
            pool_fee,
            "Effective rate at threshold should equal pool fee."
        );
    }
}

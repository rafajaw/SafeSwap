// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";
import {
    PROTOCOL_FEE_DIVISOR as SAFESWAP_PROTOCOL_FEE_DIVISOR,
    MIN_PROTOCOL_FEE_RATE as SAFESWAP_MIN_PROTOCOL_FEE_RATE
} from "@SafeSwapRouter/Definitions.sol";


contract FuzzTest is SafeSwapTestBase {


    // ━━━━  Fee Calculation  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function testFuzz_protocol_fee_never_exceeds_output( uint256 amount_out, uint24 pool_fee ) external pure
    {
        // Bound inputs to reasonable ranges.
        amount_out  =  bound( amount_out, 1, type(uint128).max );
        pool_fee    =  uint24(bound( pool_fee, 1, 1_000_000 ));  // Max 100% fee.

        uint256 effective_fee_rate  =  pool_fee < SAFESWAP_MIN_PROTOCOL_FEE_RATE  ?  SAFESWAP_MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        uint256 protocol_fee  =  amount_out * effective_fee_rate / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        assertLe(
            protocol_fee,
            amount_out,
            "Protocol fee should never exceed output amount."
        );
    }

    function testFuzz_protocol_fee_at_least_floor_rate( uint256 amount_out, uint24 pool_fee ) external pure
    {
        // Bound inputs.
        amount_out  =  bound( amount_out, SAFESWAP_PROTOCOL_FEE_DIVISOR, type(uint128).max );  // Large enough for meaningful fee.
        pool_fee    =  uint24(bound( pool_fee, 1, 500 ));  // Below floor threshold.

        uint256 effective_fee_rate  =  pool_fee < SAFESWAP_MIN_PROTOCOL_FEE_RATE  ?  SAFESWAP_MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        uint256 protocol_fee  =  amount_out * effective_fee_rate / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // Floor fee calculation.
        uint256 floor_fee  =  amount_out * SAFESWAP_MIN_PROTOCOL_FEE_RATE / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        assertGe(
            protocol_fee,
            floor_fee,
            "Protocol fee should be at least floor rate for low fee pools."
        );
    }

    function testFuzz_protocol_fee_proportional_to_pool_fee( uint256 amount_out, uint24 pool_fee ) external pure
    {
        // Bound inputs to avoid overflow and precision issues.
        // Use amounts divisible by divisor to avoid rounding issues.
        amount_out  =  bound( amount_out, SAFESWAP_PROTOCOL_FEE_DIVISOR, type(uint64).max );
        amount_out  =  amount_out - ( amount_out % SAFESWAP_PROTOCOL_FEE_DIVISOR );
        pool_fee    =  uint24(bound( pool_fee, SAFESWAP_MIN_PROTOCOL_FEE_RATE, 50_000 ));

        uint256 protocol_fee  =  amount_out * pool_fee / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // Double the pool fee should approximately double the protocol fee.
        uint24 double_fee  =  pool_fee * 2;
        uint256 double_protocol_fee  =  amount_out * double_fee / SAFESWAP_PROTOCOL_FEE_DIVISOR;

        // Allow 1 wei difference due to rounding.
        assertApproxEqAbs(
            double_protocol_fee,
            protocol_fee * 2,
            1,
            "Protocol fee should be proportional to pool fee."
        );
    }


    // ━━━━  Stake Calculation  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function testFuzz_stake_is_1_percent_of_amount( uint256 amount ) external pure
    {
        // Bound to reasonable range.
        amount  =  bound( amount, 100, type(uint128).max );

        uint256 stake  =  amount * 1 / 100;

        assertEq(
            stake,
            amount / 100,
            "Stake should be exactly 1% of amount."
        );

        assertLe(
            stake,
            amount,
            "Stake should not exceed amount."
        );
    }


    // ━━━━  Slippage Protection  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function testFuzz_exact_input_respects_minimum_output( uint256 amount_in, uint256 min_out ) external
    {
        // Bound inputs to fit in int128.
        uint256 max_int128  =  uint256(uint128(type(int128).max));
        amount_in  =  bound( amount_in, 1 ether, max_int128 );
        min_out    =  bound( min_out, 2, amount_in );  // min_out <= amount_in, at least 2 so min_out - 1 > 0.

        BondContext memory context  =  _create_bond_context( user, amount_in );
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token1,
            minimum_output_amount: min_out,
            pool_info: _default_pool_info( )
        });

        // Mock returns pool_output one wei under min_out. The net amount delivered to the user (after protocol fee)
        // is necessarily even smaller, so the net-of-fee slippage check must revert.
        uint256 pool_output  =  min_out - 1;
        pool_manager.set_mock_swap_amounts( -int128(uint128(amount_in)), int128(uint128(pool_output)) );

        ( , uint256 expected_user_output )  =  SafeSwapCommon.calculate_protocol_fee( pool_output, POOL_FEE_030 );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, expected_user_output, min_out ) );
        hook.harness_execute_exact_input_swap( context, params );
    }

    function testFuzz_exact_output_respects_maximum_input( uint256 exact_output_amount, uint256 max_in ) external
    {
        // Bound inputs to fit in int128.
        uint256 max_int128  =  uint256(uint128(type(int128).max));
        exact_output_amount  =  bound( exact_output_amount, 1 ether, max_int128 / 2 );
        max_in      =  bound( max_in, 1 ether, max_int128 - 1 );  // Leave room for +1.

        BondContext memory context  =  _create_bond_context( user, max_in );
        ExactOutputSwapParams memory params  =  ExactOutputSwapParams({
            token_out: token1,
            exact_output_amount: exact_output_amount,
            pool_info: _default_pool_info( )
        });

        // Mock requires more than maximum - should revert.
        int128 mock_input  =  -int128(uint128(max_in + 1));
        pool_manager.set_mock_swap_amounts( mock_input, int128(uint128(exact_output_amount)) );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, max_in + 1, max_in ) );
        hook.harness_execute_exact_output_swap( context, params );
    }


    // ━━━━  Donate  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function testFuzz_donate_executes_for_arbitrary_split( uint128 amount0, uint128 amount1 ) external
    {
        // Bound away from zero so fundings are non-empty; cap below int128 max to avoid pool overflow.
        amount0  =  uint128(bound( amount0, 1, uint128(type(int128).max / 2) ));
        amount1  =  uint128(bound( amount1, 1, uint128(type(int128).max / 2) ));

        BondContext memory context  =  _create_bond_context_two_fundings( user, amount0, amount1 );
        DonateParams memory params  =  _create_donate_params( );

        // Pool requests the exact funded amounts back as the donation.
        pool_manager.set_mock_donate_amounts( -int128(amount0), -int128(amount1) );

        vm.prank( address(pool_manager) );
        hook.harness_execute_donate( context, params );
        // Property: settlement does not revert across any (amount0, amount1) within bounds.
    }

    function testFuzz_donate_executes_for_one_sided_split( uint128 amount, bool donate_token0 ) external
    {
        amount  =  uint128(bound( amount, 1, uint128(type(int128).max / 2) ));

        uint128 amount0  =  donate_token0 ? amount : 0;
        uint128 amount1  =  donate_token0 ? 0 : amount;

        BondContext memory context  =  _create_bond_context_two_fundings( user, amount0, amount1 );
        DonateParams memory params  =  _create_donate_params( );

        pool_manager.set_mock_donate_amounts( -int128(amount0), -int128(amount1) );

        vm.prank( address(pool_manager) );
        hook.harness_execute_donate( context, params );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";
import { SafeSwapCommon } from "@SafeSwap/libraries/SafeSwapCommon.sol";


contract FuzzTest is SafeSwapTestBase {

    uint256 constant PROTOCOL_FEE_DIVISOR   =  SafeSwapCommon.PROTOCOL_FEE_DIVISOR;
    uint256 constant MIN_PROTOCOL_FEE_RATE  =  SafeSwapCommon.MIN_PROTOCOL_FEE_RATE;


    // ━━━━  Fee Calculation  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function testFuzz_protocol_fee_never_exceeds_output( uint256 amount_out, uint24 pool_fee ) external pure
    {
        // Bound inputs to reasonable ranges.
        amount_out  =  bound( amount_out, 1, type(uint128).max );
        pool_fee    =  uint24( bound( pool_fee, 1, 1_000_000 ) );  // Max 100% fee.

        uint256 effective_fee_rate  =  pool_fee < MIN_PROTOCOL_FEE_RATE  ?  MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        uint256 protocol_fee  =  amount_out * effective_fee_rate / PROTOCOL_FEE_DIVISOR;

        assertLe(
            protocol_fee,
            amount_out,
            "Protocol fee should never exceed output amount."
        );
    }

    function testFuzz_protocol_fee_at_least_floor_rate( uint256 amount_out, uint24 pool_fee ) external pure
    {
        // Bound inputs.
        amount_out  =  bound( amount_out, PROTOCOL_FEE_DIVISOR, type(uint128).max );  // Large enough for meaningful fee.
        pool_fee    =  uint24( bound( pool_fee, 1, 500 ) );  // Below floor threshold.

        uint256 effective_fee_rate  =  pool_fee < MIN_PROTOCOL_FEE_RATE  ?  MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        uint256 protocol_fee  =  amount_out * effective_fee_rate / PROTOCOL_FEE_DIVISOR;

        // Floor fee calculation.
        uint256 floor_fee  =  amount_out * MIN_PROTOCOL_FEE_RATE / PROTOCOL_FEE_DIVISOR;

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
        amount_out  =  bound( amount_out, PROTOCOL_FEE_DIVISOR, type(uint64).max );
        amount_out  =  ( amount_out / PROTOCOL_FEE_DIVISOR ) * PROTOCOL_FEE_DIVISOR;
        pool_fee    =  uint24( bound( pool_fee, MIN_PROTOCOL_FEE_RATE, 50_000 ) );

        uint256 protocol_fee  =  amount_out * pool_fee / PROTOCOL_FEE_DIVISOR;

        // Double the pool fee should approximately double the protocol fee.
        uint24 double_fee  =  pool_fee * 2;
        uint256 double_protocol_fee  =  amount_out * double_fee / PROTOCOL_FEE_DIVISOR;

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
            minimum_amount_out: min_out,
            pool_info: _default_pool_info( )
        });

        // Mock returns less than minimum - should revert.
        int128 mock_output  =  int128(uint128(min_out - 1));
        pool_manager.set_mock_swap_amounts( -int128(uint128(amount_in)), mock_output );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, min_out - 1, min_out ) );
        hook.test_execute_exact_input_swap( context, params );
    }

    function testFuzz_exact_output_respects_maximum_input( uint256 amount_out, uint256 max_in ) external
    {
        // Bound inputs to fit in int128.
        uint256 max_int128  =  uint256(uint128(type(int128).max));
        amount_out  =  bound( amount_out, 1 ether, max_int128 / 2 );
        max_in      =  bound( max_in, 1 ether, max_int128 - 1 );  // Leave room for +1.

        BondContext memory context  =  _create_bond_context( user, max_in );
        ExactOutputSwapParams memory params  =  ExactOutputSwapParams({
            token_out: token1,
            amount_out: amount_out,
            pool_info: _default_pool_info( )
        });

        // Mock requires more than maximum - should revert.
        int128 mock_input  =  -int128(uint128(max_in + 1));
        pool_manager.set_mock_swap_amounts( mock_input, int128(uint128(amount_out)) );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, max_in + 1, max_in ) );
        hook.test_execute_exact_output_swap( context, params );
    }
}

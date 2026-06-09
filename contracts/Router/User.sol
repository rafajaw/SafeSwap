// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwapRouter/Orchestrator.sol";
import "@SafeSwapRouter/HookRegistry.sol";
import "@SafeSwapCommon/SafeSwapCommon.sol";
import "@SafeSwapCommon/SwapSimulator.sol";
import "@BondRouteProtected/BondRouteProtected.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";

using PoolIdLibrary for PoolKey;
using StateLibrary for IPoolManager;


/**
 * @title User
 * @notice User-facing SafeSwap swap operations and off-chain swap helpers. The SwapRouter handles swaps only; LP positions
 *         live in the PositionManager NFT.
 */
abstract contract User is Orchestrator, HookRegistry, BondRouteProtected {

    constructor( )
    BondRouteProtected( SAFESWAP_PROTOCOL_NAME, SAFESWAP_PROTOCOL_DESCRIPTION ) { }


    // ━━━━  USER FUNCTIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Execute an exact-input Uniswap V4 swap through BondRoute.
     * @param params Output token, minimum net output, and pool configuration (base fee, capture, tick spacing).
     *
     * @dev Callable only through a valid BondRoute bond. Input token and amount come from the bond funding. The pool's LP
     *      fee (base + repricing) is applied by the hook and accrues to LPs; the user's net output is after the SafeSwap
     *      protocol fee and is checked against `minimum_output_amount`.
     */
    function bonded_swap_exact_input( ExactInputSwapParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        address hook  =  _resolve_hook( params.pool_info.base_fee_bps, params.pool_info.rebate_percent );

        bytes memory data  =  bytes.concat( bytes1(uint8(SwapAction.ExactInput)), abi.encode( context, params, hook ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Execute an exact-output Uniswap V4 swap through BondRoute.
     * @param params Output token, exact net output amount, and pool configuration.
     *
     * @dev Callable only through a valid BondRoute bond. Maximum input comes from the bond funding; the LP fee is charged
     *      on the input by the hook and counts against that maximum.
     */
    function bonded_swap_exact_output( ExactOutputSwapParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        address hook  =  _resolve_hook( params.pool_info.base_fee_bps, params.pool_info.rebate_percent );

        bytes memory data  =  bytes.concat( bytes1(uint8(SwapAction.ExactOutput)), abi.encode( context, params, hook ) );
        PoolManager.unlock( data );
    }


    // ━━━━  OFF-CHAIN GETTERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Compute the Uniswap V4 pool id for a SafeSwap pool.
     */
    function __OFF_CHAIN__get_pool_id( IERC20 token_a, IERC20 token_b, PoolInfo calldata pool_info )
    external  view returns ( PoolId pool_id )
    {
        address hook  =  _resolve_hook( pool_info.base_fee_bps, pool_info.rebate_percent );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( token_a, token_b, LPFeeLibrary.DYNAMIC_FEE_FLAG, pool_info.tick_spacing, hook );

        pool_id  =  pool_key.toId( );
    }

    /**
     * @notice Read the live Uniswap V4 state of a SafeSwap pool: its id, current price, current tick, and whether it exists yet.
     * @return pool_id The Uniswap V4 pool id for this `(token pair, base fee, capture, tick spacing)`.
     * @return sqrt_price_x96 The current pool price (Q64.96), or zero when the pool has not been initialized.
     * @return tick The current pool tick, or zero when the pool has not been initialized.
     * @return initialized True once the pool has a price (a position has been created in it), false otherwise.
     *
     * @dev Lets a frontend show live price / range occupancy for the Earn explorer and decide whether a Create call will
     *      initialize a new pool or join an existing one, without needing the PoolManager address or slot derivation client-side.
     *      An uninitialized pool reports `sqrt_price_x96 == 0` from slot0, so that doubles as the existence flag.
     */
    function __OFF_CHAIN__get_pool_state( IERC20 token_a, IERC20 token_b, PoolInfo calldata pool_info )
    external  view returns ( PoolId pool_id, uint160 sqrt_price_x96, int24 tick, bool initialized )
    {
        address hook  =  _resolve_hook( pool_info.base_fee_bps, pool_info.rebate_percent );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( token_a, token_b, LPFeeLibrary.DYNAMIC_FEE_FLAG, pool_info.tick_spacing, hook );
        pool_id  =  pool_key.toId( );

        ( sqrt_price_x96, tick, , )  =  PoolManager.getSlot0( pool_id );
        initialized  =  sqrt_price_x96 != 0;
    }

    /**
     * @notice Quote an exact-input swap: the total LP fee, the price movement, and the user's net output after the protocol fee.
     * @return expected_net_output Output the user would receive, net of the protocol fee, at the estimated total fee.
     * @return total_fee_pips Total LP fee (base + repricing) the hook would apply, in v4 pips.
     * @return movement_bps Estimated pool price movement in basis points.
     *
     * @dev Two-pass simulation with the SAME `SwapSimulator` the hook uses, so the quoted fee equals the executed fee. Pass
     *      one estimates the movement (and thus the fee) at the base fee; pass two estimates the output at that total fee.
     */
    function __OFF_CHAIN__quote_swap_exact_input( IERC20 token_in, IERC20 token_out, PoolInfo calldata pool_info, uint256 amount_in )
    external  view returns ( uint256 expected_net_output, uint24 total_fee_pips, uint256 movement_bps )
    {
        address hook  =  _resolve_hook( pool_info.base_fee_bps, pool_info.rebate_percent );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( token_in, token_out, LPFeeLibrary.DYNAMIC_FEE_FLAG, pool_info.tick_spacing, hook );
        bool zero_for_one        =  address(token_in) < address(token_out);
        uint24 base_fee_pips     =  SafeSwapCommon.compute_base_fee_pips( pool_info.base_fee_bps );

        ( int24 tick_before, int24 tick_after, uint160 sqrt_price_after_x96, uint256 gross_output_estimate )  =  SwapSimulator.simulate( PoolManager, pool_key, zero_for_one, -int256(amount_in), base_fee_pips );

        ( uint256 leg_in, uint256 leg_out )  =  SafeSwapCommon.compute_swap_amounts( -int256(amount_in), gross_output_estimate );
        total_fee_pips  =  SafeSwapCommon.compute_repricing_fee_pips( leg_in, leg_out, sqrt_price_after_x96, zero_for_one, pool_info.rebate_percent, base_fee_pips );
        movement_bps    =  tick_after >= tick_before  ?  uint256(int256(tick_after) - int256(tick_before))  :  uint256(int256(tick_before) - int256(tick_after));

        ( , , , uint256 gross_output )  =  SwapSimulator.simulate( PoolManager, pool_key, zero_for_one, -int256(amount_in), total_fee_pips );

        ( , expected_net_output )  =  SafeSwapCommon.calculate_protocol_fee( gross_output, base_fee_pips );
    }

    /**
     * @notice Quote an exact-output swap: the total LP fee, the price movement, and the input required to net `exact_output_amount`.
     * @return required_input Input the user must fund to receive `exact_output_amount` net of the protocol fee, at the estimated total fee.
     * @return total_fee_pips Total LP fee (base + repricing) the hook would apply, in v4 pips.
     * @return movement_bps Estimated pool price movement in basis points.
     *
     * @dev Same two-pass approach as the exact-input quoter, plus a protocol-fee gross-up of the requested output.
     */
    function __OFF_CHAIN__quote_swap_exact_output( IERC20 token_in, IERC20 token_out, PoolInfo calldata pool_info, uint256 exact_output_amount )
    external  view returns ( uint256 required_input, uint24 total_fee_pips, uint256 movement_bps )
    {
        address hook  =  _resolve_hook( pool_info.base_fee_bps, pool_info.rebate_percent );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( token_in, token_out, LPFeeLibrary.DYNAMIC_FEE_FLAG, pool_info.tick_spacing, hook );
        bool zero_for_one        =  address(token_in) < address(token_out);
        uint24 base_fee_pips     =  SafeSwapCommon.compute_base_fee_pips( pool_info.base_fee_bps );

        // Gross up the requested output for the SafeSwap protocol fee (the LP fee is taken separately from the input).
        uint256 effective_fee_rate  =  base_fee_pips < MIN_PROTOCOL_FEE_RATE  ?  MIN_PROTOCOL_FEE_RATE  :  base_fee_pips;
        uint256 grossed_up_output   =  exact_output_amount * PROTOCOL_FEE_DIVISOR / ( PROTOCOL_FEE_DIVISOR - effective_fee_rate );

        ( int24 tick_before, int24 tick_after, uint160 sqrt_price_after_x96, uint256 required_input_estimate )  =  SwapSimulator.simulate( PoolManager, pool_key, zero_for_one, int256(grossed_up_output), base_fee_pips );

        ( uint256 leg_in, uint256 leg_out )  =  SafeSwapCommon.compute_swap_amounts( int256(grossed_up_output), required_input_estimate );
        total_fee_pips  =  SafeSwapCommon.compute_repricing_fee_pips( leg_in, leg_out, sqrt_price_after_x96, zero_for_one, pool_info.rebate_percent, base_fee_pips );
        movement_bps    =  tick_after >= tick_before  ?  uint256(int256(tick_after) - int256(tick_before))  :  uint256(int256(tick_before) - int256(tick_after));

        ( , , , required_input )  =  SwapSimulator.simulate( PoolManager, pool_key, zero_for_one, int256(grossed_up_output), total_fee_pips );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { SwapMath } from "@UniswapV4Core/libraries/SwapMath.sol";
import { TickBitmap } from "@UniswapV4Core/libraries/TickBitmap.sol";
import { BitMath } from "@UniswapV4Core/libraries/BitMath.sol";
import { LiquidityMath } from "@UniswapV4Core/libraries/LiquidityMath.sol";


/**
 * @title SwapWalkLib
 * @notice Read-only forward simulation of a Uniswap V4 swap's tick walk, used to estimate the post-swap tick (and hence
 *         the price movement) BEFORE the swap executes — the input a dynamic-fee repricing rebate would need in beforeSwap.
 *
 * @dev Faithful port of `Pool.swap`'s loop, reading live pool state via `StateLibrary` and only the per-tick `liquidityNet`
 *      on each crossing (fee-growth tracking is irrelevant to the price path, so it is omitted). Simulate with the pool's
 *      base LP fee; the fee↔movement feedback is second-order. The slots read here are exactly the slots the real swap
 *      reads, so running this immediately before the swap warms them (the cold cost is paid by the swap regardless).
 */
library SwapWalkLib {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /**
     * @notice Simulate `params`-style swap and return where the price lands.
     * @param amount_specified Negative for exact-input, positive for exact-output (Uniswap V4 convention).
     * @param fee_pips Swap fee in pips (the pool's base LP fee for the estimate).
     * @return tick_after Estimated post-swap tick.
     * @return sqrt_price_after_x96 Estimated post-swap sqrt price.
     * @return ticks_crossed Number of initialized ticks crossed (for benchmarking / movement diagnostics).
     */
    function simulate( IPoolManager manager, PoolKey memory key, bool zero_for_one, int256 amount_specified, uint24 fee_pips )
    internal view returns ( int24 tick_after, uint160 sqrt_price_after_x96, uint256 ticks_crossed )
    {
        PoolId pool_id  =  key.toId( );

        ( uint160 sqrt_price_x96, int24 tick, , )  =  manager.getSlot0( pool_id );
        uint128 liquidity  =  manager.getLiquidity( pool_id );

        int256 remaining  =  amount_specified;
        uint160 price_limit  =  zero_for_one  ?  TickMath.MIN_SQRT_PRICE + 1  :  TickMath.MAX_SQRT_PRICE - 1;

        unchecked
        {
            while(  remaining != 0  &&  sqrt_price_x96 != price_limit  )
            {
                uint160 start_price_x96  =  sqrt_price_x96;

                ( int24 tick_next, bool initialized )  =  _next_initialized_tick_within_one_word( manager, pool_id, tick, key.tickSpacing, zero_for_one );

                if(  tick_next <= TickMath.MIN_TICK  )  tick_next  =  TickMath.MIN_TICK;
                if(  tick_next >= TickMath.MAX_TICK  )  tick_next  =  TickMath.MAX_TICK;

                uint160 sqrt_price_next_x96  =  TickMath.getSqrtPriceAtTick( tick_next );

                uint256 amount_in;
                uint256 amount_out;
                uint256 fee_amount;
                ( sqrt_price_x96, amount_in, amount_out, fee_amount )  =  SwapMath.computeSwapStep(
                    sqrt_price_x96,
                    SwapMath.getSqrtPriceTarget( zero_for_one, sqrt_price_next_x96, price_limit ),
                    liquidity,
                    remaining,
                    fee_pips
                );

                if(  amount_specified > 0  )
                {
                    remaining  -=  int256(amount_out);
                }
                else
                {
                    remaining  +=  int256(amount_in + fee_amount);
                }

                if(  sqrt_price_x96 == sqrt_price_next_x96  )
                {
                    if(  initialized  )
                    {
                        ( , int128 liquidity_net )  =  manager.getTickLiquidity( pool_id, tick_next );
                        if(  zero_for_one  )  liquidity_net  =  -liquidity_net;

                        liquidity       =  LiquidityMath.addDelta( liquidity, liquidity_net );
                        ticks_crossed   =  ticks_crossed + 1;
                    }

                    tick  =  zero_for_one  ?  tick_next - 1  :  tick_next;
                }
                else if(  sqrt_price_x96 != start_price_x96  )
                {
                    tick  =  TickMath.getTickAtSqrtPrice( sqrt_price_x96 );
                }
            }
        }

        tick_after            =  tick;
        sqrt_price_after_x96  =  sqrt_price_x96;
    }

    /**
     * @notice Walk and cross up to `max_crossings` initialized ticks doing ONLY the state reads (bitmap word + liquidityNet),
     *         the bit-scan, and the liquidity update — NO `computeSwapStep` / sqrt-price arithmetic.
     * @dev Isolates the simulation's I/O + call overhead from its AMM-math cost for benchmarking.
     */
    function walk_only( IPoolManager manager, PoolKey memory key, bool zero_for_one, uint256 max_crossings )
    internal view returns ( uint256 ticks_crossed )
    {
        PoolId pool_id  =  key.toId( );

        ( , int24 tick, , )  =  manager.getSlot0( pool_id );
        uint128 liquidity  =  manager.getLiquidity( pool_id );

        unchecked
        {
            while(  ticks_crossed < max_crossings  )
            {
                ( int24 tick_next, bool initialized )  =  _next_initialized_tick_within_one_word( manager, pool_id, tick, key.tickSpacing, zero_for_one );

                if(  tick_next <= TickMath.MIN_TICK  )  { tick_next = TickMath.MIN_TICK; }
                if(  tick_next >= TickMath.MAX_TICK  )  { tick_next = TickMath.MAX_TICK; }

                if(  initialized  )
                {
                    ( , int128 liquidity_net )  =  manager.getTickLiquidity( pool_id, tick_next );
                    if(  zero_for_one  )  liquidity_net  =  -liquidity_net;

                    liquidity      =  LiquidityMath.addDelta( liquidity, liquidity_net );
                    ticks_crossed  =  ticks_crossed + 1;
                }

                tick  =  zero_for_one  ?  tick_next - 1  :  tick_next;

                if(  tick_next == TickMath.MIN_TICK  ||  tick_next == TickMath.MAX_TICK  )  break;
            }
        }
    }

    // Reimplementation of TickBitmap.nextInitializedTickWithinOneWord that reads the bitmap word via StateLibrary
    // instead of a storage mapping, so it works against a live PoolManager from outside the pool.
    function _next_initialized_tick_within_one_word( IPoolManager manager, PoolId pool_id, int24 tick, int24 tick_spacing, bool lte )
    private view returns ( int24 next, bool initialized )
    {
        unchecked
        {
            int24 compressed  =  TickBitmap.compress( tick, tick_spacing );

            if(  lte  )
            {
                ( int16 word_pos, uint8 bit_pos )  =  TickBitmap.position( compressed );
                uint256 mask    =  type(uint256).max >> ( uint256(type(uint8).max) - bit_pos );
                uint256 masked  =  manager.getTickBitmap( pool_id, word_pos ) & mask;

                initialized  =  masked != 0;
                next  =  initialized
                    ? ( compressed - int24(uint24(bit_pos - BitMath.mostSignificantBit( masked ))) ) * tick_spacing
                    : ( compressed - int24(uint24(bit_pos)) ) * tick_spacing;
            }
            else
            {
                int24 next_compressed  =  compressed + 1;
                ( int16 word_pos, uint8 bit_pos )  =  TickBitmap.position( next_compressed );
                uint256 mask    =  ~( ( uint256(1) << bit_pos ) - 1 );
                uint256 masked  =  manager.getTickBitmap( pool_id, word_pos ) & mask;

                initialized  =  masked != 0;
                next  =  initialized
                    ? ( next_compressed + int24(uint24(BitMath.leastSignificantBit( masked ) - bit_pos)) ) * tick_spacing
                    : ( next_compressed + int24(uint24(type(uint8).max - bit_pos)) ) * tick_spacing;
            }
        }
    }
}

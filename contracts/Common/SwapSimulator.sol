// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { SwapMath } from "@UniswapV4Core/libraries/SwapMath.sol";
import { TickBitmap } from "@UniswapV4Core/libraries/TickBitmap.sol";
import { BitMath } from "@UniswapV4Core/libraries/BitMath.sol";
import { LiquidityMath } from "@UniswapV4Core/libraries/LiquidityMath.sol";


/**
 * @title SwapSimulator
 * @notice Read-only forward simulation of a Uniswap V4 swap's price path. Given live pool state and a swap request, it
 *         returns the tick the swap would land on — the input the LP repricing rebate needs to price movement BEFORE the
 *         swap executes (a v4 dynamic LP fee must be chosen in `beforeSwap`, before the realized movement is known).
 *
 * @dev Faithful port of `Pool.swap`'s loop (both swap directions, exact-input and exact-output, multi-word), so the
 *      returned tick matches the real swap. Simulate with the pool's base LP fee; the fee-vs-movement feedback is
 *      second-order. The slots read here are exactly the slots the real swap reads, so running this immediately before
 *      the swap warms them — the cold storage cost is paid by the swap regardless.
 *
 *      Performance: pool state is read through raw `extsload` staticcalls assembled inline (no Solidity ABI encode/decode
 *      of return arrays), storage slots are derived in assembly using only the two EVM scratch words (0x00, 0x20) so the
 *      free-memory pointer is never disturbed, and the tick bitmap word is read once per 256-tick word rather than once
 *      per crossing. The AMM arithmetic itself reuses Uniswap's already-optimized `SwapMath` / `TickMath` libraries.
 */
library SwapSimulator {
    using PoolIdLibrary for PoolKey;

    // Storage layout of Uniswap V4 `PoolManager`: `mapping(PoolId => Pool.State) pools` at slot 6, and within Pool.State
    // the liquidity, ticks mapping, and tickBitmap mapping at these offsets. Mirrors `StateLibrary`.
    uint256 constant POOLS_SLOT          =  6;
    uint256 constant LIQUIDITY_OFFSET    =  3;
    uint256 constant TICKS_OFFSET        =  4;
    uint256 constant TICK_BITMAP_OFFSET  =  5;

    // `extsload(bytes32)` selector — single-slot raw read.
    uint256 constant EXTSLOAD_SELECTOR   =  0x1e2eaeaf;

    /// @notice Working state threaded through the walk so the bitmap word is fetched once per word, not once per tick.
    struct WordCache {
        bytes32 bitmap_mapping_slot;
        int16 word_pos;
        uint256 word;
        bool loaded;
    }

    /**
     * @notice Estimate where a swap would move the pool price.
     * @param amount_specified Negative for exact-input, positive for exact-output (Uniswap V4 convention).
     * @param fee_pips Swap fee in pips to simulate with (the pool's base LP fee).
     * @return tick_before Pool tick before the swap.
     * @return tick_after Estimated pool tick after the swap.
     * @return sqrt_price_after_x96 Estimated post-swap sqrt price.
     * @return amount_calculated Counterpart amount at `fee_pips`: total output for exact-input, total input for exact-output.
     */
    function simulate( IPoolManager manager, PoolKey memory key, bool zero_for_one, int256 amount_specified, uint24 fee_pips )
    internal view returns ( int24 tick_before, int24 tick_after, uint160 sqrt_price_after_x96, uint256 amount_calculated )
    {
        bytes32 state_slot     =  _pool_state_slot( key.toId( ) );
        bytes32 ticks_mapping  =  bytes32( uint256(state_slot) + TICKS_OFFSET );

        bytes32 slot0  =  _extsload( manager, state_slot );
        uint160 sqrt_price_x96  =  uint160(uint256(slot0));   // low 160 bits of slot0 hold sqrtPriceX96 (truncating cast).
        int24 tick;
        assembly ("memory-safe")
        {
            tick  :=  signextend( 2, shr(160, slot0) )         // bits 160-183 hold the signed current tick.
        }

        tick_before  =  tick;

        uint128 liquidity  =  uint128(uint256( _extsload( manager, bytes32( uint256(state_slot) + LIQUIDITY_OFFSET ) ) ));

        WordCache memory cache;
        cache.bitmap_mapping_slot  =  bytes32( uint256(state_slot) + TICK_BITMAP_OFFSET );

        int24 tick_spacing  =  key.tickSpacing;
        int256 remaining    =  amount_specified;
        uint160 price_limit =  zero_for_one  ?  TickMath.MIN_SQRT_PRICE + 1  :  TickMath.MAX_SQRT_PRICE - 1;
        amount_calculated   =  0;

        unchecked
        {
            while(  remaining != 0  &&  sqrt_price_x96 != price_limit  )
            {
                uint160 start_price_x96  =  sqrt_price_x96;

                ( int24 tick_next, bool initialized )  =  _next_initialized_tick( manager, cache, tick, tick_spacing, zero_for_one );

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
                    remaining          -=  int256(amount_out);
                    amount_calculated  +=  amount_in + fee_amount;     // exact-output: accumulate the required input.
                }
                else
                {
                    remaining          +=  int256(amount_in + fee_amount);
                    amount_calculated  +=  amount_out;                 // exact-input: accumulate the produced output.
                }

                if(  sqrt_price_x96 == sqrt_price_next_x96  )
                {
                    if(  initialized  )
                    {
                        int128 liquidity_net  =  _liquidity_net( manager, ticks_mapping, tick_next );
                        if(  zero_for_one  )  liquidity_net  =  -liquidity_net;

                        liquidity  =  LiquidityMath.addDelta( liquidity, liquidity_net );
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


    // ━━━━  TICK BITMAP WALK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // Same result as `TickBitmap.nextInitializedTickWithinOneWord`, but reads the bitmap word through the cache so repeated
    // searches inside one 256-tick word reuse a single storage read.
    function _next_initialized_tick( IPoolManager manager, WordCache memory cache, int24 tick, int24 tick_spacing, bool lte )
    private view returns ( int24 next, bool initialized )
    {
        unchecked
        {
            int24 compressed  =  TickBitmap.compress( tick, tick_spacing );

            if(  lte  )
            {
                ( int16 word_pos, uint8 bit_pos )  =  TickBitmap.position( compressed );
                uint256 word    =  _word( manager, cache, word_pos );
                uint256 masked  =  word & ( type(uint256).max >> ( uint256(type(uint8).max) - bit_pos ) );

                initialized  =  masked != 0;
                next  =  initialized
                    ? ( compressed - int24(uint24(bit_pos - BitMath.mostSignificantBit( masked ))) ) * tick_spacing
                    : ( compressed - int24(uint24(bit_pos)) ) * tick_spacing;
            }
            else
            {
                int24 next_compressed  =  compressed + 1;
                ( int16 word_pos, uint8 bit_pos )  =  TickBitmap.position( next_compressed );
                uint256 word    =  _word( manager, cache, word_pos );
                uint256 masked  =  word & ~( ( uint256(1) << bit_pos ) - 1 );

                initialized  =  masked != 0;
                next  =  initialized
                    ? ( next_compressed + int24(uint24(BitMath.leastSignificantBit( masked ) - bit_pos)) ) * tick_spacing
                    : ( next_compressed + int24(uint24(type(uint8).max - bit_pos)) ) * tick_spacing;
            }
        }
    }

    function _word( IPoolManager manager, WordCache memory cache, int16 word_pos ) private view returns ( uint256 )
    {
        if(  cache.loaded  &&  cache.word_pos == word_pos  )  return cache.word;

        uint256 word  =  uint256( _extsload( manager, _bitmap_word_slot( cache.bitmap_mapping_slot, word_pos ) ) );

        cache.word_pos  =  word_pos;
        cache.word      =  word;
        cache.loaded    =  true;

        return word;
    }

    function _liquidity_net( IPoolManager manager, bytes32 ticks_mapping_slot, int24 tick ) private view returns ( int128 liquidity_net )
    {
        // TickInfo packs `liquidityNet` in the high 128 bits of its first word; `liquidityGross` occupies the low 128 bits.
        bytes32 first_word  =  _extsload( manager, _tick_info_slot( ticks_mapping_slot, tick ) );
        assembly ("memory-safe") { liquidity_net := sar( 128, first_word ) }
    }


    // ━━━━  STORAGE SLOT DERIVATION (assembly, scratch-only)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _pool_state_slot( PoolId pool_id ) private pure returns ( bytes32 state_slot )
    {
        // pools[poolId] => keccak256( poolId . POOLS_SLOT ). Uses only the two EVM scratch words.
        assembly ("memory-safe")
        {
            mstore( 0x00, pool_id )
            mstore( 0x20, POOLS_SLOT )
            state_slot  :=  keccak256( 0x00, 0x40 )
        }
    }

    function _bitmap_word_slot( bytes32 bitmap_mapping_slot, int16 word_pos ) private pure returns ( bytes32 slot )
    {
        // tickBitmap[word_pos] => keccak256( int256(word_pos) . bitmap_mapping_slot ).
        assembly ("memory-safe")
        {
            mstore( 0x00, word_pos )
            mstore( 0x20, bitmap_mapping_slot )
            slot  :=  keccak256( 0x00, 0x40 )
        }
    }

    function _tick_info_slot( bytes32 ticks_mapping_slot, int24 tick ) private pure returns ( bytes32 slot )
    {
        // ticks[tick] => keccak256( int256(tick) . ticks_mapping_slot ).
        assembly ("memory-safe")
        {
            mstore( 0x00, tick )
            mstore( 0x20, ticks_mapping_slot )
            slot  :=  keccak256( 0x00, 0x40 )
        }
    }


    // ━━━━  RAW EXTSLOAD (assembly, scratch-only)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // Single-slot `extsload` without Solidity ABI machinery. Calldata `selector(4) . slot(32)` and the 32-byte return both
    // live entirely in the two scratch words (0x00-0x3f); the free-memory pointer at 0x40 is never touched.
    function _extsload( IPoolManager manager, bytes32 slot ) private view returns ( bytes32 value )
    {
        assembly ("memory-safe")
        {
            mstore( 0x00, EXTSLOAD_SELECTOR )     // right-aligned: selector occupies bytes 0x1c-0x1f.
            mstore( 0x20, slot )

            // *SECURITY*  -  A failed staticcall (bad PoolManager) must not be read as a zero slot; bubble the revert.
            if iszero( staticcall( gas(), manager, 0x1c, 0x24, 0x00, 0x20 ) )
            {
                returndatacopy( 0x00, 0x00, returndatasize() )
                revert( 0x00, returndatasize() )
            }

            value  :=  mload( 0x00 )
        }
    }
}

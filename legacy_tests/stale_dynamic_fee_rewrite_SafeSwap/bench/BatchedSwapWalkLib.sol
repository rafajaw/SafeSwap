// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { TickBitmap } from "@UniswapV4Core/libraries/TickBitmap.sol";
import { BitMath } from "@UniswapV4Core/libraries/BitMath.sol";
import { LiquidityMath } from "@UniswapV4Core/libraries/LiquidityMath.sol";


interface IExt {
    function extsload( bytes32 slot ) external view returns ( bytes32 );
    function extsload( bytes32 start_slot, uint256 n_slots ) external view returns ( bytes32[] memory );
    function extsload( bytes32[] calldata slots ) external view returns ( bytes32[] memory );
}


/**
 * @title BatchedSwapWalkLib
 * @notice Read-optimized tick-walk (upward / oneForZero only) that isolates the simulation's STATE I/O cost.
 *
 * @dev Optimizations vs the StateLibrary-based walk:
 *      - storage slots derived in inline assembly (no per-read Solidity slot helpers);
 *      - the tick bitmap word is read once per word (not once per tick);
 *      - all initialized-tick `liquidityNet` slots in a word are fetched in a SINGLE `extsload(bytes32[])` batch;
 *      - slot0 + liquidity are read in one `extsload(start, n)` call.
 *      No AMM math — this measures the irreducible read/call floor, not the swap-path arithmetic.
 */
library BatchedSwapWalkLib {
    using PoolIdLibrary for PoolKey;

    uint256 constant POOLS_SLOT         =  6;
    uint256 constant TICKS_OFFSET       =  4;
    uint256 constant TICK_BITMAP_OFFSET =  5;

    function walk_only_batched( IPoolManager manager, PoolKey memory key, uint256 max_crossings )
    internal view returns ( uint256 ticks_crossed )
    {
        PoolId pool_id   =  key.toId( );
        int24 spacing    =  key.tickSpacing;
        bytes32 state    =  _state_slot( pool_id );

        // slot0 (for current tick) and liquidity in one batched read: [slot0, feeGrowthGlobal0, feeGrowthGlobal1, liquidity].
        bytes32[] memory head  =  IExt(address(manager)).extsload( bytes32(state), 4 );
        uint128 liquidity  =  uint128(uint256( head[ 3 ] ));   // low 128 bits of the liquidity word (truncating cast).
        int24 tick;
        assembly ("memory-safe")
        {
            tick  :=  signextend( 2, shr(160, mload(add(head, 32))) )
        }

        unchecked
        {
            while(  ticks_crossed < max_crossings  )
            {
                int24 compressed  =  TickBitmap.compress( tick, spacing ) + 1;
                ( int16 word_pos, uint8 bit_pos )  =  TickBitmap.position( compressed );

                uint256 word    =  uint256(IExt(address(manager)).extsload( _bitmap_slot( state, word_pos ) ));
                uint256 masked  =  word & ~( ( uint256(1) << bit_pos ) - 1 );

                if(  masked == 0  )
                {
                    // No initialized tick in the rest of this word — jump to the word's top boundary and continue.
                    tick  =  int24( ( int256(compressed) + int256(uint256(255 - bit_pos)) ) * int256(spacing) );
                    continue;
                }

                uint256 available   =  _popcount( masked );
                uint256 remaining   =  max_crossings - ticks_crossed;
                uint256 batch_size  =  available < remaining ? available : remaining;

                bytes32[] memory slots  =  new bytes32[]( batch_size );
                int24[] memory ticks    =  new int24[]( batch_size );
                uint256 m  =  masked;
                for(  uint256 i = 0  ;  i < batch_size  ;  i = i + 1  )
                {
                    uint8 lsb  =  BitMath.leastSignificantBit( m );
                    int24 t    =  int24( ( int256(word_pos) * 256 + int256(uint256(lsb)) ) * int256(spacing) );
                    slots[ i ]  =  _tick_info_slot( state, t );
                    ticks[ i ]  =  t;
                    m  =  m & ( m - 1 );
                }

                bytes32[] memory values  =  IExt(address(manager)).extsload( slots );
                for(  uint256 i = 0  ;  i < batch_size  ;  i = i + 1  )
                {
                    int128 liquidity_net;
                    bytes32 v  =  values[ i ];
                    assembly ("memory-safe") { liquidity_net := sar( 128, v ) }

                    liquidity      =  LiquidityMath.addDelta( liquidity, liquidity_net );
                    ticks_crossed  =  ticks_crossed + 1;
                    tick           =  ticks[ i ];
                }

                if(  batch_size < available  )  break;   // reached max_crossings mid-word.
            }
        }
    }

    function _popcount( uint256 x ) private pure returns ( uint256 count )
    {
        unchecked
        {
            while(  x != 0  )  { x  =  x & ( x - 1 );  count  =  count + 1; }
        }
    }

    function _state_slot( PoolId pool_id ) private pure returns ( bytes32 s )
    {
        assembly ("memory-safe")
        {
            mstore( 0, pool_id )
            mstore( 0x20, POOLS_SLOT )
            s  :=  keccak256( 0, 0x40 )
        }
    }

    function _bitmap_slot( bytes32 state, int16 word_pos ) private pure returns ( bytes32 s )
    {
        assembly ("memory-safe")
        {
            mstore( 0, word_pos )
            mstore( 0x20, add(state, TICK_BITMAP_OFFSET) )
            s  :=  keccak256( 0, 0x40 )
        }
    }

    function _tick_info_slot( bytes32 state, int24 tick ) private pure returns ( bytes32 s )
    {
        assembly ("memory-safe")
        {
            mstore( 0, tick )
            mstore( 0x20, add(state, TICKS_OFFSET) )
            s  :=  keccak256( 0, 0x40 )
        }
    }
}

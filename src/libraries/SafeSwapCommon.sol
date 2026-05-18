// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/integrations/BondRouteProtected.sol";
import "@SafeSwap/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { FullMath } from "@UniswapV4Core/libraries/FullMath.sol";
import { FixedPoint96 } from "@UniswapV4Core/libraries/FixedPoint96.sol";


// ━━━━  DATA STRUCTURES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice Uniswap V4 pool configuration shared by all SafeSwap actions.
 * @param fee Pool LP fee in Uniswap V4 units. Dynamic-fee pools are not supported.
 * @param tick_spacing Pool tick spacing.
 */
struct PoolInfo {
    uint24 fee;
    int24 tick_spacing;
}


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error SlippageExceeded( uint256 amount_received, uint256 minimum_required );
error UnsupportedFeeTier( uint24 fee );


/**
 * @title SafeSwapCommon
 * @notice Shared utilities for SafeSwap action libraries
 * @dev Contains constants, pool key building, stake calculation, protocol fee math, and settlement logic
 */
library SafeSwapCommon {
    using FundingsLib for BondContext;

    // ━━━━  CONSTANTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // EIP-712 type hashes shared across action libs.
    bytes32 constant POOL_INFO_TYPEHASH     =  keccak256( "PoolInfo(uint24 fee,int24 tick_spacing)" );
    bytes32 constant TOKEN_AMOUNT_TYPEHASH  =  keccak256( "TokenAmount(address token,uint256 amount)" );


    // ━━━━  EIP-712 HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function hash_pool_info( PoolInfo memory pool_info ) internal pure returns ( bytes32 result )
    {
        bytes32 typehash  =  POOL_INFO_TYPEHASH;

        assembly ("memory-safe")
        {
            let saved_free_memory_pointer  :=  mload( 0x40 )

            // EIP-712 encodes signed integers sign-extended into a full 32-byte word.
            // signextend( 2, x )  treats the low 3 bytes (= 24 bits = int24) of x as a signed value
            // and fills the upper 29 bytes with the sign bit, so a negative tick_spacing hashes
            // with 0xFF padding instead of 0x00.
            let tick_spacing_signed_word  :=  signextend( 2, mload( add( pool_info, 0x20 ) ) )

            // Lay out  typehash || fee || tick_spacing  across the 96 bytes spanning the scratch
            // space (0x00-0x3f) and the free-memory-pointer slot (0x40-0x5f). This leaves no
            // garbage above the free memory pointer.
            mstore( 0x00, typehash )
            mstore( 0x20, mload( pool_info ) )
            mstore( 0x40, tick_spacing_signed_word )

            result  :=  keccak256( 0x00, 0x60 )

            mstore( 0x40, saved_free_memory_pointer )    // *SECURITY*  -  Restore the free memory pointer we just clobbered.
        }
    }

    function hash_token_amount( TokenAmount memory token_amount ) internal pure returns ( bytes32 result )
    {
        bytes32 typehash  =  TOKEN_AMOUNT_TYPEHASH;

        assembly ("memory-safe")
        {
            let saved_free_memory_pointer  :=  mload( 0x40 )

            // Lay out  typehash || token || amount  across the 96 bytes spanning the scratch
            // space (0x00-0x3f) and the free-memory-pointer slot (0x40-0x5f). This leaves no
            // garbage above the free memory pointer.
            // The token field is a memory-stored address, already right-aligned in its 32-byte slot.
            mstore( 0x00, typehash )
            mstore( 0x20, mload( token_amount ) )                  // token
            mstore( 0x40, mload( add( token_amount, 0x20 ) ) )     // amount

            result  :=  keccak256( 0x00, 0x60 )

            mstore( 0x40, saved_free_memory_pointer )    // *SECURITY*  -  Restore the free memory pointer we just clobbered.
        }
    }


    // ━━━━  FUNDING PAIR HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Sort a two-token funding pair into Uniswap V4 pool currency order.
     * @dev Reverts with `TOKENS_MUST_BE_DIFFERENT` if both fundings reference the same token.
     */
    function sort_funding_pair( TokenAmount memory funding_a, TokenAmount memory funding_b )
    internal pure returns ( IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1 )
    {
        if(  address(funding_a.token) == address(funding_b.token)  )  revert( TOKENS_MUST_BE_DIFFERENT );

        ( token0, amount0, token1, amount1 )  =  address(funding_a.token) < address(funding_b.token)
            ? ( funding_a.token, funding_a.amount, funding_b.token, funding_b.amount )
            : ( funding_b.token, funding_b.amount, funding_a.token, funding_a.amount );
    }


    // ━━━━  POOL KEY BUILDER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function build_pool_key( IERC20 token_in, IERC20 token_out, uint24 fee, int24 tick_spacing, address hook_address )
    internal pure returns ( PoolKey memory )
    {
        ( Currency currency0, Currency currency1 )  =  address(token_in) < address(token_out)
            ? ( Currency.wrap(address(token_in)), Currency.wrap(address(token_out)) )
            : ( Currency.wrap(address(token_out)), Currency.wrap(address(token_in)) );

        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tick_spacing,
            hooks: IHooks(hook_address)
        });
    }


    // ━━━━  STAKE CALCULATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function calculate_swap_stake( TokenAmount memory funding ) internal pure returns ( TokenAmount memory )
    {
        return TokenAmount({ token: funding.token, amount: funding.amount * SWAP_STAKE_PERCENTAGE / 100 });
    }

    // *SECURITY*  -  Stake must reflect the total committed value across BOTH sides of a liquidity bond. Measuring
    //                only one side opens a dust attack: (amount0 = 1 wei, amount1 = 1e18) would yield zero stake while
    //                committing real value. We normalize amount1 into token0 units at the pool's current price (slot0)
    //                so both legs can be summed in the same frame of reference, then stake a percentage of the total.
    //                Caveat: on very thin pools an attacker can shift slot0 cheaply, so the per-bond stake reflects
    //                a manipulated price. This is bounded by SafeSwap's own 1% swap stake on the manipulation swap.
    function calculate_normalized_liquidity_stake( uint160 sqrtPriceX96, IERC20 token0, uint256 amount0, uint256 amount1 )
    internal pure returns ( TokenAmount memory )
    {
        // Convert amount1 into token0 units at current pool price.
        // Price (token1 per token0)  =  sqrtPriceX96^2 / 2^192
        // So  amount0_equivalent     =  amount1 * 2^192 / sqrtPriceX96^2
        // Performed as two mulDiv steps to avoid uint256 overflow on sqrtPriceX96^2 at high prices.
        uint256 amount1_in_token0_units  =  0;
        if(  amount1 > 0  )
        {
            uint256 intermediate     =  FullMath.mulDiv( amount1, FixedPoint96.Q96, sqrtPriceX96 );
            amount1_in_token0_units  =  FullMath.mulDiv( intermediate, FixedPoint96.Q96, sqrtPriceX96 );
        }

        uint256 total_in_token0  =  amount0 + amount1_in_token0_units;

        return TokenAmount({ token: token0, amount: total_in_token0 * LIQUIDITY_STAKE_PERCENTAGE / 100 });
    }

    // ━━━━  PROTOCOL FEE CALCULATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function calculate_protocol_fee( uint256 amount_out, uint24 pool_fee ) internal pure returns ( uint256 protocol_fee, uint256 user_amount )
    {
        uint256 effective_fee_rate  =  pool_fee < MIN_PROTOCOL_FEE_RATE  ?  MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        protocol_fee                =  amount_out * effective_fee_rate / PROTOCOL_FEE_DIVISOR;
        user_amount                 =  amount_out - protocol_fee;
    }


    // ━━━━  SETTLEMENT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // *NATIVE*  -  V4 PoolManager has no receive(); native ETH cannot be transferred to it separately and then settled.
    //              It must arrive bundled with `settle{value:}()`. So for native we pull ETH to the hook (which has
    //              receive()) and forward via msg.value on settle. For ERC20 we keep the direct user→PM path.
    function settle_input( IPoolManager pool_manager, BondContext memory context, IERC20 token, uint256 amount ) internal
    {
        if(  amount == 0  )  return;

        pool_manager.sync( Currency.wrap( address(token) ) );

        if(  address(token) == address(0)  )
        {
            context.pull( token, amount );
            pool_manager.settle{ value: amount }( );
        }
        else
        {
            context.send( token, amount, address(pool_manager) );
            pool_manager.settle( );
        }
    }

    function settle_and_take(
        IPoolManager pool_manager,
        BondContext memory context,
        IERC20 token_in,
        IERC20 token_out,
        uint256 amount_in,
        uint256 user_output,
        uint256 protocol_fee,
        address hook_address
    ) internal
    {
        Currency currency_out  =  Currency.wrap( address(token_out) );

        settle_input( pool_manager, context, token_in, amount_in );

        pool_manager.take( currency_out, context.user, user_output );
        pool_manager.take( currency_out, hook_address, protocol_fee );
    }
}

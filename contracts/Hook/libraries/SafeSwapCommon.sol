// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
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
error OneSidedDepositMismatch( address expected_token, uint256 minimum_required );
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


    // ━━━━  TOKEN AMOUNT HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Sort a two-element TokenAmount pair into Uniswap V4 pool currency order.
     * @dev Reverts with `TOKENS_MUST_BE_DIFFERENT` if both entries reference the same token.
     */
    function sort_token_amount_pair( TokenAmount memory pair_a, TokenAmount memory pair_b )
    internal pure returns ( IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1 )
    {
        if(  address(pair_a.token) == address(pair_b.token)  )  revert( TOKENS_MUST_BE_DIFFERENT );

        ( token0, amount0, token1, amount1 )  =  address(pair_a.token) < address(pair_b.token)
            ? ( pair_a.token, pair_a.amount, pair_b.token, pair_b.amount )
            : ( pair_b.token, pair_b.amount, pair_a.token, pair_a.amount );
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
        uint256 stake_amount  =  funding.amount * SWAP_STAKE_PERCENTAGE / 100;

        // *SECURITY*  -  Bump dust to 1 wei. For 0-decimal / low-decimal tokens where 1 wei = 1 unit = real value
        //                (gaming ERC20s, fractional RWAs), this turns a free speculative bond into a meaningful stake.
        if(  stake_amount == 0  )  stake_amount  =  1;

        return TokenAmount({ token: funding.token, amount: stake_amount });
    }

    // *SECURITY*  -  Stake must reflect the total committed value across BOTH sides of a liquidity bond. Measuring
    //                only one side opens a dust attack: (amount0 = 1 wei, amount1 = 1e18) would yield zero stake while
    //                committing real value. By default we normalize amount1 into token0 units at the pool's current
    //                price (slot0). If the user signals token1 as the preferred stake token, we normalize amount0 into
    //                token1 instead. Any other preference is ignored and falls back to token0.
    //                Caveat: on very thin pools an attacker can shift slot0 cheaply, so the per-bond stake reflects
    //                a manipulated price. This is bounded by SafeSwap's own 1% swap stake on the manipulation swap.
    function calculate_normalized_liquidity_stake(
        uint160 sqrtPriceX96,
        IERC20 token0,
        IERC20 token1,
        uint256 amount0,
        uint256 amount1,
        IERC20 preferred_stake_token
    )
    internal pure returns ( TokenAmount memory )
    {
        bool is_token1_preferred  =  address(preferred_stake_token) == address(token1);
        IERC20 stake_token        =  is_token1_preferred  ?  token1  :  token0;
        uint256 normalized_total  =  is_token1_preferred
            ?  amount1 + _convert_token0_to_token1_units( sqrtPriceX96, amount0 )
            :  amount0 + _convert_token1_to_token0_units( sqrtPriceX96, amount1 );

        uint256 stake_amount  =  normalized_total * LIQUIDITY_STAKE_PERCENTAGE / 100;

        // *SECURITY*  -  Bump dust to 1 wei. For 0-decimal / low-decimal tokens where 1 wei = 1 unit = real value
        //                (gaming ERC20s, fractional RWAs), this turns a free speculative bond into a meaningful stake.
        if(  stake_amount == 0  )  stake_amount  =  1;

        return TokenAmount({ token: stake_token, amount: stake_amount });
    }

    function _convert_token1_to_token0_units( uint160 sqrtPriceX96, uint256 amount1 ) private pure returns ( uint256 amount1_in_token0_units )
    {
        if(  amount1 == 0  )  return 0;

        // Price (token1 per token0)  =  sqrtPriceX96^2 / 2^192.
        // So amount1 in token0 units =  amount1 * 2^192 / sqrtPriceX96^2.
        // Performed as two mulDiv steps to avoid uint256 overflow on sqrtPriceX96^2 at high prices.
        uint256 intermediate      =  FullMath.mulDiv( amount1, FixedPoint96.Q96, sqrtPriceX96 );
        amount1_in_token0_units   =  FullMath.mulDiv( intermediate, FixedPoint96.Q96, sqrtPriceX96 );
    }

    function _convert_token0_to_token1_units( uint160 sqrtPriceX96, uint256 amount0 ) private pure returns ( uint256 amount0_in_token1_units )
    {
        if(  amount0 == 0  )  return 0;

        // Price (token1 per token0)  =  sqrtPriceX96^2 / 2^192.
        // So amount0 in token1 units =  amount0 * sqrtPriceX96^2 / 2^192.
        // Performed as two mulDiv steps to avoid uint256 overflow on sqrtPriceX96^2 at high prices.
        uint256 intermediate      =  FullMath.mulDiv( amount0, sqrtPriceX96, FixedPoint96.Q96 );
        amount0_in_token1_units   =  FullMath.mulDiv( intermediate, sqrtPriceX96, FixedPoint96.Q96 );
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

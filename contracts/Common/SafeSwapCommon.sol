// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapCommon/Definitions.sol";
import "@SafeSwapCommon/Types.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { FullMath } from "@UniswapV4Core/libraries/FullMath.sol";
import { FixedPoint96 } from "@UniswapV4Core/libraries/FixedPoint96.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error SlippageExceeded( uint256 amount_received, uint256 minimum_required );
error MaximumInputExceeded( uint256 required_input, uint256 maximum_required );
error OneSidedDepositMismatch( address expected_token, uint256 minimum_required );
error RepricingFeeExceedsV4Limit( uint256 total_fee_pips, uint256 maximum_fee_pips );


/**
 * @title SafeSwapCommon
 * @notice Shared utilities for SafeSwap action libraries.
 * @dev Constants, pool key building, stake calculation, protocol fee math, repricing-fee math, and settlement logic.
 */
library SafeSwapCommon {
    using FundingsLib for BondContext;

    // EIP-712 type hashes shared across action libs.
    bytes32 constant POOL_INFO_TYPEHASH     =  keccak256( "PoolInfo(uint16 base_fee_bps,uint8 rebate_percent,int24 tick_spacing)" );
    bytes32 constant TOKEN_AMOUNT_TYPEHASH  =  keccak256( "TokenAmount(address token,uint256 amount)" );


    // ━━━━  EIP-712 HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // EIP-712 encodes each atomic member into a full 32-byte word: uint8 zero-padded, int24 sign-extended. `abi.encode`
    // produces exactly that layout, so we hash it directly rather than hand-rolling assembly for this off-chain signing path.
    function hash_pool_info( PoolInfo memory pool_info ) internal pure returns ( bytes32 result )
    {
        result  =  keccak256( abi.encode(
            POOL_INFO_TYPEHASH,
            pool_info.base_fee_bps,
            pool_info.rebate_percent,
            pool_info.tick_spacing
        ));
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


    // ━━━━  POOL CONFIG HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Convert a base LP fee in basis points into Uniswap V4 fee units (pips).
     * @dev 100 v4 pips = 1 bps. E.g. 30 bps (0.3%) → 3000 pips.
     */
    function compute_base_fee_pips( uint16 base_fee_bps ) internal pure returns ( uint24 )
    {
        return uint24(base_fee_bps) * uint24(PIPS_PER_BPS);
    }


    // ━━━━  TOKEN AMOUNT HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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


    // ━━━━  POOL KEY BUILDER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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


    // ━━━━  PROTOCOL FEE CALCULATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function calculate_protocol_fee( uint256 amount_out, uint24 pool_fee ) internal pure returns ( uint256 protocol_fee, uint256 user_amount )
    {
        uint256 effective_fee_rate  =  pool_fee < MIN_PROTOCOL_FEE_RATE  ?  MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        protocol_fee                =  amount_out * effective_fee_rate / PROTOCOL_FEE_DIVISOR;
        user_amount                 =  amount_out - protocol_fee;
    }


    // ━━━━  REPRICING FEE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Compute the total swap fee (in Uniswap V4 pips) from a swap's estimated repricing surplus.
     * @param amount_in Input the swap pays (estimated at the base fee).
     * @param amount_out Output the swap receives (estimated at the base fee).
     * @param sqrt_price_after_x96 Estimated post-swap sqrt price — the terminal price the output is valued at.
     * @param zero_for_one Swap direction (token0 → token1 when true).
     * @param capture_percent LP capture share in percent (0..90): the share of SURPLUS paid to LPs.
     * @param base_fee_pips Base LP fee in v4 pips.
     * @return swap_fee_pips Base fee plus the repricing fee, in v4 pips, to be returned as the dynamic-fee override.
     *
     * @dev `surplus = (output valued at the post-swap price) − input`, in input-token units (clamped at 0). The repricing
     *      fee is `capture% × surplus`, expressed as a flat rate over the input: `capture% × surplus / amount_in × 1e6`.
     *      Direction-neutral. If enforcing the configured capture would require a 100%+ V4 fee, the swap reverts instead of
     *      silently under-capturing LPs. This is NOT `capture% × displacement`: that over-captures by ~2×.
     */
    function compute_repricing_fee_pips(
        uint256 amount_in,
        uint256 amount_out,
        uint160 sqrt_price_after_x96,
        bool zero_for_one,
        uint8 capture_percent,
        uint24 base_fee_pips
    ) internal pure returns ( uint24 swap_fee_pips )
    {
        uint256 repricing_pips  =  _repricing_fee_pips( amount_in, amount_out, sqrt_price_after_x96, zero_for_one, capture_percent );
        uint256 total_pips  =  uint256(base_fee_pips) + repricing_pips;

        if(  total_pips >= LPFeeLibrary.MAX_LP_FEE  )
        {
            revert RepricingFeeExceedsV4Limit({ total_fee_pips: total_pips, maximum_fee_pips: LPFeeLibrary.MAX_LP_FEE - 1 });
        }

        swap_fee_pips  =  uint24(total_pips);
    }

    /**
     * @notice Split the Uniswap V4 swap-amount convention into `(amount_in, amount_out)` given the simulator's counterpart.
     * @dev `amount_specified < 0` is exact-input (amount_in = |specified|, amount_out = counterpart); `> 0` is exact-output.
     */
    function compute_swap_amounts( int256 amount_specified, uint256 counterpart ) internal pure returns ( uint256 amount_in, uint256 amount_out )
    {
        if(  amount_specified < 0  )
        {
            amount_in   =  uint256(-amount_specified);
            amount_out  =  counterpart;
        }
        else
        {
            amount_out  =  uint256(amount_specified);
            amount_in   =  counterpart;
        }
    }

    // Repricing fee in v4 pips = `capture% × surplus / amount_in × 1e6`, where surplus = output valued at the post-swap price
    // minus the input, in input-token units (0 if not positive). FullMath keeps the valuation and pip conversion exact.
    function _repricing_fee_pips( uint256 amount_in, uint256 amount_out, uint160 sqrt_price_after_x96, bool zero_for_one, uint8 capture_percent )
    private pure returns ( uint256 )
    {
        if(  amount_in == 0  ||  capture_percent == 0  )  return 0;

        uint256 output_in_input_units  =  _value_output_in_input( amount_out, sqrt_price_after_x96, zero_for_one );
        if(  output_in_input_units <= amount_in  )  return 0;

        uint256 surplus  =  output_in_input_units - amount_in;

        // capture% × surplus / amount_in × 1e6  =  surplus × (capture% × 1e6/100) / amount_in.
        return FullMath.mulDiv( surplus, uint256(capture_percent) * PIPS_PER_PERCENT, amount_in );
    }

    // Value `amount_out` (the output token) in input-token units at the post-swap price P = (sqrtP / 2^96)^2 (token1/token0):
    //   zeroForOne (out = token1): value in token0 = amount_out / P = amount_out · 2^192 / sqrtP^2
    //   oneForZero (out = token0): value in token1 = amount_out · P = amount_out · sqrtP^2 / 2^192
    function _value_output_in_input( uint256 amount_out, uint160 sqrt_price_after_x96, bool zero_for_one )
    private pure returns ( uint256 )
    {
        uint256 sqrt_price  =  uint256(sqrt_price_after_x96);

        if(  zero_for_one  )
        {
            uint256 term  =  FullMath.mulDiv( amount_out, FixedPoint96.Q96, sqrt_price );
            return          FullMath.mulDiv( term, FixedPoint96.Q96, sqrt_price );
        }

        uint256 scaled  =  FullMath.mulDiv( amount_out, sqrt_price, FixedPoint96.Q96 );
        return              FullMath.mulDiv( scaled, sqrt_price, FixedPoint96.Q96 );
    }


    // ━━━━  SETTLEMENT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // *NATIVE*  -  V4 PoolManager has no receive(); native ETH cannot be transferred to it separately and then settled.
    //              It must arrive bundled with `settle{value:}()`. So for native we pull ETH to the router (which has
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

    /**
     * @notice Settle the swap input, send the user their net output, and take the protocol fee.
     * @param fee_recipient SafeSwap router address that receives the protocol fee (held for the treasury).
     */
    function settle_and_take(
        IPoolManager pool_manager,
        BondContext memory context,
        IERC20 token_in,
        IERC20 token_out,
        uint256 amount_in,
        uint256 user_output,
        uint256 protocol_fee,
        address fee_recipient
    ) internal
    {
        Currency currency_out  =  Currency.wrap( address(token_out) );

        settle_input( pool_manager, context, token_in, amount_in );

        pool_manager.take( currency_out, context.user, user_output );
        pool_manager.take( currency_out, fee_recipient, protocol_fee );
    }
}

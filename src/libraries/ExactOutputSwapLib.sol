// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/integrations/BondRouteProtected.sol";
import "@SafeSwap/libraries/SafeSwapCommon.sol";
import "@SafeSwap/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice Exact-output swap parameters signed by the user.
 * @param token_out Token the user receives.
 * @param amount_out Exact net output sent to the user after SafeSwap protocol fee.
 * @param pool_info Target Uniswap V4 pool configuration.
 *
 * @dev Input token and maximum input amount come from the bond funding, not from this struct.
 */
struct ExactOutputSwapParams {
    IERC20 token_out;
    uint256 amount_out;
    PoolInfo pool_info;
}


/**
 * @title ExactOutputSwapLib
 * @notice Library for exact output swap operations via SafeSwap
 * @dev Contains constraint calculation and execution logic for swaps where output amount is specified
 */
library ExactOutputSwapLib {
    using FundingsLib for BondContext;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactOutputSwap call)"
        "ExactOutputSwap(address token_out,uint256 amount_out,PoolInfo pool_info)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "ExactOutputSwap(address token_out,uint256 amount_out,PoolInfo pool_info)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  217;

    function get_signing_info( ExactOutputSwapParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            EIP712_TYPEHASH,
            address(params.token_out),
            params.amount_out,
            SafeSwapCommon.hash_pool_info( params.pool_info )
        ));

        token_amount_offset  =  EIP712_TOKEN_AMOUNT_OFFSET;
    }


    // ━━━━  GET CONSTRAINTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function get_constraints( ExactOutputSwapParams memory params, TokenAmount[] memory preferred_fundings )
    internal pure returns ( BondConstraints memory constraints )
    {
        if(  params.pool_info.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG  )               revert UnsupportedFeeTier({ fee: params.pool_info.fee });
        if(  preferred_fundings.length != 1  )                                      revert( SWAPS_REQUIRE_EXACTLY_ONE_FUNDING );
        if(  address(preferred_fundings[0].token) == address(params.token_out)  )   revert( TOKENS_MUST_BE_DIFFERENT );

        constraints.min_stake                       =  SafeSwapCommon.calculate_swap_stake( preferred_fundings[ 0 ] );
        constraints.min_fundings                    =  preferred_fundings;
        constraints.min_execution_delay_in_blocks   =  MIN_EXECUTION_DELAY_IN_BLOCKS;
        constraints.max_execution_delay_in_seconds  =  MAX_EXECUTION_DELAY;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute( BondContext memory context, ExactOutputSwapParams memory params, IPoolManager pool_manager, address hook_address ) internal
    {
        // *NOTE*  -  Token in and max amount come from fundings. Multi-funding: pick best at execution time.
        IERC20 token_in            =  context.fundings[ 0 ].token;
        uint256 maximum_amount_in  =  context.fundings[ 0 ].amount;

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key(
            token_in,
            params.token_out,
            params.pool_info.fee,
            params.pool_info.tick_spacing,
            hook_address
        );

        // ━━━━  GROSS-UP MATH  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        //
        // The user wants to receive exactly `target_user_output` tokens, NET of the protocol fee.
        // The pool itself doesn't know about our fee; it produces whatever we ask for via `amountSpecified`.
        // So we instruct the pool to produce a slightly larger `grossed_up_pool_output`, then split it on settlement:
        // the user gets exactly `target_user_output`, the hook keeps `grossed_up_pool_output - target_user_output`.
        //
        //     user_output       =  pool_output * ( DIVISOR - effective_fee_rate ) / DIVISOR
        //     target_user_output  =  grossed_up_pool_output * ( DIVISOR - effective_fee_rate ) / DIVISOR
        //     grossed_up_pool_output  =  target_user_output * DIVISOR / ( DIVISOR - effective_fee_rate )
        //

        uint256 target_user_output      =  params.amount_out;
        uint256 effective_fee_rate      =  params.pool_info.fee < MIN_PROTOCOL_FEE_RATE
                                            ? MIN_PROTOCOL_FEE_RATE
                                            : params.pool_info.fee;
        uint256 fee_complement          =  PROTOCOL_FEE_DIVISOR - effective_fee_rate;
        // Truncating division: rounding dust on the gross-up is ≤1 wei per swap.
        uint256 grossed_up_pool_output  =  target_user_output * PROTOCOL_FEE_DIVISOR / fee_complement;

        bool zero_for_one  =  address(token_in) < address(params.token_out);

        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: zero_for_one,
            amountSpecified: int256(grossed_up_pool_output),
            sqrtPriceLimitX96: zero_for_one ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta  =  pool_manager.swap( pool_key, swap_params, "" );

        // *NOTE*  -  Input delta is ALWAYS negative (we owe pool). Negate to get positive amount for calculation.
        uint256 amount_in  =  zero_for_one ? uint256(-int256(delta.amount0( ))) : uint256(-int256(delta.amount1( )));

        if(  amount_in > maximum_amount_in  )  revert SlippageExceeded({ amount_received: amount_in, minimum_required: maximum_amount_in });

        uint256 user_output   =  target_user_output;
        uint256 protocol_fee  =  grossed_up_pool_output - target_user_output;

        SafeSwapCommon.settle_and_take(
            pool_manager,
            context,
            token_in,
            params.token_out,
            amount_in,
            user_output,
            protocol_fee,
            hook_address
        );
    }
}

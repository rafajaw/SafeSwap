// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapCommon/SafeSwapCommon.sol";
import "@SafeSwapCommon/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice Exact-output swap parameters signed by the user.
 * @param token_out Token the user receives.
 * @param exact_output_amount Exact net output sent to the user after the SafeSwap protocol fee.
 * @param pool_info Target SafeSwap pool configuration (base fee, capture, tick spacing).
 *
 * @dev Input token and maximum input amount come from the bond funding, not from this struct. The LP fee (base + repricing)
 *      is charged on the input by the pool's dynamic-fee override; it (and the protocol-fee gross-up) count against the
 *      committed maximum input.
 */
struct ExactOutputSwapParams {
    IERC20 token_out;
    uint256 exact_output_amount;
    PoolInfo pool_info;
}


/**
 * @title ExactOutputSwapLib
 * @notice Exact-output swaps via SafeSwap on dynamic-fee pools. The pool produces a slightly grossed-up output so the user
 *         receives `exact_output_amount` net of the SafeSwap protocol fee; the LP fee is taken from the input by the hook.
 */
library ExactOutputSwapLib {
    using FundingsLib for BondContext;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactOutputSwap call)"
        "ExactOutputSwap(address token_out,uint256 exact_output_amount,PoolInfo pool_info)"
        "PoolInfo(uint16 base_fee_bps,uint8 rebate_percent,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "ExactOutputSwap(address token_out,uint256 exact_output_amount,PoolInfo pool_info)"
        "PoolInfo(uint16 base_fee_bps,uint8 rebate_percent,int24 tick_spacing)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  256;

    function get_signing_info( ExactOutputSwapParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            EIP712_TYPEHASH,
            address(params.token_out),
            params.exact_output_amount,
            SafeSwapCommon.hash_pool_info( params.pool_info )
        ));

        token_amount_offset  =  EIP712_TOKEN_AMOUNT_OFFSET;
    }


    // ━━━━  GET CONSTRAINTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function get_constraints( ExactOutputSwapParams memory params, TokenAmount[] memory preferred_fundings )
    internal pure returns ( BondConstraints memory constraints )
    {
        if(  preferred_fundings.length != 1  )                                       revert( SWAPS_REQUIRE_EXACTLY_ONE_FUNDING );
        if(  address(preferred_fundings[0].token) == address(params.token_out)  )    revert( TOKENS_MUST_BE_DIFFERENT );

        constraints.min_stake                       =  SafeSwapCommon.calculate_swap_stake( preferred_fundings[ 0 ] );
        constraints.min_fundings                    =  preferred_fundings;
        constraints.min_execution_delay_in_blocks   =  MIN_BOND_EXECUTION_DELAY_IN_BLOCKS;
        constraints.min_execution_delay_in_seconds  =  MIN_BOND_EXECUTION_DELAY_IN_SECONDS;
        constraints.max_execution_delay_in_seconds  =  MAX_BOND_EXECUTION_DELAY_IN_SECONDS;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute( BondContext memory context, ExactOutputSwapParams memory params, IPoolManager pool_manager, address hook, address router ) internal
    {
        // *NOTE*  -  Token in and max amount come from fundings. Multi-funding: pick best at execution time.
        IERC20 token_in            =  context.fundings[ 0 ].token;
        uint256 maximum_amount_in  =  context.fundings[ 0 ].amount;

        // Gross up the requested output so the user nets `exact_output_amount` after the SafeSwap protocol fee. The LP fee
        // (base + repricing) is taken separately from the input by the pool, so it is not part of this gross-up.
        uint256 effective_fee_rate      =  SafeSwapCommon.compute_base_fee_pips( params.pool_info.base_fee_bps ) < MIN_PROTOCOL_FEE_RATE
                                            ? MIN_PROTOCOL_FEE_RATE
                                            : SafeSwapCommon.compute_base_fee_pips( params.pool_info.base_fee_bps );
        uint256 fee_complement          =  PROTOCOL_FEE_DIVISOR - effective_fee_rate;
        // Truncating division: rounding dust on the gross-up is ≤1 wei per swap.
        uint256 grossed_up_pool_output  =  params.exact_output_amount * PROTOCOL_FEE_DIVISOR / fee_complement;

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key(
            token_in,
            params.token_out,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            params.pool_info.tick_spacing,
            hook
        );

        bool zero_for_one  =  address(token_in) < address(params.token_out);

        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: zero_for_one,
            amountSpecified: int256(grossed_up_pool_output),
            sqrtPriceLimitX96: zero_for_one ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta  =  pool_manager.swap( pool_key, swap_params, "" );

        // *NOTE*  -  Input delta is negative (we owe the pool), and already includes the LP fee the hook charged on the input.
        uint256 amount_in  =  zero_for_one ? uint256(-int256(delta.amount0( ))) : uint256(-int256(delta.amount1( )));

        if(  amount_in > maximum_amount_in  )  revert MaximumInputExceeded({ required_input: amount_in, maximum_required: maximum_amount_in });

        uint256 user_output   =  params.exact_output_amount;
        uint256 protocol_fee  =  grossed_up_pool_output - params.exact_output_amount;

        SafeSwapCommon.settle_and_take( pool_manager, context, token_in, params.token_out, amount_in, user_output, protocol_fee, router );
    }
}

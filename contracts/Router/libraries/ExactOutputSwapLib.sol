// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapRouter/libraries/SafeSwapCommon.sol";
import "@SafeSwapRouter/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice Exact-output swap parameters signed by the user.
 * @param token_out Token the user receives.
 * @param exact_output_amount Exact net output sent to the user after the SafeSwap protocol fee.
 * @param pool_info Target SafeSwap pool configuration.
 *
 * @dev Input token and maximum input amount come from the bond funding, not from this struct. Because the output is fixed,
 *      the LP repricing rebate is charged on the input side and counts against the committed maximum input.
 */
struct ExactOutputSwapParams {
    IERC20 token_out;
    uint256 exact_output_amount;
    PoolInfo pool_info;
}


/**
 * @title ExactOutputSwapLib
 * @notice Exact-output swaps via SafeSwap: protocol fee grossed up into the output, LP repricing rebate charged on the input.
 */
library ExactOutputSwapLib {
    using FundingsLib for BondContext;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactOutputSwap call)"
        "ExactOutputSwap(address token_out,uint256 exact_output_amount,PoolInfo pool_info)"
        "PoolInfo(uint8 base_fee_bps,uint8 rebate_profile,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "ExactOutputSwap(address token_out,uint256 exact_output_amount,PoolInfo pool_info)"
        "PoolInfo(uint8 base_fee_bps,uint8 rebate_profile,int24 tick_spacing)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  255;

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
        if(  params.pool_info.rebate_profile > MAX_REBATE_PROFILE  )                 revert InvalidRebateProfile({ rebate_profile: params.pool_info.rebate_profile });
        if(  preferred_fundings.length != 1  )                                       revert( SWAPS_REQUIRE_EXACTLY_ONE_FUNDING );
        if(  address(preferred_fundings[0].token) == address(params.token_out)  )    revert( TOKENS_MUST_BE_DIFFERENT );

        constraints.min_stake                       =  SafeSwapCommon.calculate_swap_stake( preferred_fundings[ 0 ] );
        constraints.min_fundings                    =  preferred_fundings;
        constraints.min_execution_delay_in_blocks   =  MIN_BOND_EXECUTION_DELAY_IN_BLOCKS;
        constraints.min_execution_delay_in_seconds  =  MIN_BOND_EXECUTION_DELAY_IN_SECONDS;
        constraints.max_execution_delay_in_seconds  =  MAX_BOND_EXECUTION_DELAY_IN_SECONDS;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute( BondContext memory context, ExactOutputSwapParams memory params, IPoolManager pool_manager, address hook, address router ) public
    {
        // *NOTE*  -  Token in and max amount come from fundings. Multi-funding: pick best at execution time.
        IERC20 token_in            =  context.fundings[ 0 ].token;
        uint256 maximum_amount_in  =  context.fundings[ 0 ].amount;

        uint24 fee_units  =  SafeSwapCommon.base_fee_units( params.pool_info.base_fee_bps );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( token_in, params.token_out, fee_units, params.pool_info.tick_spacing, hook );
        PoolId pool_id           =  pool_key.toId( );

        // ━━━━  GROSS-UP MATH  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        //
        // The user wants to receive exactly `exact_output_amount` tokens, NET of the protocol fee. The pool produces whatever
        // we ask for via `amountSpecified`, so we instruct it to produce a slightly larger `grossed_up_pool_output`, then split
        // it on settlement: the user gets exactly the target, the protocol keeps the remainder.
        //
        //     grossed_up_pool_output  =  exact_output_amount * DIVISOR / ( DIVISOR - effective_fee_rate )
        //
        uint256 effective_fee_rate      =  fee_units < MIN_PROTOCOL_FEE_RATE ? MIN_PROTOCOL_FEE_RATE : fee_units;
        uint256 fee_complement          =  PROTOCOL_FEE_DIVISOR - effective_fee_rate;
        // Truncating division: rounding dust on the gross-up is ≤1 wei per swap.
        uint256 grossed_up_pool_output  =  params.exact_output_amount * PROTOCOL_FEE_DIVISOR / fee_complement;

        bool zero_for_one  =  address(token_in) < address(params.token_out);

        ( , int24 tick_before, , )  =  pool_manager.getSlot0( pool_id );

        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: zero_for_one,
            amountSpecified: int256(grossed_up_pool_output),
            sqrtPriceLimitX96: zero_for_one ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta  =  pool_manager.swap( pool_key, swap_params, "" );

        // *NOTE*  -  Input delta is ALWAYS negative (we owe pool). Negate to get positive amount for calculation.
        uint256 amount_in  =  zero_for_one ? uint256(-int256(delta.amount0( ))) : uint256(-int256(delta.amount1( )));

        // The repricing rebate is charged on the input side (output is fixed) and counts against the committed maximum input.
        ( int24 tick_after, uint256 rebate_amount, uint256 movement_bps )  =  _measure_rebate( pool_manager, pool_id, tick_before, params.pool_info.rebate_profile, amount_in );

        uint256 total_input  =  amount_in + rebate_amount;
        if(  total_input > maximum_amount_in  )  revert SlippageExceeded({ amount_received: total_input, minimum_required: maximum_amount_in });

        uint256 user_output   =  params.exact_output_amount;
        uint256 protocol_fee  =  grossed_up_pool_output - params.exact_output_amount;

        Currency rebate_currency  =  Currency.wrap( address(token_in) );
        SafeSwapCommon.donate_rebate( pool_manager, pool_key, rebate_currency, rebate_amount );

        SafeSwapCommon.settle_and_take( pool_manager, context, token_in, params.token_out, total_input, user_output, protocol_fee, router );

        if(  rebate_amount > 0  )
        {
            emit RepricingRebateCharged({
                pool_id:         PoolId.unwrap( pool_id ),
                user:            context.user,
                tick_before:     tick_before,
                tick_after:      tick_after,
                tick_delta:      movement_bps,
                movement_bps:    movement_bps,
                rebate_profile:  params.pool_info.rebate_profile,
                rebate_amount:   rebate_amount,
                rebate_currency: address(token_in)
            });
        }
    }

    // *SECURITY*  -  See ExactInputSwapLib: the rebate is skipped when the pool has zero in-range liquidity, since V4 `donate`
    //                would revert. The rebate is charged on the input amount because the output is fixed.
    function _measure_rebate( IPoolManager pool_manager, PoolId pool_id, int24 tick_before, uint8 rebate_profile, uint256 amount_in )
    private view returns ( int24 tick_after, uint256 rebate_amount, uint256 movement_bps )
    {
        ( , tick_after, , )  =  pool_manager.getSlot0( pool_id );

        if(  pool_manager.getLiquidity( pool_id ) == 0  )  return ( tick_after, 0, 0 );

        ( rebate_amount, movement_bps )  =  SafeSwapCommon.compute_repricing_rebate( tick_before, tick_after, rebate_profile, amount_in );
    }
}

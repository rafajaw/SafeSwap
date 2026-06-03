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
 * @notice Exact-input swap parameters signed by the user.
 * @param token_out Token the user receives.
 * @param minimum_output_amount Minimum net output after the SafeSwap protocol fee.
 * @param pool_info Target SafeSwap pool configuration (base fee, capture, tick spacing).
 *
 * @dev Input token and input amount come from the bond funding, not from this struct. The base LP fee and the repricing fee
 *      are charged inside the pool by the hook's dynamic-fee override and accrue to LPs; this struct's `base_fee_bps` only
 *      drives the separate SafeSwap protocol fee.
 */
struct ExactInputSwapParams {
    IERC20 token_out;
    uint256 minimum_output_amount;
    PoolInfo pool_info;
}


/**
 * @title ExactInputSwapLib
 * @notice Exact-input swaps via SafeSwap on dynamic-fee pools. The LP fee (base + repricing) is applied natively by the
 *         hook; this library only takes the SafeSwap protocol fee from the output and enforces slippage.
 */
library ExactInputSwapLib {
    using FundingsLib for BondContext;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactInputSwap call)"
        "ExactInputSwap(address token_out,uint256 minimum_output_amount,PoolInfo pool_info)"
        "PoolInfo(uint16 base_fee_bps,uint8 rebate_percent,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "ExactInputSwap(address token_out,uint256 minimum_output_amount,PoolInfo pool_info)"
        "PoolInfo(uint16 base_fee_bps,uint8 rebate_percent,int24 tick_spacing)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  256;

    function get_signing_info( ExactInputSwapParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            EIP712_TYPEHASH,
            address(params.token_out),
            params.minimum_output_amount,
            SafeSwapCommon.hash_pool_info( params.pool_info )
        ));

        token_amount_offset  =  EIP712_TOKEN_AMOUNT_OFFSET;
    }


    // ━━━━  GET CONSTRAINTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function get_constraints( ExactInputSwapParams memory params, TokenAmount[] memory preferred_fundings )
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

    function execute( BondContext memory context, ExactInputSwapParams memory params, IPoolManager pool_manager, address hook, address router ) internal
    {
        // *NOTE*  -  Token in and amount come from fundings. Multi-funding: pick best at execution time.
        IERC20 token_in    =  context.fundings[ 0 ].token;
        uint256 amount_in  =  context.fundings[ 0 ].amount;

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( token_in, params.token_out, LPFeeLibrary.DYNAMIC_FEE_FLAG, params.pool_info.tick_spacing, hook );

        bool zero_for_one  =  address(token_in) < address(params.token_out);

        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: zero_for_one,
            amountSpecified: -int256(amount_in),
            sqrtPriceLimitX96: zero_for_one ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta  =  pool_manager.swap( pool_key, swap_params, "" );

        // *NOTE*  -  Output delta is positive (pool owes us), already net of the LP fee the hook applied. The SafeSwap
        //            protocol fee is taken on top of that; the LP base + repricing fee already accrued to LPs in the pool.
        uint256 pool_output  =  zero_for_one ? uint256(int256(delta.amount1( ))) : uint256(int256(delta.amount0( )));

        ( uint256 protocol_fee, uint256 user_output )  =  SafeSwapCommon.calculate_protocol_fee( pool_output, SafeSwapCommon.base_fee_units( params.pool_info.base_fee_bps ) );

        if(  user_output < params.minimum_output_amount  )  revert SlippageExceeded({ amount_received: user_output, minimum_required: params.minimum_output_amount });

        SafeSwapCommon.settle_and_take( pool_manager, context, token_in, params.token_out, amount_in, user_output, protocol_fee, router );
    }
}

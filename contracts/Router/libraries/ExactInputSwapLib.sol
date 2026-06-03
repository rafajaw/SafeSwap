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
 * @notice Exact-input swap parameters signed by the user.
 * @param token_out Token the user receives.
 * @param minimum_output_amount Minimum net output after the SafeSwap protocol fee and LP repricing rebate.
 * @param pool_info Target SafeSwap pool configuration.
 *
 * @dev Input token and input amount come from the bond funding, not from this struct.
 */
struct ExactInputSwapParams {
    IERC20 token_out;
    uint256 minimum_output_amount;
    PoolInfo pool_info;
}


/**
 * @title ExactInputSwapLib
 * @notice Exact-input swaps via SafeSwap: protocol fee + LP repricing rebate charged from the swap output.
 */
library ExactInputSwapLib {
    using FundingsLib for BondContext;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactInputSwap call)"
        "ExactInputSwap(address token_out,uint256 minimum_output_amount,PoolInfo pool_info)"
        "PoolInfo(uint8 base_fee_bps,uint8 rebate_profile,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "ExactInputSwap(address token_out,uint256 minimum_output_amount,PoolInfo pool_info)"
        "PoolInfo(uint8 base_fee_bps,uint8 rebate_profile,int24 tick_spacing)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  255;

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

    function execute( BondContext memory context, ExactInputSwapParams memory params, IPoolManager pool_manager, address hook, address router ) public
    {
        // *NOTE*  -  Token in and amount come from fundings. Multi-funding: pick best at execution time.
        IERC20 token_in    =  context.fundings[ 0 ].token;
        uint256 amount_in  =  context.fundings[ 0 ].amount;

        uint24 fee_units  =  SafeSwapCommon.base_fee_units( params.pool_info.base_fee_bps );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( token_in, params.token_out, fee_units, params.pool_info.tick_spacing, hook );
        PoolId pool_id           =  pool_key.toId( );

        bool zero_for_one  =  address(token_in) < address(params.token_out);

        ( , int24 tick_before, , )  =  pool_manager.getSlot0( pool_id );

        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: zero_for_one,
            amountSpecified: -int256(amount_in),
            sqrtPriceLimitX96: zero_for_one ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta  =  pool_manager.swap( pool_key, swap_params, "" );

        // *NOTE*  -  Swap output deltas are ALWAYS positive (pool owes us tokens). Input deltas are ALWAYS negative (we owe pool).
        // This is guaranteed by Uniswap V4 design (see SqrtPriceMath.sol:267-269 and Pool.sol:454-461).
        uint256 pool_output  =  zero_for_one ? uint256(int256(delta.amount1( ))) : uint256(int256(delta.amount0( )));

        ( int24 tick_after, uint256 rebate_amount, uint256 movement_bps )  =  _measure_rebate( pool_manager, pool_id, tick_before, params.pool_info.rebate_profile, pool_output );

        // Split the pool output into the protocol fee, the LP repricing rebate, and the user's net receipt.
        ( uint256 protocol_fee, )  =  SafeSwapCommon.calculate_protocol_fee( pool_output, fee_units );
        uint256 user_output        =  pool_output - protocol_fee - rebate_amount;

        if(  user_output < params.minimum_output_amount  )  revert SlippageExceeded({ amount_received: user_output, minimum_required: params.minimum_output_amount });

        SafeSwapCommon.settle_and_take( pool_manager, context, token_in, params.token_out, amount_in, user_output, protocol_fee, router );

        Currency rebate_currency  =  Currency.wrap( address(params.token_out) );
        SafeSwapCommon.donate_rebate( pool_manager, pool_key, rebate_currency, rebate_amount );

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
                rebate_currency: address(params.token_out)
            });
        }
    }

    // *SECURITY*  -  The rebate is donated to in-range LPs. If the swap left the pool with zero active liquidity, V4 `donate`
    //                would revert, so we skip the rebate and return that value to the trader rather than failing the swap.
    function _measure_rebate( IPoolManager pool_manager, PoolId pool_id, int24 tick_before, uint8 rebate_profile, uint256 pool_output )
    private view returns ( int24 tick_after, uint256 rebate_amount, uint256 movement_bps )
    {
        ( , tick_after, , )  =  pool_manager.getSlot0( pool_id );

        if(  pool_manager.getLiquidity( pool_id ) == 0  )  return ( tick_after, 0, 0 );

        ( rebate_amount, movement_bps )  =  SafeSwapCommon.compute_repricing_rebate( tick_before, tick_after, rebate_profile, pool_output );
    }
}

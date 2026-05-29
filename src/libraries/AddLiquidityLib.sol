// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwap/libraries/SafeSwapCommon.sol";
import "@SafeSwap/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@SafeSwap/vendor/LiquidityAmounts.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error OneSidedDepositMismatch( address expected_token, uint256 minimum_required );
error MinimumAddedTokensMismatch( address funding_token0, address funding_token1, address minimum_added_a_token, address minimum_added_b_token );


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice Add-liquidity parameters signed by the user.
 * @param pool_info Target Uniswap V4 pool configuration.
 * @param tick_lower Lower tick of the liquidity position.
 * @param tick_upper Upper tick of the liquidity position.
 * @param minimum_added_a Minimum amount that must be added for one of the two pool tokens (token field identifies which).
 * @param minimum_added_b Minimum amount that must be added for the other pool token (token field identifies which).
 *
 * @dev MINIMUM-ADDED ORDER: `minimum_added_a` and `minimum_added_b` are matched to the pool's currency0/currency1 by token address at execute time,
 *      so they can be supplied in any order. Both `token` fields must equal the two funding tokens; otherwise `MinimumAddedTokensMismatch` reverts.
 * @dev Token0, token1, and desired deposit amounts come from the two bond fundings, not from this struct.
 */
struct AddLiquidityParams {
    PoolInfo pool_info;
    int24 tick_lower;
    int24 tick_upper;
    TokenAmount minimum_added_a;
    TokenAmount minimum_added_b;
}


/**
 * @title AddLiquidityLib
 * @notice Library for add liquidity operations via SafeSwap
 * @dev Contains constraint calculation and execution logic for adding liquidity to Uniswap V4 pools
 */
library AddLiquidityLib {
    using FundingsLib for BondContext;
    using PoolIdLibrary for PoolKey;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,AddLiquidity call)"
        "AddLiquidity(PoolInfo pool_info,int24 tick_lower,int24 tick_upper,TokenAmount minimum_added_a,TokenAmount minimum_added_b)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "AddLiquidity(PoolInfo pool_info,int24 tick_lower,int24 tick_upper,TokenAmount minimum_added_a,TokenAmount minimum_added_b)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  264;

    function get_signing_info( AddLiquidityParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            EIP712_TYPEHASH,
            SafeSwapCommon.hash_pool_info( params.pool_info ),
            params.tick_lower,
            params.tick_upper,
            SafeSwapCommon.hash_token_amount( params.minimum_added_a ),
            SafeSwapCommon.hash_token_amount( params.minimum_added_b )
        ));

        token_amount_offset  =  EIP712_TOKEN_AMOUNT_OFFSET;
    }


    // ━━━━  GET CONSTRAINTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function get_constraints(
        AddLiquidityParams memory params,
        IERC20 preferred_stake_token,
        TokenAmount[] memory preferred_fundings,
        IPoolManager pool_manager,
        address hook_address
    ) internal view returns ( BondConstraints memory constraints )
    {
        if(  params.pool_info.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG  )   revert UnsupportedFeeTier({ fee: params.pool_info.fee });
        if(  preferred_fundings.length != 2  )                          revert( ADD_LIQUIDITY_REQUIRES_TWO_FUNDINGS );

        ( IERC20 token0, uint256 amount0_desired, IERC20 token1, uint256 amount1_desired )  =  _validate_and_sort_tokens(
            preferred_fundings[ 0 ],
            preferred_fundings[ 1 ],
            params.minimum_added_a,
            params.minimum_added_b
        );

        PoolKey memory pool_key  =  PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: params.pool_info.fee,
            tickSpacing: params.pool_info.tick_spacing,
            hooks: IHooks(hook_address)
        });

        ( uint160 sqrtPriceX96, , , )  =  StateLibrary.getSlot0( pool_manager, pool_key.toId( ) );

        constraints.min_stake                       =  SafeSwapCommon.calculate_normalized_liquidity_stake(
            sqrtPriceX96,
            token0,
            token1,
            amount0_desired,
            amount1_desired,
            preferred_stake_token
        );
        constraints.min_fundings                    =  preferred_fundings;
        constraints.min_execution_delay_in_blocks   =  MIN_BOND_EXECUTION_DELAY_IN_BLOCKS;
        constraints.min_execution_delay_in_seconds  =  MIN_BOND_EXECUTION_DELAY_IN_SECONDS;
        constraints.max_execution_delay_in_seconds  =  MAX_BOND_EXECUTION_DELAY_IN_SECONDS;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute( BondContext memory context, AddLiquidityParams memory params, IPoolManager pool_manager, address hook_address ) internal
    {
        ( IERC20 token0, uint256 amount0_desired, IERC20 token1, uint256 amount1_desired )  =  _validate_and_sort_tokens(
            context.fundings[ 0 ],
            context.fundings[ 1 ],
            params.minimum_added_a,
            params.minimum_added_b
        );

        ( uint256 amount0_minimum_added, uint256 amount1_minimum_added )  =  address(params.minimum_added_a.token) == address(token0)
            ? ( params.minimum_added_a.amount, params.minimum_added_b.amount )
            : ( params.minimum_added_b.amount, params.minimum_added_a.amount );

        PoolKey memory pool_key  =  PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: params.pool_info.fee,
            tickSpacing: params.pool_info.tick_spacing,
            hooks: IHooks(hook_address)
        });

        ( uint160 sqrt_price_x96, , , )  =  StateLibrary.getSlot0( pool_manager, pool_key.toId( ) );
        uint160 sqrt_price_a_x96  =  TickMath.getSqrtPriceAtTick( params.tick_lower );
        uint160 sqrt_price_b_x96  =  TickMath.getSqrtPriceAtTick( params.tick_upper );
        uint128 liquidity  =  LiquidityAmounts.getLiquidityForAmounts( sqrt_price_x96, sqrt_price_a_x96, sqrt_price_b_x96, amount0_desired, amount1_desired );

        IPoolManager.ModifyLiquidityParams memory mod_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: params.tick_lower,
            tickUpper: params.tick_upper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(uint256(uint160(context.user)))
        });

        ( BalanceDelta delta, )  =  pool_manager.modifyLiquidity( pool_key, mod_params, "" );

        // *NOTE*  -  When adding liquidity (liquidityDelta > 0), deltas are negative (we provide tokens to pool)
        // or zero if tick range is entirely above/below current tick (one-sided position). Positive is impossible
        // by V4 invariant; the asymmetric branches below rely on this — a positive delta would catastrophic-revert
        // during V4's lock unwind on unsettled balance.
        int128 amount0  =  delta.amount0( );
        int128 amount1  =  delta.amount1( );

        if(  amount0 < 0  )
        {
            uint256 amount0_actual  =  uint256(uint128(-amount0));
            if(  amount0_actual < amount0_minimum_added  )
            {
                revert SlippageExceeded({ amount_received: amount0_actual, minimum_required: amount0_minimum_added });
            }

            SafeSwapCommon.settle_input( pool_manager, context, token0, amount0_actual );
        }
        else if(  amount0_minimum_added > 0  )
        {
            // User expected to deposit token0, but the position is one-sided in token1 at the current price.
            revert OneSidedDepositMismatch({ expected_token: address(token0), minimum_required: amount0_minimum_added });
        }

        if(  amount1 < 0  )
        {
            uint256 amount1_actual  =  uint256(uint128(-amount1));
            if(  amount1_actual < amount1_minimum_added  )
            {
                revert SlippageExceeded({ amount_received: amount1_actual, minimum_required: amount1_minimum_added });
            }

            SafeSwapCommon.settle_input( pool_manager, context, token1, amount1_actual );
        }
        else if(  amount1_minimum_added > 0  )
        {
            // User expected to deposit token1, but the position is one-sided in token0 at the current price.
            revert OneSidedDepositMismatch({ expected_token: address(token1), minimum_required: amount1_minimum_added });
        }
    }


    // ━━━━  INTERNAL HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Sort the funding pair into pool currency order and confirm the signed mins reference those same two tokens.
     * @dev Reverts with `TOKENS_MUST_BE_DIFFERENT` if the two fundings share a token, or `MinimumAddedTokensMismatch` if the minimum-added
     *      token fields do not reference the same two tokens as the fundings (in either order).
     */
    function _validate_and_sort_tokens(
        TokenAmount memory funding_a,
        TokenAmount memory funding_b,
        TokenAmount memory minimum_added_a,
        TokenAmount memory minimum_added_b
    ) private pure returns ( IERC20 token0, uint256 amount0_desired, IERC20 token1, uint256 amount1_desired )
    {
        ( token0, amount0_desired, token1, amount1_desired )  =  SafeSwapCommon.sort_token_amount_pair( funding_a, funding_b );

        bool ordered_ab  =  address(minimum_added_a.token) == address(token0)  &&  address(minimum_added_b.token) == address(token1);
        bool ordered_ba  =  address(minimum_added_a.token) == address(token1)  &&  address(minimum_added_b.token) == address(token0);

        if(  ordered_ab == false  &&  ordered_ba == false  )
        {
            revert MinimumAddedTokensMismatch({
                funding_token0:          address(token0),
                funding_token1:          address(token1),
                minimum_added_a_token:   address(minimum_added_a.token),
                minimum_added_b_token:   address(minimum_added_b.token)
            });
        }
    }
}

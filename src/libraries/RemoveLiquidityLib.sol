// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/integrations/BondRouteProtected.sol";
import "@SafeSwap/libraries/SafeSwapCommon.sol";
import "@SafeSwap/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";
import { PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@UniswapV4Core/../test/utils/LiquidityAmounts.sol";


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct RemoveLiquidityParams {
    IERC20 token0;
    IERC20 token1;
    PoolInfo pool_info;
    int24 tick_lower;
    int24 tick_upper;
    uint128 liquidity;
    uint256 amount0_min;
    uint256 amount1_min;
    bytes32 salt;
}


/**
 * @title RemoveLiquidityLib
 * @notice Library for remove liquidity operations via SafeSwap
 * @dev Contains constraint calculation and execution logic for removing liquidity from Uniswap V4 pools
 */
library RemoveLiquidityLib {
    using PoolIdLibrary for PoolKey;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,RemoveLiquidity call)"
        "RemoveLiquidity(address token0,address token1,PoolInfo pool_info,int24 tick_lower,int24 tick_upper,uint128 liquidity,uint256 amount0_min,uint256 amount1_min,bytes32 salt)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "RemoveLiquidity(address token0,address token1,PoolInfo pool_info,int24 tick_lower,int24 tick_upper,uint128 liquidity,uint256 amount0_min,uint256 amount1_min,bytes32 salt)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  315;

    function get_signing_info( RemoveLiquidityParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            EIP712_TYPEHASH,
            address(params.token0),
            address(params.token1),
            SafeSwapCommon.hash_pool_info( params.pool_info ),
            params.tick_lower,
            params.tick_upper,
            params.liquidity,
            params.amount0_min,
            params.amount1_min,
            params.salt
        ));

        token_amount_offset  =  EIP712_TOKEN_AMOUNT_OFFSET;
    }


    // ━━━━  GET CONSTRAINTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function get_constraints(
        RemoveLiquidityParams memory params,
        IPoolManager pool_manager,
        address hook_address
    ) internal view returns ( BondConstraints memory constraints )
    {
        if(  params.pool_info.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG  )  revert UnsupportedFeeTier({ fee: params.pool_info.fee });
        if(  address(params.token0) == address(params.token1)  )         revert( TOKENS_MUST_BE_DIFFERENT );

        PoolKey memory pool_key  =  PoolKey({
            currency0: Currency.wrap( address(params.token0) ),
            currency1: Currency.wrap( address(params.token1) ),
            fee: params.pool_info.fee,
            tickSpacing: params.pool_info.tick_spacing,
            hooks: IHooks(hook_address)
        });

        ( uint160 sqrtPriceX96, , , )  =  StateLibrary.getSlot0( pool_manager, pool_key.toId( ) );

        // Project the actual amounts that this liquidity removal will release at current pool price.
        // Stake is based on real released value, not on user-controlled amount0_min/amount1_min (which could be 0).
        uint160 sqrtPriceA  =  TickMath.getSqrtPriceAtTick( params.tick_lower );
        uint160 sqrtPriceB  =  TickMath.getSqrtPriceAtTick( params.tick_upper );

        ( uint256 amount0_released, uint256 amount1_released )  =  LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtPriceA,
            sqrtPriceB,
            params.liquidity
        );

        constraints.min_stake  =  SafeSwapCommon.calculate_normalized_liquidity_stake( sqrtPriceX96, params.token0, amount0_released, amount1_released );

        constraints.min_fundings  =  new TokenAmount[](0);

        constraints.min_execution_delay_in_blocks   =  MIN_EXECUTION_DELAY_IN_BLOCKS;
        constraints.max_execution_delay_in_seconds  =  MAX_EXECUTION_DELAY;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute(
        BondContext memory context,
        RemoveLiquidityParams memory params,
        IPoolManager pool_manager,
        address hook_address
    ) internal
    {
        PoolKey memory pool_key  =  PoolKey({
            currency0: Currency.wrap(address(params.token0)),
            currency1: Currency.wrap(address(params.token1)),
            fee: params.pool_info.fee,
            tickSpacing: params.pool_info.tick_spacing,
            hooks: IHooks(hook_address)
        });

        bytes32 effective_salt  =  SafeSwapCommon._position_salt( context.user, params.salt );

        IPoolManager.ModifyLiquidityParams memory mod_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: params.tick_lower,
            tickUpper: params.tick_upper,
            liquidityDelta: -int128(params.liquidity),
            salt: effective_salt
        });

        ( BalanceDelta delta, )  =  pool_manager.modifyLiquidity( pool_key, mod_params, "" );

        // *NOTE*  -  When removing liquidity (liquidityDelta < 0), deltas are ALWAYS positive (pool returns tokens to us).
        // Negative deltas are impossible here by Uniswap V4 design (see SqrtPriceMath.sol:267-269).
        uint256 amount0  =  uint256(uint128(delta.amount0( )));
        uint256 amount1  =  uint256(uint128(delta.amount1( )));

        if(  amount0 < params.amount0_min  )  revert SlippageExceeded({ amount_received: amount0, minimum_required: params.amount0_min });
        if(  amount1 < params.amount1_min  )  revert SlippageExceeded({ amount_received: amount1, minimum_required: params.amount1_min });

        pool_manager.take( Currency.wrap(address(params.token0)), context.user, amount0 );
        pool_manager.take( Currency.wrap(address(params.token1)), context.user, amount1 );
    }
}

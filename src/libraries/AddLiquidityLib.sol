// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/integrations/BondRouteProtected.sol";
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
import { LiquidityAmounts } from "@UniswapV4Core/../test/utils/LiquidityAmounts.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error OneSidedDepositMismatch( address expected_token, uint256 minimum_required );


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct AddLiquidityParams {
    PoolInfo pool_info;
    int24 tick_lower;
    int24 tick_upper;
    uint256 amount0_min;
    uint256 amount1_min;
    bytes32 salt;
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
        "AddLiquidity(PoolInfo pool_info,int24 tick_lower,int24 tick_upper,uint256 amount0_min,uint256 amount1_min,bytes32 salt)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "AddLiquidity(PoolInfo pool_info,int24 tick_lower,int24 tick_upper,uint256 amount0_min,uint256 amount1_min,bytes32 salt)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  261;

    function get_signing_info( AddLiquidityParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            EIP712_TYPEHASH,
            SafeSwapCommon.hash_pool_info( params.pool_info ),
            params.tick_lower,
            params.tick_upper,
            params.amount0_min,
            params.amount1_min,
            params.salt
        ));

        token_amount_offset  =  EIP712_TOKEN_AMOUNT_OFFSET;
    }


    // ━━━━  GET CONSTRAINTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function get_constraints(
        AddLiquidityParams memory params,
        TokenAmount[2] memory token_pair,
        IPoolManager pool_manager,
        address hook_address
    ) internal view returns ( BondConstraints memory constraints )
    {
        if(  params.pool_info.fee == SafeSwapCommon.DYNAMIC_FEE_FLAG  )  revert UnsupportedFeeTier( params.pool_info.fee );

        // *NOTE*  -  token_pair must be [token0, token1] in order matching the pool's currency order.
        IERC20 token0            =  token_pair[ 0 ].token;
        uint256 amount0_desired  =  token_pair[ 0 ].amount;
        IERC20 token1            =  token_pair[ 1 ].token;
        uint256 amount1_desired  =  token_pair[ 1 ].amount;

        if(  address(token0) == address(token1)  )  revert( "Tokens must be different" );

        PoolKey memory pool_key  =  PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: params.pool_info.fee,
            tickSpacing: params.pool_info.tick_spacing,
            hooks: IHooks(hook_address)
        });

        ( uint160 sqrtPriceX96, , , )  =  StateLibrary.getSlot0( pool_manager, pool_key.toId( ) );

        constraints.min_stake  =  SafeSwapCommon.calculate_normalized_liquidity_stake( sqrtPriceX96, token0, amount0_desired, amount1_desired );

        constraints.min_fundings  =  new TokenAmount[](2);
        constraints.min_fundings[ 0 ]  =  TokenAmount({ token: token0, amount: amount0_desired });
        constraints.min_fundings[ 1 ]  =  TokenAmount({ token: token1, amount: amount1_desired });

        constraints.min_execution_delay_in_blocks   =  MIN_EXECUTION_DELAY_IN_BLOCKS;
        constraints.max_execution_delay_in_seconds  =  MAX_LIQUIDITY_EXECUTION_DELAY;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute(
        BondContext memory context,
        AddLiquidityParams memory params,
        IPoolManager pool_manager,
        address hook_address
    ) internal
    {
        // *NOTE*  -  Fundings are [token0, token1] in order matching the pool's currency order.
        IERC20 token0            =  context.fundings[ 0 ].token;
        uint256 amount0_desired  =  context.fundings[ 0 ].amount;
        IERC20 token1            =  context.fundings[ 1 ].token;
        uint256 amount1_desired  =  context.fundings[ 1 ].amount;

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

        bytes32 effective_salt  =  SafeSwapCommon._position_salt( context.user, params.salt );

        IPoolManager.ModifyLiquidityParams memory mod_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: params.tick_lower,
            tickUpper: params.tick_upper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: effective_salt
        });

        ( BalanceDelta delta, )  =  pool_manager.modifyLiquidity( pool_key, mod_params, "" );

        // *NOTE*  -  When adding liquidity (liquidityDelta > 0), deltas are negative (we provide tokens to pool)
        // or zero if tick range is entirely above/below current tick (one-sided position).
        int128 amount0  =  delta.amount0( );
        int128 amount1  =  delta.amount1( );

        if(  amount0 < 0  )
        {
            uint256 amount0_actual  =  uint256(uint128(-amount0));
            if(  amount0_actual < params.amount0_min  )  revert SlippageExceeded( amount0_actual, params.amount0_min );

            pool_manager.sync( Currency.wrap( address(token0) ) );
            context.send( token0, amount0_actual, address(pool_manager) );
            pool_manager.settle( );
        }
        else if(  params.amount0_min > 0  )
        {
            // User expected to deposit token0 but none is needed (e.g., price moved out of range).
            revert OneSidedDepositMismatch({ expected_token: address(token0), minimum_required: params.amount0_min });
        }

        if(  amount1 < 0  )
        {
            uint256 amount1_actual  =  uint256(uint128(-amount1));
            if(  amount1_actual < params.amount1_min  )  revert SlippageExceeded( amount1_actual, params.amount1_min );

            pool_manager.sync( Currency.wrap( address(token1) ) );
            context.send( token1, amount1_actual, address(pool_manager) );
            pool_manager.settle( );
        }
        else if(  params.amount1_min > 0  )
        {
            // User expected to deposit token1 but none is needed (e.g., price moved out of range).
            revert OneSidedDepositMismatch({ expected_token: address(token1), minimum_required: params.amount1_min });
        }
    }
}

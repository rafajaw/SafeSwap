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


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct DonateParams {
    PoolInfo pool_info;
}


/**
 * @title DonateLib
 * @notice Library for BondRoute-protected Uniswap V4 donation operations
 */
library DonateLib {
    using FundingsLib for BondContext;
    using PoolIdLibrary for PoolKey;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,Donate call)"
        "Donate(PoolInfo pool_info)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "Donate(PoolInfo pool_info)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  162;

    function get_signing_info( DonateParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            EIP712_TYPEHASH,
            SafeSwapCommon.hash_pool_info( params.pool_info )
        ));

        token_amount_offset  =  EIP712_TOKEN_AMOUNT_OFFSET;
    }


    // ━━━━  GET CONSTRAINTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function get_constraints(
        DonateParams memory params,
        TokenAmount[2] memory token_pair,
        IPoolManager pool_manager,
        address hook_address
    ) internal view returns ( BondConstraints memory constraints )
    {
        if(  params.pool_info.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG  )  revert UnsupportedFeeTier({ fee: params.pool_info.fee });

        IERC20 token0    =  token_pair[ 0 ].token;
        uint256 amount0  =  token_pair[ 0 ].amount;
        IERC20 token1    =  token_pair[ 1 ].token;
        uint256 amount1  =  token_pair[ 1 ].amount;

        if(  address(token0) == address(token1)  )  revert( TOKENS_MUST_BE_DIFFERENT );

        PoolKey memory pool_key  =  PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: params.pool_info.fee,
            tickSpacing: params.pool_info.tick_spacing,
            hooks: IHooks(hook_address)
        });

        ( uint160 sqrtPriceX96, , , )  =  StateLibrary.getSlot0( pool_manager, pool_key.toId( ) );

        constraints.min_stake  =  SafeSwapCommon.calculate_normalized_liquidity_stake( sqrtPriceX96, token0, amount0, amount1 );

        constraints.min_fundings  =  new TokenAmount[](2);
        constraints.min_fundings[ 0 ]  =  TokenAmount({ token: token0, amount: amount0 });
        constraints.min_fundings[ 1 ]  =  TokenAmount({ token: token1, amount: amount1 });

        constraints.min_execution_delay_in_blocks   =  MIN_EXECUTION_DELAY_IN_BLOCKS;
        constraints.max_execution_delay_in_seconds  =  MAX_EXECUTION_DELAY;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute( BondContext memory context, DonateParams memory params, IPoolManager pool_manager, address hook_address ) internal
    {
        uint256 amount0  =  context.fundings[ 0 ].amount;
        uint256 amount1  =  context.fundings[ 1 ].amount;
        IERC20 token0    =  context.fundings[ 0 ].token;
        IERC20 token1    =  context.fundings[ 1 ].token;

        PoolKey memory pool_key  =  PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: params.pool_info.fee,
            tickSpacing: params.pool_info.tick_spacing,
            hooks: IHooks(hook_address)
        });

        BalanceDelta delta  =  pool_manager.donate( pool_key, amount0, amount1, "" );

        int128 delta0  =  delta.amount0( );
        int128 delta1  =  delta.amount1( );

        if(  delta0 < 0  )  SafeSwapCommon.settle_input( pool_manager, context, token0, uint256(uint128(-delta0)) );
        if(  delta1 < 0  )  SafeSwapCommon.settle_input( pool_manager, context, token1, uint256(uint128(-delta1)) );
    }
}

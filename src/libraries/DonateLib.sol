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

/**
 * @notice Donation parameters signed by the user.
 * @param pool_info Target Uniswap V4 pool configuration.
 *
 * @dev Token0, token1, and donation amounts come from the two bond fundings, not from this struct.
 */
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
        TokenAmount[] memory preferred_fundings,
        IPoolManager pool_manager,
        address hook_address
    ) internal view returns ( BondConstraints memory constraints )
    {
        if(  params.pool_info.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG  )   revert UnsupportedFeeTier({ fee: params.pool_info.fee });
        if(  preferred_fundings.length != 2  )                          revert( DONATE_REQUIRES_TWO_FUNDINGS );

        ( IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1 )  =  SafeSwapCommon.sort_token_amount_pair(
            preferred_fundings[ 0 ],
            preferred_fundings[ 1 ]
        );

        PoolKey memory pool_key  =  PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: params.pool_info.fee,
            tickSpacing: params.pool_info.tick_spacing,
            hooks: IHooks(hook_address)
        });

        ( uint160 sqrtPriceX96, , , )  =  StateLibrary.getSlot0( pool_manager, pool_key.toId( ) );

        constraints.min_stake                       =  SafeSwapCommon.calculate_normalized_liquidity_stake( sqrtPriceX96, token0, amount0, amount1 );
        constraints.min_fundings                    =  preferred_fundings;
        constraints.min_execution_delay_in_blocks   =  MIN_BOND_EXECUTION_DELAY_IN_BLOCKS;
        constraints.max_execution_delay_in_seconds  =  MAX_BOND_EXECUTION_DELAY_IN_SECONDS;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute( BondContext memory context, DonateParams memory params, IPoolManager pool_manager, address hook_address ) internal
    {
        ( IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1 )  =  SafeSwapCommon.sort_token_amount_pair(
            context.fundings[ 0 ],
            context.fundings[ 1 ]
        );

        PoolKey memory pool_key  =  PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: params.pool_info.fee,
            tickSpacing: params.pool_info.tick_spacing,
            hooks: IHooks(hook_address)
        });

        BalanceDelta delta  =  pool_manager.donate( pool_key, amount0, amount1, "" );

        // *NOTE*  -  Donate deltas are NEVER positive — V4 only takes from us on donate. Asymmetric branches are intentional;
        //            a positive delta would be a V4 invariant violation and the lock unwind would revert on unsettled balance.
        int128 delta0  =  delta.amount0( );
        int128 delta1  =  delta.amount1( );

        if(  delta0 < 0  )  SafeSwapCommon.settle_input( pool_manager, context, token0, uint256(uint128(-delta0)) );
        if(  delta1 < 0  )  SafeSwapCommon.settle_input( pool_manager, context, token1, uint256(uint128(-delta1)) );
    }
}

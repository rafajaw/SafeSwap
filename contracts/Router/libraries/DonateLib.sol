// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapRouter/libraries/SafeSwapCommon.sol";
import "@SafeSwapRouter/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice Donation parameters signed by the user.
 * @param pool_info Target SafeSwap pool configuration.
 *
 * @dev Token0, token1, and donation amounts come from the two bond fundings, not from this struct.
 */
struct DonateParams {
    PoolInfo pool_info;
}


/**
 * @title DonateLib
 * @notice BondRoute-protected Uniswap V4 donation operations. A direct donation carries no repricing rebate.
 */
library DonateLib {
    using FundingsLib for BondContext;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,Donate call)"
        "Donate(PoolInfo pool_info)"
        "PoolInfo(uint8 base_fee_bps,uint8 rebate_profile,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "Donate(PoolInfo pool_info)"
        "PoolInfo(uint8 base_fee_bps,uint8 rebate_profile,int24 tick_spacing)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  191;

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
        IERC20 preferred_stake_token,
        TokenAmount[] memory preferred_fundings,
        IPoolManager pool_manager,
        address hook
    ) internal view returns ( BondConstraints memory constraints )
    {
        if(  params.pool_info.rebate_profile > MAX_REBATE_PROFILE  )   revert InvalidRebateProfile({ rebate_profile: params.pool_info.rebate_profile });
        if(  preferred_fundings.length != 2  )                         revert( DONATE_REQUIRES_TWO_FUNDINGS );

        ( IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1 )  =  SafeSwapCommon.sort_token_amount_pair(
            preferred_fundings[ 0 ],
            preferred_fundings[ 1 ]
        );

        PoolKey memory pool_key  =  _build_pool_key( params, token0, token1, hook );

        ( uint160 sqrtPriceX96, , , )  =  pool_manager.getSlot0( pool_key.toId( ) );

        constraints.min_stake                       =  SafeSwapCommon.calculate_normalized_liquidity_stake(
            sqrtPriceX96,
            token0,
            token1,
            amount0,
            amount1,
            preferred_stake_token
        );
        constraints.min_fundings                    =  preferred_fundings;
        constraints.min_execution_delay_in_blocks   =  MIN_BOND_EXECUTION_DELAY_IN_BLOCKS;
        constraints.min_execution_delay_in_seconds  =  MIN_BOND_EXECUTION_DELAY_IN_SECONDS;
        constraints.max_execution_delay_in_seconds  =  MAX_BOND_EXECUTION_DELAY_IN_SECONDS;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute( BondContext memory context, DonateParams memory params, IPoolManager pool_manager, address hook ) public
    {
        ( IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1 )  =  SafeSwapCommon.sort_token_amount_pair(
            context.fundings[ 0 ],
            context.fundings[ 1 ]
        );

        PoolKey memory pool_key  =  _build_pool_key( params, token0, token1, hook );

        BalanceDelta delta  =  pool_manager.donate( pool_key, amount0, amount1, "" );

        // *NOTE*  -  Donate deltas are NEVER positive — V4 only takes from us on donate. Asymmetric branches are intentional;
        //            a positive delta would be a V4 invariant violation and the lock unwind would revert on unsettled balance.
        int128 delta0  =  delta.amount0( );
        int128 delta1  =  delta.amount1( );

        if(  delta0 < 0  )  SafeSwapCommon.settle_input( pool_manager, context, token0, uint256(uint128(-delta0)) );
        if(  delta1 < 0  )  SafeSwapCommon.settle_input( pool_manager, context, token1, uint256(uint128(-delta1)) );
    }

    function _build_pool_key( DonateParams memory params, IERC20 token0, IERC20 token1, address hook )
    private pure returns ( PoolKey memory )
    {
        return PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: SafeSwapCommon.base_fee_units( params.pool_info.base_fee_bps ),
            tickSpacing: params.pool_info.tick_spacing,
            hooks: IHooks(hook)
        });
    }
}

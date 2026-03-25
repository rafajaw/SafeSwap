// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/integrations/BondRouteProtected.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";


// ━━━━  DATA STRUCTURES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct PoolInfo {
    uint24 fee;
    int24 tick_spacing;
}


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error SlippageExceeded( uint256 amount_received, uint256 minimum_required );


/**
 * @title SafeSwapCommon
 * @notice Shared utilities for SafeSwap action libraries
 * @dev Contains constants, pool key building, stake calculation, protocol fee math, and settlement logic
 */
library SafeSwapCommon {
    using FundingsLib for BondContext;

    // ━━━━  CONSTANTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    uint256 constant SWAP_STAKE_PERCENTAGE              =   1;
    uint256 constant LIQUIDITY_STAKE_PERCENTAGE         =   2;  // 2x swap rate — only token0 side is measured.
    uint160 constant MIN_SQRT_PRICE_LIMIT               =   4295128740;  // MIN_SQRT_PRICE + 1.
    uint160 constant MAX_SQRT_PRICE_LIMIT               =   1461446703485210103287273052203988822378723970341;  // MAX_SQRT_PRICE - 1.
    uint256 constant MIN_EXECUTION_DELAY_IN_BLOCKS      =   3;
    uint256 constant MAX_SWAP_EXECUTION_DELAY           =   1 hours;
    uint256 constant MAX_LIQUIDITY_EXECUTION_DELAY      =   4 hours;
    uint256 constant PROTOCOL_FEE_DIVISOR               =   10_000_000;  // E.g. 0.3% pool: LPs get full 0.3%, SafeSwap takes 0.03% from output.
    uint256 constant MIN_PROTOCOL_FEE_RATE              =   1000;        // 0.01% floor when pool LP fee < 0.10%.

    // EIP-712 type hash for PoolInfo struct (shared across all action libs).
    bytes32 constant POOL_INFO_TYPEHASH  =  keccak256( "PoolInfo(uint24 fee,int24 tick_spacing)" );


    // ━━━━  EIP-712 HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function hash_pool_info( PoolInfo memory pool_info ) internal pure returns ( bytes32 )
    {
        return keccak256( abi.encode( POOL_INFO_TYPEHASH, pool_info.fee, pool_info.tick_spacing ) );
    }


    // ━━━━  POOL KEY BUILDER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function build_pool_key( IERC20 token_in, IERC20 token_out, uint24 fee, int24 tick_spacing, address hook_address )
    internal pure returns ( PoolKey memory )
    {
        ( Currency currency0, Currency currency1 )  =  address(token_in) < address(token_out)
            ? ( Currency.wrap(address(token_in)), Currency.wrap(address(token_out)) )
            : ( Currency.wrap(address(token_out)), Currency.wrap(address(token_in)) );

        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tick_spacing,
            hooks: IHooks(hook_address)
        });
    }


    // ━━━━  STAKE CALCULATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function calculate_swap_stake( IERC20 token, uint256 amount ) internal pure returns ( TokenAmount memory )
    {
        return TokenAmount({ token: token, amount: amount * SWAP_STAKE_PERCENTAGE / 100 });
    }

    function calculate_liquidity_stake( IERC20 token, uint256 amount ) internal pure returns ( TokenAmount memory )
    {
        return TokenAmount({ token: token, amount: amount * LIQUIDITY_STAKE_PERCENTAGE / 100 });
    }

    // ━━━━  PROTOCOL FEE CALCULATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function calculate_protocol_fee( uint256 amount_out, uint24 pool_fee )
    internal pure returns ( uint256 protocol_fee, uint256 user_amount )
    {
        uint256 effective_fee_rate  =  pool_fee < MIN_PROTOCOL_FEE_RATE  ?  MIN_PROTOCOL_FEE_RATE  :  pool_fee;
        protocol_fee                =  amount_out * effective_fee_rate / PROTOCOL_FEE_DIVISOR;
        user_amount                 =  amount_out - protocol_fee;
    }


    // ━━━━  POSITION SALT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // *SECURITY*  -  Positions are owned by the hook contract, so salt must incorporate the user address
    //                to prevent users from interfering with each other's liquidity positions.
    function _position_salt( address user, bytes32 salt ) internal pure returns ( bytes32 result )
    {
        assembly ("memory-safe")
        {
            mstore( 0x00, user )
            mstore( 0x20, salt )
            result  :=  keccak256( 0x00, 0x40 )
        }
    }


    // ━━━━  SETTLEMENT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function settle_and_take(
        IPoolManager pool_manager,
        BondContext memory context,
        IERC20 token_in,
        IERC20 token_out,
        uint256 amount_in,
        uint256 amount_out,
        uint24 pool_fee,
        address hook_address
    ) internal
    {
        Currency currency_in   =  Currency.wrap( address(token_in) );
        Currency currency_out  =  Currency.wrap( address(token_out) );

        pool_manager.sync( currency_in );

        context.send( token_in, amount_in, address(pool_manager) );

        pool_manager.settle( );

        // Protocol fee from output: LPs get full pool fee, SafeSwap takes 10% of LP fee rate (0.01% floor).
        ( uint256 protocol_fee, uint256 user_amount )  =  calculate_protocol_fee( amount_out, pool_fee );

        pool_manager.take( currency_out, context.user, user_amount );
        pool_manager.take( currency_out, hook_address, protocol_fee );
    }
}

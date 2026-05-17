// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/integrations/BondRouteProtected.sol";
import "@SafeSwap/libraries/SafeSwapCommon.sol";
import "@SafeSwap/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct ExactInputSwapParams {
    IERC20 token_out;
    uint256 minimum_amount_out;
    PoolInfo pool_info;
}


/**
 * @title ExactInputSwapLib
 * @notice Library for exact input swap operations via SafeSwap
 * @dev Contains constraint calculation and execution logic for swaps where input amount is specified
 */
library ExactInputSwapLib {
    using FundingsLib for BondContext;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactInputSwap call)"
        "ExactInputSwap(address token_out,uint256 minimum_amount_out,PoolInfo pool_info)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "ExactInputSwap(address token_out,uint256 minimum_amount_out,PoolInfo pool_info)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  223;

    function get_signing_info( ExactInputSwapParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            EIP712_TYPEHASH,
            address(params.token_out),
            params.minimum_amount_out,
            SafeSwapCommon.hash_pool_info( params.pool_info )
        ));

        token_amount_offset  =  EIP712_TOKEN_AMOUNT_OFFSET;
    }


    // ━━━━  GET CONSTRAINTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function get_constraints( ExactInputSwapParams memory params, TokenAmount memory input_token )
    internal pure returns ( BondConstraints memory constraints )
    {
        if(  params.pool_info.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG  )  revert UnsupportedFeeTier( params.pool_info.fee );

        IERC20 token_in    =  input_token.token;
        uint256 amount_in  =  input_token.amount;

        if(  address(token_in) == address(params.token_out)  )  revert( "Tokens must be different" );

        constraints.min_stake  =  SafeSwapCommon.calculate_swap_stake( token_in, amount_in );

        constraints.min_fundings  =  new TokenAmount[](1);
        constraints.min_fundings[ 0 ]  =  TokenAmount({ token: token_in, amount: amount_in });

        constraints.min_execution_delay_in_blocks   =  MIN_EXECUTION_DELAY_IN_BLOCKS;
        constraints.max_execution_delay_in_seconds  =  MAX_SWAP_EXECUTION_DELAY;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute(
        BondContext memory context,
        ExactInputSwapParams memory params,
        IPoolManager pool_manager,
        address hook_address
    ) internal
    {
        // *NOTE*  -  Token in and amount come from fundings. Multi-funding: pick best at execution time.
        IERC20 token_in    =  context.fundings[ 0 ].token;
        uint256 amount_in  =  context.fundings[ 0 ].amount;

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key(
            token_in,
            params.token_out,
            params.pool_info.fee,
            params.pool_info.tick_spacing,
            hook_address
        );

        bool zero_for_one  =  address(token_in) < address(params.token_out);

        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: zero_for_one,
            amountSpecified: -int256(amount_in),
            sqrtPriceLimitX96: zero_for_one ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta  =  pool_manager.swap( pool_key, swap_params, "" );

        // *NOTE*  -  Swap output deltas are ALWAYS positive (pool owes us tokens). Input deltas are ALWAYS negative (we owe pool).
        // This is guaranteed by Uniswap V4 design (see SqrtPriceMath.sol:267-269 and Pool.sol:454-461).
        uint256 pool_output  =  zero_for_one ? uint256(int256(delta.amount1( ))) : uint256(int256(delta.amount0( )));

        // Split the pool output into the user's share and the protocol's share, then enforce slippage on the user's net receipt.
        ( uint256 protocol_fee, uint256 user_output )  =  SafeSwapCommon.calculate_protocol_fee( pool_output, params.pool_info.fee );

        if(  user_output < params.minimum_amount_out  )  revert SlippageExceeded( user_output, params.minimum_amount_out );

        SafeSwapCommon.settle_and_take(
            pool_manager,
            context,
            token_in,
            params.token_out,
            amount_in,
            user_output,
            protocol_fee,
            hook_address
        );
    }
}

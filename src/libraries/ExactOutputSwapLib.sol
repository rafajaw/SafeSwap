// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/integrations/BondRouteProtected.sol";
import "@SafeSwap/libraries/SafeSwapCommon.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct ExactOutputSwapParams {
    IERC20 token_out;
    uint256 amount_out;
    PoolInfo pool_info;
}


/**
 * @title ExactOutputSwapLib
 * @notice Library for exact output swap operations via SafeSwap
 * @dev Contains constraint calculation and execution logic for swaps where output amount is specified
 */
library ExactOutputSwapLib {
    using FundingsLib for BondContext;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,ExactOutputSwap call)"
        "ExactOutputSwap(address token_out,uint256 amount_out,PoolInfo pool_info)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant EIP712_TYPEHASH  =  keccak256(
        "ExactOutputSwap(address token_out,uint256 amount_out,PoolInfo pool_info)"
        "PoolInfo(uint24 fee,int24 tick_spacing)"
    );

    uint256 constant EIP712_TOKEN_AMOUNT_OFFSET  =  217;

    function get_signing_info( ExactOutputSwapParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            EIP712_TYPEHASH,
            address(params.token_out),
            params.amount_out,
            SafeSwapCommon.hash_pool_info( params.pool_info )
        ));

        token_amount_offset  =  EIP712_TOKEN_AMOUNT_OFFSET;
    }


    // ━━━━  GET CONSTRAINTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function get_constraints( ExactOutputSwapParams memory params, TokenAmount memory input_token )
    internal pure returns ( BondConstraints memory constraints )
    {
        IERC20 token_in            =  input_token.token;
        uint256 maximum_amount_in  =  input_token.amount;

        if(  address(token_in) == address(params.token_out)  )  revert( "Tokens must be different" );

        constraints.min_stake  =  SafeSwapCommon.calculate_swap_stake( token_in, maximum_amount_in );

        constraints.min_fundings  =  new TokenAmount[](1);
        constraints.min_fundings[ 0 ]  =  TokenAmount({ token: token_in, amount: maximum_amount_in });

        constraints.min_execution_delay_in_blocks   =  SafeSwapCommon.MIN_EXECUTION_DELAY_IN_BLOCKS;
        constraints.max_execution_delay_in_seconds  =  SafeSwapCommon.MAX_SWAP_EXECUTION_DELAY;
    }


    // ━━━━  EXECUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function execute(
        BondContext memory context,
        ExactOutputSwapParams memory params,
        IPoolManager pool_manager,
        address hook_address
    ) internal
    {
        // *NOTE*  -  Token in and max amount come from fundings. Multi-funding: pick best at execution time.
        IERC20 token_in            =  context.fundings[ 0 ].token;
        uint256 maximum_amount_in  =  context.fundings[ 0 ].amount;

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
            amountSpecified: int256(params.amount_out),
            sqrtPriceLimitX96: zero_for_one ? SafeSwapCommon.MIN_SQRT_PRICE_LIMIT : SafeSwapCommon.MAX_SQRT_PRICE_LIMIT
        });

        BalanceDelta delta  =  pool_manager.swap( pool_key, swap_params, "" );

        // *NOTE*  -  Input delta is ALWAYS negative (we owe pool). Negate to get positive amount for calculation.
        uint256 amount_in  =  zero_for_one ? uint256(-int256(delta.amount0( ))) : uint256(-int256(delta.amount1( )));

        if(  amount_in > maximum_amount_in  )  revert SlippageExceeded( amount_in, maximum_amount_in );

        SafeSwapCommon.settle_and_take(
            pool_manager,
            context,
            token_in,
            params.token_out,
            amount_in,
            params.amount_out,
            params.pool_info.fee,
            hook_address
        );
    }
}

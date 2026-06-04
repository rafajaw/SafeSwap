// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapCommon/Types.sol";
import "@SafeSwapCommon/SafeSwapCommon.sol";
import "@SafeSwapCommon/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { SqrtPriceMath } from "@UniswapV4Core/libraries/SqrtPriceMath.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error InvalidLiquidityModification( uint256 token_id, int128 liquidity_delta, uint256 funding_count );
error PositionInfoMismatch( uint256 token_id );
error ModifyLiquidityTokensMismatch( address token0, address token1, address amount_a_token, address amount_b_token );


// ━━━━  PARAMETERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice Modify-liquidity parameters signed by the user.
 * @param token_id SafeSwap LP NFT id. Use zero only when creating a new position.
 * @param pool_info Target SafeSwap pool configuration.
 * @param tick_lower Lower tick of the liquidity position.
 * @param tick_upper Upper tick of the liquidity position.
 * @param liquidity_delta Single sign-encoded carrier for all four liquidity operations, mirroring
 *        Uniswap V4's own `IPoolManager.ModifyLiquidityParams.liquidityDelta`:
 *          - `> 0`  → create position / add liquidity (settle the deposited tokens)
 *          - `< 0`  → remove liquidity (take the released tokens)
 *          - `== 0` → collect fees (take only accrued fees)
 *        Keeping one carrier (rather than per-op structs) is deliberate: the deployed router is at the
 *        EIP-170 limit, and per-op `unlockCallback` decode paths would overflow it. Per-op clarity
 *        lives in the user-facing functions and EIP-712 signing structs instead.
 * @param minimum_amount_a Minimum actual amount for one of the pool tokens. Token field identifies which token.
 * @param minimum_amount_b Minimum actual amount for the other pool token. Token field identifies which token.
 *
 * @dev For positive `liquidity_delta`, the minimum amounts apply to tokens deposited into the pool.
 *      For negative or zero `liquidity_delta`, they apply to tokens received by the NFT owner.
 */
struct ModifyLiquidityParams {
    uint256 token_id;
    PoolInfo pool_info;
    int24 tick_lower;
    int24 tick_upper;
    int128 liquidity_delta;
    TokenAmount minimum_amount_a;
    TokenAmount minimum_amount_b;
}

/**
 * @notice Create-position parameters signed by the user.
 * @param pool_info Target SafeSwap pool configuration.
 * @param tick_lower Lower tick of the liquidity position.
 * @param tick_upper Upper tick of the liquidity position.
 * @param liquidity Liquidity amount to create.
 * @param sqrt_price_x96 Initial pool price if the pool has not been initialized yet.
 * @param minimum_deposited_a Minimum actual deposited amount for one pool token. Token field identifies which token.
 * @param minimum_deposited_b Minimum actual deposited amount for the other pool token. Token field identifies which token.
 */
struct CreatePositionParams {
    PoolInfo pool_info;
    int24 tick_lower;
    int24 tick_upper;
    uint128 liquidity;
    uint160 sqrt_price_x96;
    TokenAmount minimum_deposited_a;
    TokenAmount minimum_deposited_b;
}

/**
 * @notice Add-liquidity parameters signed by the user.
 * @param token_id SafeSwap LP NFT id receiving more liquidity.
 * @param liquidity Liquidity amount to add.
 * @param minimum_deposited_a Minimum actual deposited amount for one pool token. Token field identifies which token.
 * @param minimum_deposited_b Minimum actual deposited amount for the other pool token. Token field identifies which token.
 */
struct AddPositionLiquidityParams {
    uint256 token_id;
    uint128 liquidity;
    TokenAmount minimum_deposited_a;
    TokenAmount minimum_deposited_b;
}

/**
 * @notice Remove-liquidity parameters signed by the user.
 * @param token_id SafeSwap LP NFT id losing liquidity.
 * @param liquidity Liquidity amount to remove.
 * @param minimum_received_a Minimum received amount for one pool token. Token field identifies which token.
 * @param minimum_received_b Minimum received amount for the other pool token. Token field identifies which token.
 */
struct RemovePositionLiquidityParams {
    uint256 token_id;
    uint128 liquidity;
    TokenAmount minimum_received_a;
    TokenAmount minimum_received_b;
}

/**
 * @notice Collect-fees parameters signed by the user.
 * @param token_id SafeSwap LP NFT id whose accrued fees are collected.
 * @param minimum_received_a Minimum received fee amount for one pool token. Token field identifies which token.
 * @param minimum_received_b Minimum received fee amount for the other pool token. Token field identifies which token.
 */
struct CollectFeesParams {
    uint256 token_id;
    TokenAmount minimum_received_a;
    TokenAmount minimum_received_b;
}


/**
 * @title ModifyLiquidityLib
 * @notice NFT-backed SafeSwap liquidity modification through Uniswap V4 core. Positions are owned by the router
 *         (salt = tokenId); the pool key's hook is the position's config hook. No repricing rebate on liquidity actions.
 */
library ModifyLiquidityLib {
    using FundingsLib for BondContext;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;


    // ━━━━  EIP-712 SIGNING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    string constant CREATE_POSITION_EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,CreatePosition call)"
        "CreatePosition(PoolInfo pool_info,int24 tick_lower,int24 tick_upper,uint128 liquidity,uint160 sqrt_price_x96,TokenAmount minimum_deposited_a,TokenAmount minimum_deposited_b)"
        "PoolInfo(uint16 base_fee_bps,uint8 rebate_percent,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant CREATE_POSITION_EIP712_TYPEHASH  =  keccak256(
        "CreatePosition(PoolInfo pool_info,int24 tick_lower,int24 tick_upper,uint128 liquidity,uint160 sqrt_price_x96,TokenAmount minimum_deposited_a,TokenAmount minimum_deposited_b)"
        "PoolInfo(uint16 base_fee_bps,uint8 rebate_percent,int24 tick_spacing)"
        "TokenAmount(address token,uint256 amount)"
    );

    uint256 constant CREATE_POSITION_EIP712_TOKEN_AMOUNT_OFFSET  =  347;

    string constant ADD_POSITION_LIQUIDITY_EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,AddLiquidity call)"
        "AddLiquidity(uint256 token_id,uint128 liquidity,TokenAmount minimum_deposited_a,TokenAmount minimum_deposited_b)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant ADD_POSITION_LIQUIDITY_EIP712_TYPEHASH  =  keccak256(
        "AddLiquidity(uint256 token_id,uint128 liquidity,TokenAmount minimum_deposited_a,TokenAmount minimum_deposited_b)"
        "TokenAmount(address token,uint256 amount)"
    );

    uint256 constant ADD_POSITION_LIQUIDITY_EIP712_TOKEN_AMOUNT_OFFSET  =  215;

    string constant REMOVE_POSITION_LIQUIDITY_EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,RemoveLiquidity call)"
        "RemoveLiquidity(uint256 token_id,uint128 liquidity,TokenAmount minimum_received_a,TokenAmount minimum_received_b)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant REMOVE_POSITION_LIQUIDITY_EIP712_TYPEHASH  =  keccak256(
        "RemoveLiquidity(uint256 token_id,uint128 liquidity,TokenAmount minimum_received_a,TokenAmount minimum_received_b)"
        "TokenAmount(address token,uint256 amount)"
    );

    uint256 constant REMOVE_POSITION_LIQUIDITY_EIP712_TOKEN_AMOUNT_OFFSET  =  219;

    string constant COLLECT_FEES_EIP712_TYPE_STRING  =
        "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,CollectFees call)"
        "CollectFees(uint256 token_id,TokenAmount minimum_received_a,TokenAmount minimum_received_b)"
        "TokenAmount(address token,uint256 amount)";

    bytes32 constant COLLECT_FEES_EIP712_TYPEHASH  =  keccak256(
        "CollectFees(uint256 token_id,TokenAmount minimum_received_a,TokenAmount minimum_received_b)"
        "TokenAmount(address token,uint256 amount)"
    );

    uint256 constant COLLECT_FEES_EIP712_TOKEN_AMOUNT_OFFSET  =  193;

    function get_create_position_signing_info( CreatePositionParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  CREATE_POSITION_EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            CREATE_POSITION_EIP712_TYPEHASH,
            SafeSwapCommon.hash_pool_info( params.pool_info ),
            params.tick_lower,
            params.tick_upper,
            params.liquidity,
            params.sqrt_price_x96,
            SafeSwapCommon.hash_token_amount( params.minimum_deposited_a ),
            SafeSwapCommon.hash_token_amount( params.minimum_deposited_b )
        ));

        token_amount_offset  =  CREATE_POSITION_EIP712_TOKEN_AMOUNT_OFFSET;
    }

    function get_add_liquidity_signing_info( AddPositionLiquidityParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  ADD_POSITION_LIQUIDITY_EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            ADD_POSITION_LIQUIDITY_EIP712_TYPEHASH,
            params.token_id,
            params.liquidity,
            SafeSwapCommon.hash_token_amount( params.minimum_deposited_a ),
            SafeSwapCommon.hash_token_amount( params.minimum_deposited_b )
        ));

        token_amount_offset  =  ADD_POSITION_LIQUIDITY_EIP712_TOKEN_AMOUNT_OFFSET;
    }

    function get_remove_liquidity_signing_info( RemovePositionLiquidityParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  REMOVE_POSITION_LIQUIDITY_EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            REMOVE_POSITION_LIQUIDITY_EIP712_TYPEHASH,
            params.token_id,
            params.liquidity,
            SafeSwapCommon.hash_token_amount( params.minimum_received_a ),
            SafeSwapCommon.hash_token_amount( params.minimum_received_b )
        ));

        token_amount_offset  =  REMOVE_POSITION_LIQUIDITY_EIP712_TOKEN_AMOUNT_OFFSET;
    }

    function get_collect_fees_signing_info( CollectFeesParams memory params )
    internal pure returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        typed_string  =  COLLECT_FEES_EIP712_TYPE_STRING;

        struct_hash  =  keccak256( abi.encode(
            COLLECT_FEES_EIP712_TYPEHASH,
            params.token_id,
            SafeSwapCommon.hash_token_amount( params.minimum_received_a ),
            SafeSwapCommon.hash_token_amount( params.minimum_received_b )
        ));

        token_amount_offset  =  COLLECT_FEES_EIP712_TOKEN_AMOUNT_OFFSET;
    }


    // ━━━━  GET CONSTRAINTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function get_constraints(
        ModifyLiquidityParams memory params,
        IERC20 preferred_stake_token,
        TokenAmount[] memory preferred_fundings,
        IPoolManager pool_manager,
        SafeSwapPositionInfo memory stored_position_info
    ) internal view returns ( BondConstraints memory constraints )
    {

        _validate_existing_position_mode( params, preferred_fundings.length, stored_position_info );

        PoolKey memory pool_key  =  _pool_key_from_position( stored_position_info );

        constraints.min_stake                       =  _calculate_stake( params, preferred_stake_token, preferred_fundings, pool_manager, pool_key );
        constraints.min_fundings                    =  preferred_fundings;
        constraints.min_execution_delay_in_blocks   =  MIN_BOND_EXECUTION_DELAY_IN_BLOCKS;
        constraints.min_execution_delay_in_seconds  =  MIN_BOND_EXECUTION_DELAY_IN_SECONDS;
        constraints.max_execution_delay_in_seconds  =  MAX_BOND_EXECUTION_DELAY_IN_SECONDS;
    }

    function get_create_position_constraints(
        CreatePositionParams memory params,
        IERC20 preferred_stake_token,
        TokenAmount[] memory preferred_fundings
    ) internal pure returns ( BondConstraints memory constraints )
    {
        if(  params.liquidity == 0  ||  preferred_fundings.length != 2  )
        {
            int128 bounded_liquidity  =  params.liquidity > uint128(type(int128).max)  ?  type(int128).max  :  int128(params.liquidity);
            revert InvalidLiquidityModification({ token_id: 0, liquidity_delta: bounded_liquidity, funding_count: preferred_fundings.length });
        }

        ( IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1 )  =  SafeSwapCommon.sort_token_amount_pair( preferred_fundings[ 0 ], preferred_fundings[ 1 ] );
        _validate_minimum_tokens( token0, token1, params.minimum_deposited_a, params.minimum_deposited_b );

        constraints.min_stake                       =  SafeSwapCommon.calculate_normalized_liquidity_stake(
            params.sqrt_price_x96,
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

    function execute( BondContext memory context, ModifyLiquidityParams memory params, IPoolManager pool_manager, SafeSwapPositionInfo memory position_info ) internal
    {
        ( uint256 amount0_minimum, uint256 amount1_minimum )  =  _validate_minimum_tokens(
            position_info.token0,
            position_info.token1,
            params.minimum_amount_a,
            params.minimum_amount_b
        );

        PoolKey memory pool_key  =  _pool_key_from_position( position_info );

        IPoolManager.ModifyLiquidityParams memory mod_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: params.tick_lower,
            tickUpper: params.tick_upper,
            liquidityDelta: params.liquidity_delta,
            salt: bytes32(params.token_id)
        });

        ( BalanceDelta delta, )  =  pool_manager.modifyLiquidity( pool_key, mod_params, "" );

        if(  params.liquidity_delta > 0  )
        {
            _settle_added_liquidity( context, pool_manager, position_info, delta, amount0_minimum, amount1_minimum );
        }
        else
        {
            _take_removed_liquidity_or_fees( context, pool_manager, position_info, delta, amount0_minimum, amount1_minimum );
        }
    }


    // ━━━━  INTERNAL HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _pool_key_from_position( SafeSwapPositionInfo memory position_info ) private pure returns ( PoolKey memory )
    {
        return PoolKey({
            currency0: Currency.wrap( address(position_info.token0) ),
            currency1: Currency.wrap( address(position_info.token1) ),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: position_info.tick_spacing,
            hooks: IHooks(position_info.hook)
        });
    }

    function _calculate_stake(
        ModifyLiquidityParams memory params,
        IERC20 preferred_stake_token,
        TokenAmount[] memory preferred_fundings,
        IPoolManager pool_manager,
        PoolKey memory pool_key
    ) private view returns ( TokenAmount memory stake )
    {
        ( uint160 sqrt_price_x96, , , )  =  pool_manager.getSlot0( pool_key.toId( ) );

        if(  params.liquidity_delta > 0  )
        {
            ( IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1 )  =  SafeSwapCommon.sort_token_amount_pair( preferred_fundings[ 0 ], preferred_fundings[ 1 ] );

            stake  =  SafeSwapCommon.calculate_normalized_liquidity_stake( sqrt_price_x96, token0, token1, amount0, amount1, preferred_stake_token );
        }
        else
        {
            uint160 sqrt_price_a_x96  =  TickMath.getSqrtPriceAtTick( params.tick_lower );
            uint160 sqrt_price_b_x96  =  TickMath.getSqrtPriceAtTick( params.tick_upper );
            uint128 liquidity         =  params.liquidity_delta < 0  ?  uint128(-params.liquidity_delta)  :  1;

            ( uint256 amount0, uint256 amount1 )  =  _get_amounts_for_liquidity( sqrt_price_x96, sqrt_price_a_x96, sqrt_price_b_x96, liquidity );

            ( IERC20 token0, , IERC20 token1, )  =  SafeSwapCommon.sort_token_amount_pair( params.minimum_amount_a, params.minimum_amount_b );
            stake  =  SafeSwapCommon.calculate_normalized_liquidity_stake( sqrt_price_x96, token0, token1, amount0, amount1, preferred_stake_token );
        }
    }

    function _validate_existing_position_mode( ModifyLiquidityParams memory params, uint256 funding_count, SafeSwapPositionInfo memory position_info ) private pure
    {
        uint256 expected_funding_count  =  params.liquidity_delta > 0  ?  2  :  0;
        if(  funding_count != expected_funding_count  )
        {
            revert InvalidLiquidityModification({ token_id: params.token_id, liquidity_delta: params.liquidity_delta, funding_count: funding_count });
        }

        bool pool_info_matches  =  params.pool_info.base_fee_bps == position_info.base_fee_bps
                                   &&  params.pool_info.rebate_percent == position_info.rebate_percent
                                   &&  params.pool_info.tick_spacing == position_info.tick_spacing;
        bool ticks_match        =  params.tick_lower == position_info.tick_lower  &&  params.tick_upper == position_info.tick_upper;
        if(  pool_info_matches == false  ||  ticks_match == false  )  revert PositionInfoMismatch({ token_id: params.token_id });

        _validate_minimum_tokens( position_info.token0, position_info.token1, params.minimum_amount_a, params.minimum_amount_b );
    }

    function _validate_minimum_tokens( IERC20 token0, IERC20 token1, TokenAmount memory amount_a, TokenAmount memory amount_b )
    private pure returns ( uint256 amount0_minimum, uint256 amount1_minimum )
    {
        bool ordered_ab  =  address(amount_a.token) == address(token0)  &&  address(amount_b.token) == address(token1);
        bool ordered_ba  =  address(amount_a.token) == address(token1)  &&  address(amount_b.token) == address(token0);

        if(  ordered_ab == false  &&  ordered_ba == false  )
        {
            revert ModifyLiquidityTokensMismatch({
                token0:          address(token0),
                token1:          address(token1),
                amount_a_token:  address(amount_a.token),
                amount_b_token:  address(amount_b.token)
            });
        }

        ( amount0_minimum, amount1_minimum )  =  ordered_ab
            ? ( amount_a.amount, amount_b.amount )
            : ( amount_b.amount, amount_a.amount );
    }

    function _settle_added_liquidity(
        BondContext memory context,
        IPoolManager pool_manager,
        SafeSwapPositionInfo memory position_info,
        BalanceDelta delta,
        uint256 amount0_minimum,
        uint256 amount1_minimum
    ) private
    {
        int128 amount0  =  delta.amount0( );
        int128 amount1  =  delta.amount1( );

        if(  amount0 < 0  )
        {
            uint256 amount0_actual  =  uint256(uint128(-amount0));
            if(  amount0_actual < amount0_minimum  )  revert SlippageExceeded({ amount_received: amount0_actual, minimum_required: amount0_minimum });

            SafeSwapCommon.settle_input( pool_manager, context, position_info.token0, amount0_actual );
        }
        else if(  amount0_minimum > 0  )
        {
            revert OneSidedDepositMismatch({ expected_token: address(position_info.token0), minimum_required: amount0_minimum });
        }

        if(  amount1 < 0  )
        {
            uint256 amount1_actual  =  uint256(uint128(-amount1));
            if(  amount1_actual < amount1_minimum  )  revert SlippageExceeded({ amount_received: amount1_actual, minimum_required: amount1_minimum });

            SafeSwapCommon.settle_input( pool_manager, context, position_info.token1, amount1_actual );
        }
        else if(  amount1_minimum > 0  )
        {
            revert OneSidedDepositMismatch({ expected_token: address(position_info.token1), minimum_required: amount1_minimum });
        }
    }

    function _take_removed_liquidity_or_fees(
        BondContext memory context,
        IPoolManager pool_manager,
        SafeSwapPositionInfo memory position_info,
        BalanceDelta delta,
        uint256 amount0_minimum,
        uint256 amount1_minimum
    ) private
    {
        uint256 amount0  =  uint256(uint128(delta.amount0( )));
        uint256 amount1  =  uint256(uint128(delta.amount1( )));

        if(  amount0 < amount0_minimum  )  revert SlippageExceeded({ amount_received: amount0, minimum_required: amount0_minimum });
        if(  amount1 < amount1_minimum  )  revert SlippageExceeded({ amount_received: amount1, minimum_required: amount1_minimum });

        pool_manager.take( Currency.wrap( address(position_info.token0) ), context.user, amount0 );
        pool_manager.take( Currency.wrap( address(position_info.token1) ), context.user, amount1 );
    }

    function _get_amounts_for_liquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) private pure returns ( uint256 amount0, uint256 amount1 )
    {
        if(  sqrtPriceAX96 > sqrtPriceBX96  )
        {
            ( sqrtPriceAX96, sqrtPriceBX96 )  =  ( sqrtPriceBX96, sqrtPriceAX96 );
        }

        if(  sqrtPriceX96 <= sqrtPriceAX96  )
        {
            amount0  =  SqrtPriceMath.getAmount0Delta( sqrtPriceAX96, sqrtPriceBX96, liquidity, false );
        }
        else if(  sqrtPriceX96 < sqrtPriceBX96  )
        {
            amount0  =  SqrtPriceMath.getAmount0Delta( sqrtPriceX96, sqrtPriceBX96, liquidity, false );
            amount1  =  SqrtPriceMath.getAmount1Delta( sqrtPriceAX96, sqrtPriceX96, liquidity, false );
        }
        else
        {
            amount1  =  SqrtPriceMath.getAmount1Delta( sqrtPriceAX96, sqrtPriceBX96, liquidity, false );
        }
    }
}

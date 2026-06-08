// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@BondRouteProtected/BondRouteProtected.sol";
import "@SafeSwapCommon/Types.sol";
import "@SafeSwapCommon/SafeSwapCommon.sol";
import "@SafeSwapCommon/SigningLib.sol";
import "@SafeSwapCommon/Definitions.sol";
import { LibString } from "@Solady/utils/LibString.sol";
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
import { StringHelperLib } from "@SafeSwapNft/libraries/StringHelperLib.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error InvalidLiquidityModification( uint256 token_id, int128 liquidity_delta, uint256 funding_count );
error PositionInfoMismatch( uint256 token_id );
error ModifyLiquidityTokensMismatch( address token0, address token1, address amount_a_token, address amount_b_token );
error FundingDeclarationMismatch( address declared_token, uint256 declared_amount, address funded_token, uint256 funded_amount );


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
 * @param sqrt_price_lower_x96 Lower range bound as a sqrt price. The position tick is derived from it on-chain (snapped to
 *        the pool tick spacing). The receipt signs the human `Range`, never raw ticks — see SIGNING_UX_REFERENCE_2.md.
 * @param sqrt_price_upper_x96 Upper range bound as a sqrt price (derived + snapped to a tick the same way).
 * @param liquidity Liquidity amount to create.
 * @param sqrt_price_x96 Initial pool price (the signed `Price`). Used to initialize the pool if it does not exist yet, and
 *        as the price the deposit is computed at.
 * @param maximum_deposit_a Maximum authorized deposit for token A. Must exactly match one BondRoute funding.
 * @param minimum_deposit_a Minimum actual amount of token A that must be deposited.
 * @param maximum_deposit_b Maximum authorized deposit for token B. Must exactly match the other BondRoute funding.
 * @param minimum_deposit_b Minimum actual amount of token B that must be deposited.
 *
 * @dev *SOURCE OF TRUTH*  -  The signed price is authoritative; ticks are derived from `sqrt_price_lower_x96` /
 *      `sqrt_price_upper_x96` by snapping to tick spacing (`derive_ticks_from_price_bounds`). The snapped ticks therefore
 *      drift sub-display-precision from the exact signed bounds; that drift is bounded by the committed `minimum_deposit_*`
 *      floors (a manipulated range that moved real deposits would breach them and revert).
 */
struct CreatePositionParams {
    PoolInfo pool_info;
    uint160 sqrt_price_lower_x96;
    uint160 sqrt_price_upper_x96;
    uint128 liquidity;
    uint160 sqrt_price_x96;
    TokenAmount maximum_deposit_a;
    uint256 minimum_deposit_a;
    TokenAmount maximum_deposit_b;
    uint256 minimum_deposit_b;
}

/**
 * @notice Add-liquidity parameters signed by the user.
 * @param token_id SafeSwap LP NFT id receiving more liquidity.
 * @param liquidity Liquidity amount to add.
 * @param maximum_deposit_a Maximum authorized deposit for token A. Must exactly match one BondRoute funding.
 * @param minimum_deposit_a Minimum actual amount of token A that must be deposited.
 * @param maximum_deposit_b Maximum authorized deposit for token B. Must exactly match the other BondRoute funding.
 * @param minimum_deposit_b Minimum actual amount of token B that must be deposited.
 */
struct AddPositionLiquidityParams {
    uint256 token_id;
    uint128 liquidity;
    TokenAmount maximum_deposit_a;
    uint256 minimum_deposit_a;
    TokenAmount maximum_deposit_b;
    uint256 minimum_deposit_b;
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


    // ━━━━  EIP-712 SIGNING (SIGNING_UX_REFERENCE_2)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //
    // Each LP action signs the locked symbolic receipt: role-named single-word fields, each token symbol once per role,
    // amounts at FULL_PRECISION, the two pool tokens kept as raw address anchors named by their (sanitized) symbol — token1
    // first, token0 second. Create signs the human Range / Price (token0-per-token1); raw ticks / sqrtPrice never appear.
    // Create derives Deposit from committed liquidity + range + price. Add signs its explicit maximum deposits, which must
    // exactly match the BondRoute funding envelope, so its digest never depends on mutable pool state.

    string constant CREATE_FIELD_DECLARATION   =  "CreatePosition sS__CREATE_POSITION__Ss";
    string constant ADD_FIELD_DECLARATION      =  "AddLiquidity sS__ADD_LIQUIDITY__Ss";
    string constant REMOVE_FIELD_DECLARATION   =  "RemoveLiquidity sS__REMOVE_LIQUIDITY__Ss";
    string constant COLLECT_FIELD_DECLARATION  =  "CollectFees sS__COLLECT_FEES__Ss";

    // Resolved pool-token pair: addresses (the raw anchors) plus the once-read symbol / decimals reused across the fields.
    struct _PoolTokens {
        address token0;
        address token1;
        uint8 decimals0;
        uint8 decimals1;
        string symbol0;
        string symbol1;
    }

    function get_create_position_signing_info( CreatePositionParams memory params )
    internal view returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        ( IERC20 token0, uint256 minimum0, IERC20 token1, uint256 minimum1 )  =  _resolve_create_amounts( params );
        _PoolTokens memory tokens  =  _resolve_pool_tokens( token0, token1 );

        string memory inner_definition  =  string.concat(
            "CreatePosition(string Deposit,string Minimum,string Liquidity,string Range,string Price,string Pool,string Warning,address ",
            tokens.symbol1, ",address ", tokens.symbol0, ")"
        );

        ( typed_string, token_amount_offset )  =  SigningLib.build_typed_string( CREATE_FIELD_DECLARATION, inner_definition );
        struct_hash  =  _create_struct_hash( params, tokens, minimum0, minimum1, inner_definition );
    }

    function get_create_position_signing_values( CreatePositionParams memory params )
    internal view returns ( string[] memory display_values, address[] memory token_addresses )
    {
        ( IERC20 token0, uint256 minimum0, IERC20 token1, uint256 minimum1 )  =  _resolve_create_amounts( params );
        _PoolTokens memory tokens  =  _resolve_pool_tokens( token0, token1 );
        ( uint256 deposit0, uint256 deposit1 )  =  SigningLib.calculate_amounts_for_liquidity( params.sqrt_price_x96, params.sqrt_price_lower_x96, params.sqrt_price_upper_x96, params.liquidity );

        display_values     =  new string[]( 7 );
        display_values[0]  =  SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_MOST, deposit1, tokens.decimals1, tokens.symbol1, deposit0, tokens.decimals0, tokens.symbol0 );
        display_values[1]  =  SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_LEAST, minimum1, tokens.decimals1, tokens.symbol1, minimum0, tokens.decimals0, tokens.symbol0 );
        display_values[2]  =  LibString.toString( uint256(params.liquidity) );
        display_values[3]  =  SigningLib.render_range_value( params.sqrt_price_lower_x96, params.sqrt_price_upper_x96, tokens.decimals0, tokens.decimals1, tokens.symbol0, tokens.symbol1 );
        display_values[4]  =  SigningLib.render_price_value( params.sqrt_price_x96, tokens.decimals0, tokens.decimals1, tokens.symbol0, tokens.symbol1 );
        display_values[5]  =  SigningLib.render_pool_value( params.pool_info );
        display_values[6]  =  SigningLib.WARNING_VALUE;

        token_addresses     =  new address[]( 2 );
        token_addresses[0]  =  tokens.token1;
        token_addresses[1]  =  tokens.token0;
    }

    function get_add_liquidity_signing_info( AddPositionLiquidityParams memory params, SafeSwapPositionInfo memory position_info )
    internal view returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        _PoolTokens memory tokens  =  _resolve_pool_tokens( position_info.token0, position_info.token1 );
        ( uint256 maximum0, uint256 minimum0, uint256 maximum1, uint256 minimum1 )  =  _resolve_add_amounts( params, position_info );

        string memory inner_definition  =  string.concat(
            "AddLiquidity(string Position,string Deposit,string Minimum,string Liquidity,string Pool,string Warning,address ",
            tokens.symbol1, ",address ", tokens.symbol0, ")"
        );

        ( typed_string, token_amount_offset )  =  SigningLib.build_typed_string( ADD_FIELD_DECLARATION, inner_definition );
        struct_hash  =  _add_struct_hash( params, position_info, tokens, maximum0, minimum0, maximum1, minimum1, inner_definition );
    }

    function get_add_liquidity_signing_values( AddPositionLiquidityParams memory params, SafeSwapPositionInfo memory position_info )
    internal view returns ( string[] memory display_values, address[] memory token_addresses )
    {
        _PoolTokens memory tokens  =  _resolve_pool_tokens( position_info.token0, position_info.token1 );
        ( uint256 maximum0, uint256 minimum0, uint256 maximum1, uint256 minimum1 )  =  _resolve_add_amounts( params, position_info );

        display_values     =  new string[]( 6 );
        display_values[0]  =  SigningLib.render_position_value( params.token_id );
        display_values[1]  =  SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_MOST, maximum1, tokens.decimals1, tokens.symbol1, maximum0, tokens.decimals0, tokens.symbol0 );
        display_values[2]  =  SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_LEAST, minimum1, tokens.decimals1, tokens.symbol1, minimum0, tokens.decimals0, tokens.symbol0 );
        display_values[3]  =  LibString.toString( uint256(params.liquidity) );
        display_values[4]  =  SigningLib.render_pool_value( _pool_info_of( position_info ) );
        display_values[5]  =  SigningLib.WARNING_VALUE;

        token_addresses     =  new address[]( 2 );
        token_addresses[0]  =  tokens.token1;
        token_addresses[1]  =  tokens.token0;
    }

    function get_remove_liquidity_signing_info( RemovePositionLiquidityParams memory params, SafeSwapPositionInfo memory position_info )
    internal view returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        _PoolTokens memory tokens  =  _resolve_pool_tokens( position_info.token0, position_info.token1 );
        ( , uint256 received0, , uint256 received1 )  =  SafeSwapCommon.sort_token_amount_pair( params.minimum_received_a, params.minimum_received_b );

        string memory inner_definition  =  string.concat(
            "RemoveLiquidity(string Position,string Burn,string Receive,string Pool,string Warning,address ",
            tokens.symbol1, ",address ", tokens.symbol0, ")"
        );

        ( typed_string, token_amount_offset )  =  SigningLib.build_typed_string( REMOVE_FIELD_DECLARATION, inner_definition );

        struct_hash  =  SigningLib.hash_words(
            SigningLib.hash_string( inner_definition ),
            SigningLib.hash_string( SigningLib.render_position_value( params.token_id ) ),
            SigningLib.hash_string( SigningLib.render_burn_value( params.liquidity ) ),
            SigningLib.hash_string( SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_LEAST, received1, tokens.decimals1, tokens.symbol1, received0, tokens.decimals0, tokens.symbol0 ) ),
            SigningLib.hash_string( SigningLib.render_pool_value( _pool_info_of( position_info ) ) ),
            SigningLib.WARNING_VALUE_HASH,
            SigningLib.encode_address_word( tokens.token1 ),
            SigningLib.encode_address_word( tokens.token0 )
        );
    }

    function get_remove_liquidity_signing_values( RemovePositionLiquidityParams memory params, SafeSwapPositionInfo memory position_info )
    internal view returns ( string[] memory display_values, address[] memory token_addresses )
    {
        _PoolTokens memory tokens  =  _resolve_pool_tokens( position_info.token0, position_info.token1 );
        ( , uint256 received0, , uint256 received1 )  =  SafeSwapCommon.sort_token_amount_pair( params.minimum_received_a, params.minimum_received_b );

        display_values     =  new string[]( 5 );
        display_values[0]  =  SigningLib.render_position_value( params.token_id );
        display_values[1]  =  SigningLib.render_burn_value( params.liquidity );
        display_values[2]  =  SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_LEAST, received1, tokens.decimals1, tokens.symbol1, received0, tokens.decimals0, tokens.symbol0 );
        display_values[3]  =  SigningLib.render_pool_value( _pool_info_of( position_info ) );
        display_values[4]  =  SigningLib.WARNING_VALUE;

        token_addresses     =  new address[]( 2 );
        token_addresses[0]  =  tokens.token1;
        token_addresses[1]  =  tokens.token0;
    }

    function get_collect_fees_signing_info( CollectFeesParams memory params, SafeSwapPositionInfo memory position_info )
    internal view returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        _PoolTokens memory tokens  =  _resolve_pool_tokens( position_info.token0, position_info.token1 );
        ( , uint256 received0, , uint256 received1 )  =  SafeSwapCommon.sort_token_amount_pair( params.minimum_received_a, params.minimum_received_b );

        string memory inner_definition  =  string.concat(
            "CollectFees(string Position,string Receive,string Pool,string Warning,address ",
            tokens.symbol1, ",address ", tokens.symbol0, ")"
        );

        ( typed_string, token_amount_offset )  =  SigningLib.build_typed_string( COLLECT_FIELD_DECLARATION, inner_definition );

        struct_hash  =  SigningLib.hash_words(
            SigningLib.hash_string( inner_definition ),
            SigningLib.hash_string( SigningLib.render_position_value( params.token_id ) ),
            SigningLib.hash_string( SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_LEAST, received1, tokens.decimals1, tokens.symbol1, received0, tokens.decimals0, tokens.symbol0 ) ),
            SigningLib.hash_string( SigningLib.render_pool_value( _pool_info_of( position_info ) ) ),
            SigningLib.WARNING_VALUE_HASH,
            SigningLib.encode_address_word( tokens.token1 ),
            SigningLib.encode_address_word( tokens.token0 )
        );
    }

    function get_collect_fees_signing_values( CollectFeesParams memory params, SafeSwapPositionInfo memory position_info )
    internal view returns ( string[] memory display_values, address[] memory token_addresses )
    {
        _PoolTokens memory tokens  =  _resolve_pool_tokens( position_info.token0, position_info.token1 );
        ( , uint256 received0, , uint256 received1 )  =  SafeSwapCommon.sort_token_amount_pair( params.minimum_received_a, params.minimum_received_b );

        display_values     =  new string[]( 4 );
        display_values[0]  =  SigningLib.render_position_value( params.token_id );
        display_values[1]  =  SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_LEAST, received1, tokens.decimals1, tokens.symbol1, received0, tokens.decimals0, tokens.symbol0 );
        display_values[2]  =  SigningLib.render_pool_value( _pool_info_of( position_info ) );
        display_values[3]  =  SigningLib.WARNING_VALUE;

        token_addresses     =  new address[]( 2 );
        token_addresses[0]  =  tokens.token1;
        token_addresses[1]  =  tokens.token0;
    }


    // ━━━━  SIGNING HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _resolve_pool_tokens( IERC20 token0, IERC20 token1 ) private view returns ( _PoolTokens memory tokens )
    {
        tokens.token0    =  address(token0);
        tokens.token1    =  address(token1);
        tokens.decimals0 =  StringHelperLib.get_token_decimals( token0 );
        tokens.decimals1 =  StringHelperLib.get_token_decimals( token1 );
        tokens.symbol0   =  StringHelperLib.get_sanitized_token_symbol( token0 );
        tokens.symbol1   =  StringHelperLib.get_sanitized_token_symbol( token1 );
    }

    function _create_struct_hash( CreatePositionParams memory params, _PoolTokens memory tokens, uint256 minimum0, uint256 minimum1, string memory inner_definition )
    private pure returns ( bytes32 )
    {
        ( uint256 deposit0, uint256 deposit1 )  =  SigningLib.calculate_amounts_for_liquidity( params.sqrt_price_x96, params.sqrt_price_lower_x96, params.sqrt_price_upper_x96, params.liquidity );

        return SigningLib.hash_words(
            SigningLib.hash_string( inner_definition ),
            SigningLib.hash_string( SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_MOST, deposit1, tokens.decimals1, tokens.symbol1, deposit0, tokens.decimals0, tokens.symbol0 ) ),
            SigningLib.hash_string( SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_LEAST, minimum1, tokens.decimals1, tokens.symbol1, minimum0, tokens.decimals0, tokens.symbol0 ) ),
            SigningLib.hash_string( LibString.toString( uint256(params.liquidity) ) ),
            SigningLib.hash_string( SigningLib.render_range_value( params.sqrt_price_lower_x96, params.sqrt_price_upper_x96, tokens.decimals0, tokens.decimals1, tokens.symbol0, tokens.symbol1 ) ),
            SigningLib.hash_string( SigningLib.render_price_value( params.sqrt_price_x96, tokens.decimals0, tokens.decimals1, tokens.symbol0, tokens.symbol1 ) ),
            SigningLib.hash_string( SigningLib.render_pool_value( params.pool_info ) ),
            SigningLib.WARNING_VALUE_HASH,
            SigningLib.encode_address_word( tokens.token1 ),
            SigningLib.encode_address_word( tokens.token0 )
        );
    }

    function _add_struct_hash(
        AddPositionLiquidityParams memory params,
        SafeSwapPositionInfo memory position_info,
        _PoolTokens memory tokens,
        uint256 maximum0,
        uint256 minimum0,
        uint256 maximum1,
        uint256 minimum1,
        string memory inner_definition
    ) private pure returns ( bytes32 )
    {
        return SigningLib.hash_words(
            SigningLib.hash_string( inner_definition ),
            SigningLib.hash_string( SigningLib.render_position_value( params.token_id ) ),
            SigningLib.hash_string( SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_MOST, maximum1, tokens.decimals1, tokens.symbol1, maximum0, tokens.decimals0, tokens.symbol0 ) ),
            SigningLib.hash_string( SigningLib.render_pair_amount_value( SigningLib.OPERATOR_AT_LEAST, minimum1, tokens.decimals1, tokens.symbol1, minimum0, tokens.decimals0, tokens.symbol0 ) ),
            SigningLib.hash_string( LibString.toString( uint256(params.liquidity) ) ),
            SigningLib.hash_string( SigningLib.render_pool_value( _pool_info_of( position_info ) ) ),
            SigningLib.WARNING_VALUE_HASH,
            SigningLib.encode_address_word( tokens.token1 ),
            SigningLib.encode_address_word( tokens.token0 )
        );
    }

    function validate_create_fundings( CreatePositionParams memory params, TokenAmount[] memory fundings )
    internal pure
    {
        _validate_declared_fundings( 0, params.liquidity, params.maximum_deposit_a, params.maximum_deposit_b, fundings );
    }

    function validate_add_fundings( AddPositionLiquidityParams memory params, TokenAmount[] memory fundings )
    internal pure
    {
        _validate_declared_fundings( params.token_id, params.liquidity, params.maximum_deposit_a, params.maximum_deposit_b, fundings );
    }

    function _validate_declared_fundings(
        uint256 token_id,
        uint128 liquidity,
        TokenAmount memory maximum_deposit_a,
        TokenAmount memory maximum_deposit_b,
        TokenAmount[] memory fundings
    ) private pure
    {
        if(  fundings.length != 2  )
        {
            int128 bounded_liquidity  =  liquidity > uint128(type(int128).max)  ?  type(int128).max  :  int128(liquidity);
            revert InvalidLiquidityModification({ token_id: token_id, liquidity_delta: bounded_liquidity, funding_count: fundings.length });
        }

        _validate_declared_funding( maximum_deposit_a, fundings );
        _validate_declared_funding( maximum_deposit_b, fundings );
    }

    function _validate_declared_funding( TokenAmount memory declared, TokenAmount[] memory fundings ) private pure
    {
        for(  uint256 i = 0  ;  i < 2  ;  i = i + 1  )
        {
            if(  address(fundings[i].token) != address(declared.token)  )  continue;
            if(  fundings[i].amount == declared.amount  )  return;

            revert FundingDeclarationMismatch({
                declared_token:  address(declared.token),
                declared_amount: declared.amount,
                funded_token:    address(fundings[i].token),
                funded_amount:   fundings[i].amount
            });
        }

        revert FundingDeclarationMismatch({
            declared_token:  address(declared.token),
            declared_amount: declared.amount,
            funded_token:    address(0),
            funded_amount:   0
        });
    }

    function _resolve_create_amounts( CreatePositionParams memory params )
    private pure returns ( IERC20 token0, uint256 minimum0, IERC20 token1, uint256 minimum1 )
    {
        TokenAmount memory minimum_deposit_a  =  TokenAmount({ token: params.maximum_deposit_a.token, amount: params.minimum_deposit_a });
        TokenAmount memory minimum_deposit_b  =  TokenAmount({ token: params.maximum_deposit_b.token, amount: params.minimum_deposit_b });
        return SafeSwapCommon.sort_token_amount_pair( minimum_deposit_a, minimum_deposit_b );
    }

    function _resolve_add_amounts( AddPositionLiquidityParams memory params, SafeSwapPositionInfo memory position_info )
    private pure returns ( uint256 maximum0, uint256 minimum0, uint256 maximum1, uint256 minimum1 )
    {
        bool ordered_ab  =  address(params.maximum_deposit_a.token) == address(position_info.token0)
                            &&  address(params.maximum_deposit_b.token) == address(position_info.token1);
        bool ordered_ba  =  address(params.maximum_deposit_a.token) == address(position_info.token1)
                            &&  address(params.maximum_deposit_b.token) == address(position_info.token0);

        if(  ordered_ab == false  &&  ordered_ba == false  )
        {
            revert ModifyLiquidityTokensMismatch({
                token0:          address(position_info.token0),
                token1:          address(position_info.token1),
                amount_a_token:  address(params.maximum_deposit_a.token),
                amount_b_token:  address(params.maximum_deposit_b.token)
            });
        }

        return ordered_ab
            ? ( params.maximum_deposit_a.amount, params.minimum_deposit_a, params.maximum_deposit_b.amount, params.minimum_deposit_b )
            : ( params.maximum_deposit_b.amount, params.minimum_deposit_b, params.maximum_deposit_a.amount, params.minimum_deposit_a );
    }

    function _pool_info_of( SafeSwapPositionInfo memory position_info ) private pure returns ( PoolInfo memory )
    {
        return PoolInfo({ base_fee_bps: position_info.base_fee_bps, rebate_percent: position_info.rebate_percent, tick_spacing: position_info.tick_spacing });
    }


    // ━━━━  PRICE → TICK DERIVATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Derive the position ticks from the signed sqrt-price bounds, snapping to the pool's tick spacing. The lower
     *         bound floors toward -infinity and the upper bound ceils toward +infinity, so the snapped range always contains
     *         the signed range and the two ticks never collapse. Result is clamped to the usable tick range for the spacing.
     * @dev Fixed, deterministic rule — the signed price is the source of truth and these ticks are reproduced from it.
     */
    function derive_ticks_from_price_bounds( uint160 sqrt_price_lower_x96, uint160 sqrt_price_upper_x96, int24 tick_spacing )
    internal pure returns ( int24 tick_lower, int24 tick_upper )
    {
        int24 raw_lower  =  TickMath.getTickAtSqrtPrice( sqrt_price_lower_x96 );
        int24 raw_upper  =  TickMath.getTickAtSqrtPrice( sqrt_price_upper_x96 );

        if(  raw_lower > raw_upper  )  ( raw_lower, raw_upper )  =  ( raw_upper, raw_lower );

        int24 min_usable  =  TickMath.minUsableTick( tick_spacing );
        int24 max_usable  =  TickMath.maxUsableTick( tick_spacing );

        tick_lower  =  _clamp_tick( _floor_to_spacing( raw_lower, tick_spacing ), min_usable, max_usable );
        tick_upper  =  _clamp_tick( _ceil_to_spacing( raw_upper, tick_spacing ), min_usable, max_usable );
    }

    function _floor_to_spacing( int24 tick, int24 tick_spacing ) private pure returns ( int24 )
    {
        int24 rounded  =  ( tick / tick_spacing ) * tick_spacing;    // truncates toward zero.
        if(  tick < 0  &&  tick % tick_spacing != 0  )  rounded  =  rounded - tick_spacing;
        return rounded;
    }

    function _ceil_to_spacing( int24 tick, int24 tick_spacing ) private pure returns ( int24 )
    {
        int24 rounded  =  ( tick / tick_spacing ) * tick_spacing;    // truncates toward zero.
        if(  tick > 0  &&  tick % tick_spacing != 0  )  rounded  =  rounded + tick_spacing;
        return rounded;
    }

    function _clamp_tick( int24 tick, int24 min_usable, int24 max_usable ) private pure returns ( int24 )
    {
        if(  tick < min_usable  )  return min_usable;
        if(  tick > max_usable  )  return max_usable;
        return tick;
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
        IERC20 preferred_stake_token
    ) internal pure returns ( BondConstraints memory constraints )
    {
        if(  params.liquidity == 0  )
        {
            int128 bounded_liquidity  =  params.liquidity > uint128(type(int128).max)  ?  type(int128).max  :  int128(params.liquidity);
            revert InvalidLiquidityModification({ token_id: 0, liquidity_delta: bounded_liquidity, funding_count: 2 });
        }

        TokenAmount[] memory declared_fundings  =  new TokenAmount[](2);
        declared_fundings[0]                    =  params.maximum_deposit_a;
        declared_fundings[1]                    =  params.maximum_deposit_b;

        ( IERC20 token0, uint256 amount0, IERC20 token1, uint256 amount1 )  =  SafeSwapCommon.sort_token_amount_pair( declared_fundings[ 0 ], declared_fundings[ 1 ] );
        constraints.min_stake                       =  SafeSwapCommon.calculate_normalized_liquidity_stake(
            params.sqrt_price_x96,
            token0,
            token1,
            amount0,
            amount1,
            preferred_stake_token
        );
        constraints.min_fundings                    =  declared_fundings;
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

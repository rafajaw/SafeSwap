// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwap/UniswapHook.sol";
import "@SafeSwap/integrations/BondRouteProtected.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolId } from "@UniswapV4Core/types/PoolId.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";

using StateLibrary for IPoolManager;


/**
 * @title User
 * @notice User-facing SafeSwap operations and position helper functions.
 */
abstract contract User is UniswapHook, BondRouteProtected {

    constructor( )
    UniswapHook( )
    BondRouteProtected( SAFESWAP_PROTOCOL_NAME, SAFESWAP_PROTOCOL_DESCRIPTION ) { }

    // ━━━━  USER FUNCTIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Execute an exact-input Uniswap V4 swap through BondRoute.
     * @param params Swap output token, minimum net output, and pool configuration.
     *
     * @dev BONDROUTE EXECUTION:
     *      - Callable only through a valid BondRoute bond.
     *      - Input token and input amount come from the bond fundings, not from `params`.
     *      - Stake is quoted as `SWAP_STAKE_PERCENTAGE` of the committed input amount.
     *
     * @dev POOL COMPATIBILITY:
     *      - Inherits Uniswap V4 PoolManager token compatibility; SafeSwap adds BondRoute gating, not custom token accounting.
     *      - Dynamic-fee pools are not supported.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if called outside BondRoute.
     *      - `SlippageExceeded(uint256 amount_received, uint256 minimum_required)` if net output is below `minimum_amount_out`.
     *      - `UnsupportedFeeTier(uint24 fee)` if the target pool uses dynamic fees.
     */
    function swap_exact_input( ExactInputSwapParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.ExactInputSwap)), abi.encode( context, params ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Execute an exact-output Uniswap V4 swap through BondRoute.
     * @param params Swap output token, exact net output amount, and pool configuration.
     *
     * @dev BONDROUTE EXECUTION:
     *      - Callable only through a valid BondRoute bond.
     *      - Input token and maximum input amount come from the bond fundings, not from `params`.
     *      - SafeSwap grosses up the pool output so the user receives `amount_out` after protocol fee.
     *
     * @dev POOL COMPATIBILITY:
     *      - Inherits Uniswap V4 PoolManager token compatibility; SafeSwap adds BondRoute gating, not custom token accounting.
     *      - Dynamic-fee pools are not supported.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if called outside BondRoute.
     *      - `SlippageExceeded(uint256 amount_received, uint256 minimum_required)` if required input exceeds the committed maximum.
     *      - `UnsupportedFeeTier(uint24 fee)` if the target pool uses dynamic fees.
     */
    function swap_exact_output( ExactOutputSwapParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.ExactOutputSwap)), abi.encode( context, params ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Add liquidity to a Uniswap V4 position through BondRoute.
     * @param params Pool configuration, tick range, and minimum deposited amounts.
     *
     * @dev BONDROUTE EXECUTION:
     *      - Callable only through a valid BondRoute bond.
     *      - Token0, token1, and desired amounts come from the two bond fundings, not from `params`.
     *      - Stake is quoted as `LIQUIDITY_STAKE_PERCENTAGE` of total normalized value, denominated in token0.
     *
     * @dev POSITION OWNERSHIP:
     *      Positions are owned by the hook contract under the user's address as the V4 salt, so each user has
     *      exactly one position per `(pool, tick_lower, tick_upper)`; subsequent adds to the same range merge in.
     *
     * @dev POOL COMPATIBILITY:
     *      - Inherits Uniswap V4 PoolManager token compatibility; SafeSwap adds BondRoute gating, not custom token accounting.
     *      - Dynamic-fee pools are not supported.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if called outside BondRoute.
     *      - `OneSidedDepositMismatch(address expected_token, uint256 minimum_required)` if a one-sided range consumes the wrong side.
     *      - `SlippageExceeded(uint256 amount_received, uint256 minimum_required)` if actual deposited amounts are below user minimums.
     */
    function add_liquidity( AddLiquidityParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.AddLiquidity)), abi.encode( context, params ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Remove liquidity from a SafeSwap-owned Uniswap V4 position through BondRoute.
     * @param params Pool tokens, pool configuration, tick range, liquidity amount, and minimum outputs.
     *
     * @dev BONDROUTE EXECUTION:
     *      - Callable only through a valid BondRoute bond.
     *      - No fundings are required; stake is quoted from the current token0-normalized value of removed liquidity.
     *      - Withdrawn tokens are sent directly to the BondRoute user.
     *
     * @dev POOL COMPATIBILITY:
     *      - Inherits Uniswap V4 PoolManager token compatibility; SafeSwap adds BondRoute gating, not custom token accounting.
     *      - Dynamic-fee pools are not supported.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if called outside BondRoute.
     *      - `SlippageExceeded(uint256 amount_received, uint256 minimum_required)` if received token amounts are below user minimums.
     *      - `UnsupportedFeeTier(uint24 fee)` if the target pool uses dynamic fees.
     */
    function remove_liquidity( RemoveLiquidityParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.RemoveLiquidity)), abi.encode( context, params ) );
        PoolManager.unlock( data );
    }

    /**
     * @notice Donate tokens to a Uniswap V4 pool through BondRoute.
     * @param params Pool configuration.
     *
     * @dev BONDROUTE EXECUTION:
     *      - Callable only through a valid BondRoute bond.
     *      - Token0, token1, and donation amounts come from the two bond fundings, not from `params`.
     *      - Stake is quoted as `LIQUIDITY_STAKE_PERCENTAGE` of total normalized value, denominated in token0.
     *
     * @dev POOL COMPATIBILITY:
     *      - Inherits Uniswap V4 PoolManager token compatibility; SafeSwap adds BondRoute gating, not custom token accounting.
     *      - Dynamic-fee pools are not supported.
     *
     * @dev ERROR CODES:
     *      - `Unauthorized(address caller, address expected)` if called outside BondRoute.
     *      - `UnsupportedFeeTier(uint24 fee)` if the target pool uses dynamic fees.
     */
    function donate( DonateParams calldata params )
    external
    {
        BondContext memory context  =  BondRoute_initialize( );

        bytes memory data  =  bytes.concat( bytes1(uint8(Action.Donate)), abi.encode( context, params ) );
        PoolManager.unlock( data );
    }


    // ━━━━  POSITION GETTERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Read a user's SafeSwap LP position state directly from the PoolManager.
     * @param pool_id Uniswap V4 pool identifier.
     * @param user SafeSwap user whose position should be queried.
     * @param tick_lower Lower tick of the position.
     * @param tick_upper Upper tick of the position.
     * @return liquidity Current position liquidity.
     * @return fee_growth_inside_0_last_x128 Last recorded token0 fee growth inside the tick range.
     * @return fee_growth_inside_1_last_x128 Last recorded token1 fee growth inside the tick range.
     *
     * @dev Positions are owned by the hook with the user's address as the V4 salt. This lets users or aggregators
     *      inspect positions directly from the PoolManager.
     */
    function get_position_info( PoolId pool_id, address user, int24 tick_lower, int24 tick_upper )
    external  view  returns ( uint128 liquidity, uint256 fee_growth_inside_0_last_x128, uint256 fee_growth_inside_1_last_x128 )
    {
        ( liquidity, fee_growth_inside_0_last_x128, fee_growth_inside_1_last_x128 )  =  PoolManager.getPositionInfo(
            pool_id,
            address(this),
            tick_lower,
            tick_upper,
            bytes32(uint256(uint160(user)))
        );
    }
}

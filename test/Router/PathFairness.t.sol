// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPathFairnessTests } from "@test/Router/TestManifest.sol";
import { SafeSwapRealEnv } from "@test/helpers/SafeSwapRealEnv.t.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";

import { PoolInfo } from "@SafeSwapCommon/Types.sol";
import { CreatePositionParams } from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";
import { ExactInputSwapParams } from "@SafeSwapRouter/libraries/ExactInputSwapLib.sol";
import { BondStatus } from "@BondRoute/Definitions.sol";
import { IBondRouteProtected, IERC20, TokenAmount } from "@BondRouteProtected/BondRouteProtected.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";


interface IV4DonateRouter {
    function donate( PoolKey memory key, uint256 amount0, uint256 amount1, bytes memory hookData ) external payable;
}

interface IV4TestRouterDeployer {
    function deploy_donate_router( address manager ) external returns ( address );
}


/**
 * @title PathFairnessTest
 * @notice End-to-end dynamic-fee path-fairness tests. Swaps go through the real SafeSwap router, hook, BondRoute, and V4
 *         PoolManager; fee-growth assertions read the real V4 pool state for adjacent ranges that a swap crosses.
 */
contract PathFairnessTest is IPathFairnessTests, SafeSwapRealEnv {

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant _USER  =  address(0xA11CE);

    uint16 internal constant _BASE_FEE_BPS     =  30;
    uint8  internal constant _CAPTURE_PERCENT  =  50;
    int24  internal constant _TICK_SPACING     =  60;
    int24  internal constant _LEFT_LOWER       =  -120;
    int24  internal constant _LEFT_UPPER       =  0;
    int24  internal constant _RIGHT_LOWER      =  0;
    int24  internal constant _RIGHT_UPPER      =  120;
    int24  internal constant _START_TICK_UP    =  60;
    uint128 internal constant _RANGE_LIQUIDITY =  100_000 ether;

    TestERC20 internal _token_a;
    TestERC20 internal _token_b;
    address   internal _hook;
    IV4DonateRouter internal _donate_router;

    struct FeeGrowth {
        uint256 token0;
        uint256 token1;
    }

    function setUp( ) public
    {
        _setup_real_env( );

        _hook     =  _register_hook( _BASE_FEE_BPS, _CAPTURE_PERCENT );
        _token_a  =  _new_token( "Token A", "TKNA" );
        _token_b  =  _new_token( "Token B", "TKNB" );

        _fund_and_approve( _USER, _token_a, 100_000_000 ether );
        _fund_and_approve( _USER, _token_b, 100_000_000 ether );

        address router_deployer  =  deployCode( "ForceCompileV4.sol:V4TestRouterDeployer" );
        _donate_router           =  IV4DonateRouter( IV4TestRouterDeployer(router_deployer).deploy_donate_router( address(poolManager) ) );

        _token0().approve( address(_donate_router), type(uint256).max );
        _token1().approve( address(_donate_router), type(uint256).max );
        TestERC20(address(_token0())).mint( address(this), 1_000_000 ether );
        TestERC20(address(_token1())).mint( address(this), 1_000_000 ether );
    }


    // ━━━━  PATH FAIRNESS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_dynamic_fee_increases_fee_growth_for_crossed_and_exited_liquidity( )
    external
    {
        _create_adjacent_ranges( _START_TICK_UP );

        FeeGrowth memory exited_before  =  _fee_growth( _RIGHT_LOWER, _RIGHT_UPPER );
        FeeGrowth memory final_before   =  _fee_growth( _LEFT_LOWER, _LEFT_UPPER );

        _swap_exact_input({ token_in: _token0(), token_out: _token1(), amount_in: 700 ether });

        FeeGrowth memory exited_after  =  _fee_growth( _RIGHT_LOWER, _RIGHT_UPPER );
        FeeGrowth memory final_after   =  _fee_growth( _LEFT_LOWER, _LEFT_UPPER );

        assertLt( _current_tick(), _LEFT_UPPER, "swap should cross from the right range into the left range." );
        assertGt( exited_after.token0, exited_before.token0, "the crossed-and-exited range should earn token0 fee growth." );
        assertGt( final_after.token0, final_before.token0, "the final active range should earn token0 fee growth." );
    }

    function test_dynamic_fee_compensates_ranges_proportional_to_volume_served( )
    external
    {
        _create_adjacent_ranges( _START_TICK_UP );

        FeeGrowth memory exited_before  =  _fee_growth( _RIGHT_LOWER, _RIGHT_UPPER );
        FeeGrowth memory final_before   =  _fee_growth( _LEFT_LOWER, _LEFT_UPPER );

        _swap_exact_input({ token_in: _token0(), token_out: _token1(), amount_in: 500 ether });

        FeeGrowth memory exited_after  =  _fee_growth( _RIGHT_LOWER, _RIGHT_UPPER );
        FeeGrowth memory final_after   =  _fee_growth( _LEFT_LOWER, _LEFT_UPPER );

        uint256 exited_fee_growth  =  exited_after.token0 - exited_before.token0;
        uint256 final_fee_growth   =  final_after.token0 - final_before.token0;

        assertLt( _current_tick(), _LEFT_UPPER, "swap should cross into the left range." );
        assertGt( exited_fee_growth, 0, "the crossed range should receive token0 fee growth." );
        assertGt( final_fee_growth, 0, "the final range should receive token0 fee growth." );
        assertGt( exited_fee_growth, final_fee_growth, "the range serving more of the path should receive more fee growth per liquidity." );
    }

    function test_dynamic_fee_path_fairness_holds_for_both_swap_directions( )
    external
    {
        _create_adjacent_ranges( _START_TICK_UP );

        FeeGrowth memory right_before_down  =  _fee_growth( _RIGHT_LOWER, _RIGHT_UPPER );
        FeeGrowth memory left_before_down   =  _fee_growth( _LEFT_LOWER, _LEFT_UPPER );

        _swap_exact_input({ token_in: _token0(), token_out: _token1(), amount_in: 700 ether });

        FeeGrowth memory right_after_down  =  _fee_growth( _RIGHT_LOWER, _RIGHT_UPPER );
        FeeGrowth memory left_after_down   =  _fee_growth( _LEFT_LOWER, _LEFT_UPPER );

        assertGt( right_after_down.token0, right_before_down.token0, "token0-to-token1 should pay token0 fees to the exited range." );
        assertGt( left_after_down.token0, left_before_down.token0, "token0-to-token1 should pay token0 fees to the final range." );

        FeeGrowth memory right_before_up  =  _fee_growth( _RIGHT_LOWER, _RIGHT_UPPER );
        FeeGrowth memory left_before_up   =  _fee_growth( _LEFT_LOWER, _LEFT_UPPER );

        _swap_exact_input({ token_in: _token1(), token_out: _token0(), amount_in: 1_000 ether });

        FeeGrowth memory right_after_up  =  _fee_growth( _RIGHT_LOWER, _RIGHT_UPPER );
        FeeGrowth memory left_after_up   =  _fee_growth( _LEFT_LOWER, _LEFT_UPPER );

        assertGt( _current_tick(), _RIGHT_LOWER, "reverse swap should cross back into the right range." );
        assertGt( left_after_up.token1, left_before_up.token1, "token1-to-token0 should pay token1 fees to the exited range." );
        assertGt( right_after_up.token1, right_before_up.token1, "token1-to-token0 should pay token1 fees to the final range." );
    }

    function test_dynamic_fee_path_fairness_contrasts_with_donate_snapshot_behavior( )
    external
    {
        _create_adjacent_ranges( _START_TICK_UP );

        FeeGrowth memory right_before_donate  =  _fee_growth( _RIGHT_LOWER, _RIGHT_UPPER );
        FeeGrowth memory left_before_donate   =  _fee_growth( _LEFT_LOWER, _LEFT_UPPER );

        _donate_router.donate( _pool_key(), 100 ether, 0, "" );

        FeeGrowth memory right_after_donate  =  _fee_growth( _RIGHT_LOWER, _RIGHT_UPPER );
        FeeGrowth memory left_after_donate   =  _fee_growth( _LEFT_LOWER, _LEFT_UPPER );

        assertGt( right_after_donate.token0, right_before_donate.token0, "raw V4 donate should credit the currently active range." );
        assertEq( left_after_donate.token0, left_before_donate.token0, "raw V4 donate should not credit an out-of-range crossed range." );

        _swap_exact_input({ token_in: _token0(), token_out: _token1(), amount_in: 700 ether });

        FeeGrowth memory right_after_swap  =  _fee_growth( _RIGHT_LOWER, _RIGHT_UPPER );
        FeeGrowth memory left_after_swap   =  _fee_growth( _LEFT_LOWER, _LEFT_UPPER );

        assertGt( right_after_swap.token0, right_after_donate.token0, "dynamic swap fee should also credit the initially active range." );
        assertGt( left_after_swap.token0, left_after_donate.token0, "dynamic swap fee should credit the crossed final range unlike donate." );
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _create_adjacent_ranges( int24 start_tick ) internal
    {
        uint160 sqrt_price_x96  =  TickMath.getSqrtPriceAtTick( start_tick );

        _create_position({ tick_lower: _LEFT_LOWER, tick_upper: _LEFT_UPPER, sqrt_price_x96: sqrt_price_x96 });
        _create_position({ tick_lower: _RIGHT_LOWER, tick_upper: _RIGHT_UPPER, sqrt_price_x96: sqrt_price_x96 });
    }

    function _create_position( int24 tick_lower, int24 tick_upper, uint160 sqrt_price_x96 ) internal
    {
        CreatePositionParams memory params  =  CreatePositionParams({
            pool_info: _pool_info(),
            sqrt_price_lower_x96: TickMath.getSqrtPriceAtTick( tick_lower ),
            sqrt_price_upper_x96: TickMath.getSqrtPriceAtTick( tick_upper ),
            liquidity: _RANGE_LIQUIDITY,
            sqrt_price_x96: sqrt_price_x96,
            maximum_deposit_a: TokenAmount({ token: _token0(), amount: 1_000_000 ether }),
            minimum_deposit_a: 0,
            maximum_deposit_b: TokenAmount({ token: _token1(), amount: 1_000_000 ether }),
            minimum_deposit_b: 0
        });

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[0]  =  TokenAmount({ token: _token0(), amount: 1_000_000 ether });
        fundings[1]  =  TokenAmount({ token: _token1(), amount: 1_000_000 ether });

        ( BondStatus status, )  =  _create_and_execute_bond(
            _USER,
            IBondRouteProtected( address(nft) ),
            abi.encodeCall( nft.bonded_create_position, ( params ) ),
            TokenAmount({ token: _token0(), amount: 50_000 ether }),
            fundings
        );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "range creation should execute." );
    }

    function _swap_exact_input( IERC20 token_in, IERC20 token_out, uint256 amount_in ) internal
    {
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_in: token_in,
            input_amount: amount_in,
            token_out: token_out,
            minimum_output_amount: 0,
            pool_info: _pool_info()
        });

        TokenAmount[] memory fundings  =  new TokenAmount[](1);
        fundings[0]  =  TokenAmount({ token: token_in, amount: amount_in });

        ( BondStatus status, )  =  _create_and_execute_bond(
            _USER,
            IBondRouteProtected( address(router) ),
            abi.encodeCall( router.bonded_swap_exact_input, ( params ) ),
            _swap_stake( token_in, amount_in ),
            fundings
        );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "swap bond should execute." );
    }

    function _fee_growth( int24 tick_lower, int24 tick_upper ) internal view returns ( FeeGrowth memory growth )
    {
        ( growth.token0, growth.token1 )  =  poolManager.getFeeGrowthInside( _pool_id(), tick_lower, tick_upper );
    }

    function _current_tick( ) internal view returns ( int24 tick )
    {
        ( , tick, , )  =  poolManager.getSlot0( _pool_id() );
    }

    function _pool_info( ) internal pure returns ( PoolInfo memory )
    {
        return PoolInfo({ base_fee_bps: _BASE_FEE_BPS, rebate_percent: _CAPTURE_PERCENT, tick_spacing: _TICK_SPACING });
    }

    function _pool_id( ) internal view returns ( PoolId )
    {
        return _pool_key().toId( );
    }

    function _pool_key( ) internal view returns ( PoolKey memory )
    {
        return PoolKey({
            currency0: Currency.wrap( address(_token0()) ),
            currency1: Currency.wrap( address(_token1()) ),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: _TICK_SPACING,
            hooks: IHooks(_hook)
        });
    }

    function _token0( ) internal view returns ( IERC20 )
    {
        return address(_token_a) < address(_token_b)  ?  IERC20(address(_token_a))  :  IERC20(address(_token_b));
    }

    function _token1( ) internal view returns ( IERC20 )
    {
        return address(_token_a) < address(_token_b)  ?  IERC20(address(_token_b))  :  IERC20(address(_token_a));
    }

    function _swap_stake( IERC20 token, uint256 amount_in ) internal pure returns ( TokenAmount memory )
    {
        uint256 stake_amount  =  amount_in / 100;
        if(  stake_amount == 0  )  stake_amount  =  1;

        return TokenAmount({ token: token, amount: stake_amount });
    }
}

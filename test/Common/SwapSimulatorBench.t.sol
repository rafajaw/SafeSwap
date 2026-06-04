// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

import { TestERC20 } from "@test/helpers/TestERC20.t.sol";
import { SwapSimulator } from "@SafeSwapCommon/SwapSimulator.sol";

import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";


/// @dev Handles to the `=0.8.26` deployers force-compiled in test/helpers/ForceCompileV4.sol.
interface IPoolManagerDeployer {
    function deploy( address controller ) external returns ( address );
}

interface IV4TestRouterDeployer {
    function deploy_swap_router( address manager ) external returns ( address );
    function deploy_modify_liquidity_router( address manager ) external returns ( address );
}

/// @dev Minimal handle to Uniswap V4's `PoolSwapTest` / `PoolModifyLiquidityTest` (also `=0.8.26`), with `TestSettings`
///      redeclared at the same layout so ABI encoding matches.
interface IPoolSwapTest {
    struct TestSettings { bool takeClaims; bool settleUsingBurn; }
    function swap( PoolKey memory key, IPoolManager.SwapParams memory params, TestSettings memory testSettings, bytes memory hookData ) external payable returns ( BalanceDelta );
}

interface IPoolModifyLiquidityTest {
    function modifyLiquidity( PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, bytes memory hookData ) external payable returns ( BalanceDelta );
}


/**
 * @title SwapSimulatorBenchTest
 * @notice Gas regression bench for `SwapSimulator.simulate` — the read-only path `beforeSwap` runs on every swap to size
 *         the repricing fee. Each case reports the marginal cost of the simulation by comparing two fresh runs on an
 *         identical pool: `{swap}` versus `{simulate; swap}`. Foundry re-runs `setUp` per test, so both pay the same cold
 *         costs and the difference between the two reported totals is purely the simulation. A correctness check pins the
 *         simulated post-swap tick to the realized one across sizes, and a generous ceiling on the standalone simulation
 *         gas trips on gross regressions without being brittle across solc / foundry versions.
 *
 * @dev The earlier `SwapWalkLib` / batched-reader benches are intentionally not ported: that reader approach was dropped
 *      and `SwapSimulator` is the single read path now. Run with `-vv` to see the emitted gas logs.
 */
contract SwapSimulatorBenchTest is Test {

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24  internal constant _STATIC_FEE      =  3000;            // 0.30% LP fee — the simulator is told this fee.
    int24   internal constant _TICK_SPACING    =  10;
    int24   internal constant _TOP_TICK        =  2000;           // 200 initialized boundaries each side of tick 0.
    uint160 internal constant _SQRT_PRICE_1_1  =  79228162514264337593543950336;
    uint256 internal constant _MINT_AMOUNT     =  1e30;
    int128  internal constant _RANGE_LIQUIDITY =  1e21;

    // Exact-input sizes (negative per V4 convention) chosen to cross ~1 / ~19 / ~97 initialized ticks at this liquidity.
    int256 internal constant _SMALL  =  -1e18;
    int256 internal constant _MID    =  -1e19;
    int256 internal constant _LARGE  =  -5e19;

    // Standalone-simulation ceilings held just above observed cost (~28k / ~138k / ~617k for ~1 / ~19 / ~97 tick
    // crossings) so any real regression trips the bench while run-to-run noise does not.
    uint256 internal constant _SIM_GAS_CEILING_SMALL  =  35_000;
    uint256 internal constant _SIM_GAS_CEILING_MID    =  160_000;
    uint256 internal constant _SIM_GAS_CEILING_LARGE  =  700_000;

    IPoolManager internal _manager;
    address      internal _swap_router;
    address      internal _modify_router;
    address      internal _currency0;
    address      internal _currency1;

    function setUp( ) public
    {
        address pool_manager_deployer  =  deployCode( "ForceCompileV4.sol:PoolManagerDeployer" );
        _manager  =  IPoolManager( IPoolManagerDeployer( pool_manager_deployer ).deploy( address(this) ) );

        address router_deployer  =  deployCode( "ForceCompileV4.sol:V4TestRouterDeployer" );
        _swap_router    =  IV4TestRouterDeployer( router_deployer ).deploy_swap_router( address(_manager) );
        _modify_router  =  IV4TestRouterDeployer( router_deployer ).deploy_modify_liquidity_router( address(_manager) );

        TestERC20 token_a  =  new TestERC20( "Token A", "TKNA", 18 );
        TestERC20 token_b  =  new TestERC20( "Token B", "TKNB", 18 );
        ( _currency0, _currency1 )  =  address(token_a) < address(token_b)  ?  ( address(token_a), address(token_b) )  :  ( address(token_b), address(token_a) );

        _approve_and_mint( _currency0 );
        _approve_and_mint( _currency1 );

        _manager.initialize( _key(), _SQRT_PRICE_1_1 );

        // Seed adjacent single-spacing ranges on both sides of tick 0 so a swap crosses an initialized tick per spacing.
        for(  int24 t = -_TOP_TICK  ;  t < _TOP_TICK  ;  t = t + _TICK_SPACING  )
        {
            _seed( t, t + _TICK_SPACING, _RANGE_LIQUIDITY );
        }
    }


    // ━━━━  CORRECTNESS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_bench_simulator_matches_real_swap_across_sizes( )
    external
    {
        int256[3] memory amounts  =  [ _SMALL, _MID, _LARGE ];

        for(  uint256 i = 0  ;  i < amounts.length  ;  i = i + 1  )
        {
            ( , int24 sim_tick_after, , )  =  SwapSimulator.simulate( _manager, _key(), true, amounts[ i ], _STATIC_FEE );

            _swap( true, amounts[ i ] );
            ( , int24 real_tick_after, , )  =  _manager.getSlot0( _key().toId() );

            assertEq( sim_tick_after, real_tick_after, "simulated post-swap tick must equal the realized tick" );

            // Re-initialize the pool state between sizes would require a fresh setUp; instead each size is checked against
            // the pool as moved by the prior swaps, which is still a valid sim-vs-real comparison from that live state.
        }
    }


    // ━━━━  GAS: SWAP ONLY (baseline)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_gas_swap_only_small( ) external  { _swap_only( _SMALL ); }
    function test_gas_swap_only_mid( )   external  { _swap_only( _MID ); }
    function test_gas_swap_only_large( ) external  { _swap_only( _LARGE ); }


    // ━━━━  GAS: SIMULATE THEN SWAP  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_gas_sim_then_swap_small( ) external  { _sim_then_swap( _SMALL, _SIM_GAS_CEILING_SMALL ); }
    function test_gas_sim_then_swap_mid( )   external  { _sim_then_swap( _MID,   _SIM_GAS_CEILING_MID ); }
    function test_gas_sim_then_swap_large( ) external  { _sim_then_swap( _LARGE, _SIM_GAS_CEILING_LARGE ); }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _swap_only( int256 amount ) private
    {
        _warm_shared_state( );

        uint256 g  =  gasleft( );
        _swap( true, amount );
        emit log_named_uint( "SWAP_ONLY_total", g - gasleft( ) );
    }

    function _sim_then_swap( int256 amount, uint256 sim_gas_ceiling ) private
    {
        _warm_shared_state( );

        uint256 g  =  gasleft( );
        SwapSimulator.simulate( _manager, _key(), true, amount, _STATIC_FEE );
        uint256 sim_gas  =  g - gasleft( );

        g  =  gasleft( );
        _swap( true, amount );
        uint256 swap_gas  =  g - gasleft( );

        emit log_named_uint( "sim_gas", sim_gas );
        emit log_named_uint( "swap_gas_after_sim", swap_gas );
        emit log_named_uint( "SIM_THEN_SWAP_total", sim_gas + swap_gas );

        assertGt( sim_gas, 0, "simulation must execute" );
        assertLt( sim_gas, sim_gas_ceiling, "simulation gas regressed past its generous ceiling" );
    }

    function _swap( bool zero_for_one, int256 amount_specified ) private returns ( BalanceDelta )
    {
        IPoolManager.SwapParams memory params  =  IPoolManager.SwapParams({
            zeroForOne: zero_for_one,
            amountSpecified: amount_specified,
            sqrtPriceLimitX96: zero_for_one  ?  TickMath.MIN_SQRT_PRICE + 1  :  TickMath.MAX_SQRT_PRICE - 1
        });

        return IPoolSwapTest( _swap_router ).swap( _key(), params, IPoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "" );
    }

    function _seed( int24 tick_lower, int24 tick_upper, int128 liquidity ) private
    {
        IPoolManager.ModifyLiquidityParams memory params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: tick_lower,
            tickUpper: tick_upper,
            liquidityDelta: int256(liquidity),
            salt: bytes32(0)
        });

        IPoolModifyLiquidityTest( _modify_router ).modifyLiquidity( _key(), params, "" );
    }

    /// @dev Warm shared contract addresses and token balance slots so both measurements share an identical prefix.
    function _warm_shared_state( ) private
    {
        _manager.getSlot0( _key().toId() );
        TestERC20( _currency0 ).balanceOf( _swap_router );
        TestERC20( _currency0 ).balanceOf( address(_manager) );
        TestERC20( _currency1 ).balanceOf( _swap_router );
        TestERC20( _currency1 ).balanceOf( address(_manager) );
    }

    function _approve_and_mint( address token ) private
    {
        TestERC20( token ).mint( address(this), _MINT_AMOUNT );
        TestERC20( token ).approve( _swap_router, type(uint256).max );
        TestERC20( token ).approve( _modify_router, type(uint256).max );
    }

    function _key( ) private view returns ( PoolKey memory )
    {
        return PoolKey({
            currency0: Currency.wrap( _currency0 ),
            currency1: Currency.wrap( _currency1 ),
            fee: _STATIC_FEE,
            tickSpacing: _TICK_SPACING,
            hooks: IHooks( address(0) )
        });
    }
}

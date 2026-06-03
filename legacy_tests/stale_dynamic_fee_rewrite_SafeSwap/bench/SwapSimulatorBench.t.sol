// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import { SwapWalkLib } from "./SwapWalkLib.sol";
import { MockERC20 } from "@test/SafeSwap/TestBase.t.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@UniswapV4Core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@UniswapV4Core/types/BalanceDelta.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";


uint160 constant SQRT_PRICE_1_1  =  79228162514264337593543950336;


// ━━━━  MINIMAL V4 HARNESS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// @dev Adds liquidity / swaps directly against a real PoolManager and exposes the read-only swap simulator for benchmarking.
contract V4Harness is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable pm;

    constructor( IPoolManager _pm ) { pm = _pm; }

    function initialize( PoolKey memory key, uint160 sqrt_price ) external
    {
        pm.initialize( key, sqrt_price );
    }

    function add( PoolKey memory key, int24 tick_lower, int24 tick_upper, int128 liquidity ) external
    {
        pm.unlock( abi.encode( uint8(0), key, tick_lower, tick_upper, liquidity, false, int256(0) ) );
    }

    function swap( PoolKey memory key, bool zero_for_one, int256 amount_specified ) external returns ( int24 tick_after )
    {
        pm.unlock( abi.encode( uint8(1), key, int24(0), int24(0), int128(0), zero_for_one, amount_specified ) );
        ( , tick_after, , )  =  pm.getSlot0( key.toId( ) );
    }

    function simulate( PoolKey memory key, bool zero_for_one, int256 amount_specified, uint24 fee_pips )
    external view returns ( int24 tick_after, uint160 sqrt_price_after, uint256 ticks_crossed )
    {
        return SwapWalkLib.simulate( pm, key, zero_for_one, amount_specified, fee_pips );
    }

    function walk_only( PoolKey memory key, bool zero_for_one, uint256 max_crossings )
    external view returns ( uint256 ticks_crossed )
    {
        return SwapWalkLib.walk_only( pm, key, zero_for_one, max_crossings );
    }

    function unlockCallback( bytes calldata data ) external returns ( bytes memory )
    {
        ( uint8 action, PoolKey memory key, int24 tl, int24 tu, int128 liq, bool zfo, int256 amt )
            =  abi.decode( data, (uint8, PoolKey, int24, int24, int128, bool, int256) );

        if(  action == 0  )
        {
            ( BalanceDelta delta, )  =  pm.modifyLiquidity( key, IPoolManager.ModifyLiquidityParams(tl, tu, liq, bytes32(0)), "" );
            _settle( key, delta );
        }
        else
        {
            uint160 limit  =  zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            BalanceDelta delta  =  pm.swap( key, IPoolManager.SwapParams(zfo, amt, limit), "" );
            _settle( key, delta );
        }

        return "";
    }

    function _settle( PoolKey memory key, BalanceDelta delta ) private
    {
        int128 d0  =  delta.amount0( );
        int128 d1  =  delta.amount1( );

        if(  d0 < 0  )  _pay( key.currency0, uint256(uint128(-d0)) );
        if(  d1 < 0  )  _pay( key.currency1, uint256(uint128(-d1)) );
        if(  d0 > 0  )  pm.take( key.currency0, address(this), uint256(uint128(d0)) );
        if(  d1 > 0  )  pm.take( key.currency1, address(this), uint256(uint128(d1)) );
    }

    function _pay( Currency currency, uint256 amount ) private
    {
        pm.sync( currency );
        MockERC20(Currency.unwrap(currency)).transfer( address(pm), amount );
        pm.settle( );
    }
}


// ━━━━  BENCHMARK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
// Methodology: the marginal cost of adding the simulation must be compared on the SAME pool, in SEPARATE transactions
// (foundry re-runs setUp per test, giving identical fresh state). Each test runs an identical prefix (`_warm_shared_state`)
// and then either {swap} or {sim; swap}. The swap is the first — and only — operation that touches the PoolManager's
// global swap/settlement machinery in both cases, so all shared cold costs cancel; the difference between the two
// reported totals is purely the simulation. (Comparing two different pools in ONE tx is NOT valid: whichever swap runs
// first pays shared cold costs the second gets warm for free, which biases the baseline.)

contract SwapSimulatorBench is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public pm;
    V4Harness public harness;
    MockERC20 public token0;
    MockERC20 public token1;

    PoolKey public pool;

    int24 constant TICK_SPACING  =  10;
    uint24 constant BASE_FEE     =  3000;
    int24 constant TOP_TICK      =  2000;        // 200 initialized boundaries above tick 0.
    uint128 constant RANGE_LIQUIDITY  =  1e21;

    int256 constant SMALL  =  -1e18;
    int256 constant MID    =  -1e19;
    int256 constant LARGE  =  -5e19;

    function setUp( ) public
    {
        address deployer  =  vm.deployCode( "ForceCompileV4.sol:PoolManagerDeployer" );
        ( , bytes memory ret )  =  deployer.call( abi.encodeWithSignature( "deploy(address)", address(0) ) );
        pm  =  IPoolManager(abi.decode( ret, (address) ));

        harness  =  new V4Harness( pm );

        token0  =  new MockERC20( "T0", "T0", 18 );
        token1  =  new MockERC20( "T1", "T1", 18 );
        if(  address(token0) > address(token1)  )  ( token0, token1 )  =  ( token1, token0 );

        token0.mint( address(harness), 1e30 );
        token1.mint( address(harness), 1e30 );

        pool  =  PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: BASE_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        harness.initialize( pool, SQRT_PRICE_1_1 );
        for(  int24 t = 0  ;  t < TOP_TICK  ;  t = t + TICK_SPACING  )
        {
            harness.add( pool, t, t + TICK_SPACING, int128(RANGE_LIQUIDITY) );
        }
    }

    // ━━━━  CORRECTNESS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_simulator_matches_real_swap( ) external
    {
        int256[3] memory amounts  =  [ SMALL, MID, LARGE ];

        for(  uint i = 0  ;  i < amounts.length  ;  i = i + 1  )
        {
            ( int24 sim_tick, , uint256 crossed )  =  harness.simulate( pool, false, amounts[ i ], BASE_FEE );
            int24 real_tick  =  harness.swap( pool, false, amounts[ i ] );

            assertEq( sim_tick, real_tick, "simulated tick must equal real post-swap tick" );
            emit log_named_int( "tick_after", real_tick );
            emit log_named_uint( "ticks_crossed", crossed );
        }
    }

    // ━━━━  GAS: SWAP ALONE (baseline)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_gas_swap_only_small( ) external  { _swap_only( SMALL ); }
    function test_gas_swap_only_mid( ) external     { _swap_only( MID ); }
    function test_gas_swap_only_large( ) external   { _swap_only( LARGE ); }

    // ━━━━  GAS: SIMULATE THEN SWAP  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_gas_sim_then_swap_small( ) external  { _sim_then_swap( SMALL ); }
    function test_gas_sim_then_swap_mid( ) external     { _sim_then_swap( MID ); }
    function test_gas_sim_then_swap_large( ) external   { _sim_then_swap( LARGE ); }

    // ━━━━  GAS: WALK (reads only, no AMM math) THEN SWAP  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_gas_walk_then_swap_small( ) external  { _walk_then_swap( SMALL, 1 ); }
    function test_gas_walk_then_swap_mid( ) external     { _walk_then_swap( MID, 19 ); }
    function test_gas_walk_then_swap_large( ) external   { _walk_then_swap( LARGE, 97 ); }

    function _walk_then_swap( int256 amount, uint256 crossings ) private
    {
        _warm_shared_state( );

        uint256 g  =  gasleft( );
        uint256 walked  =  harness.walk_only( pool, false, crossings );
        uint256 walk_gas  =  g - gasleft( );

        g  =  gasleft( );
        harness.swap( pool, false, amount );
        uint256 swap_gas  =  g - gasleft( );

        emit log_named_uint( "walked", walked );
        emit log_named_uint( "WALK_THEN_SWAP_total", walk_gas + swap_gas );
    }

    function _swap_only( int256 amount ) private
    {
        _warm_shared_state( );

        uint256 g  =  gasleft( );
        harness.swap( pool, false, amount );
        emit log_named_uint( "SWAP_ONLY_total", g - gasleft( ) );
    }

    function _sim_then_swap( int256 amount ) private
    {
        _warm_shared_state( );

        uint256 g  =  gasleft( );
        ( , , uint256 crossed )  =  harness.simulate( pool, false, amount, BASE_FEE );
        uint256 sim_gas  =  g - gasleft( );

        g  =  gasleft( );
        harness.swap( pool, false, amount );
        uint256 swap_gas  =  g - gasleft( );

        emit log_named_uint( "ticks_crossed", crossed );
        emit log_named_uint( "sim_gas", sim_gas );
        emit log_named_uint( "swap_gas_after_sim", swap_gas );
        emit log_named_uint( "SIM_THEN_SWAP_total", sim_gas + swap_gas );
    }

    /// @dev Warm shared contract addresses and token balance slots so both measurements share an identical prefix.
    function _warm_shared_state( ) private
    {
        pm.getSlot0( pool.toId( ) );
        token0.balanceOf( address(harness) );
        token0.balanceOf( address(pm) );
        token1.balanceOf( address(harness) );
        token1.balanceOf( address(pm) );
        harness.pm( );
    }
}

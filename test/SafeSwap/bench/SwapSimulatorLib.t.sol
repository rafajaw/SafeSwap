// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import { SwapSimulator } from "@SafeSwapRouter/libraries/SwapSimulator.sol";
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


contract SimHarness is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable pm;

    constructor( IPoolManager _pm ) { pm = _pm; }

    function initialize( PoolKey memory key, uint160 sqrt_price ) external { pm.initialize( key, sqrt_price ); }

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
    external view returns ( int24 tick_before, int24 tick_after, uint160 sqrt_price_after )
    {
        return SwapSimulator.simulate( pm, key, zero_for_one, amount_specified, fee_pips );
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


contract SwapSimulatorLibTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public pm;
    SimHarness public harness;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey public pool;

    int24 constant TICK_SPACING  =  10;
    uint24 constant BASE_FEE     =  3000;
    int24 constant TOP_TICK      =  2000;
    uint128 constant RANGE_LIQUIDITY  =  1e21;

    function setUp( ) public
    {
        address deployer  =  vm.deployCode( "ForceCompileV4.sol:PoolManagerDeployer" );
        ( , bytes memory ret )  =  deployer.call( abi.encodeWithSignature( "deploy(address)", address(0) ) );
        pm  =  IPoolManager(abi.decode( ret, (address) ));

        harness  =  new SimHarness( pm );

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

        // Seed adjacent ranges on BOTH sides of tick 0 so swaps can move up or down across initialized ticks.
        for(  int24 t = -TOP_TICK  ;  t < TOP_TICK  ;  t = t + TICK_SPACING  )
        {
            harness.add( pool, t, t + TICK_SPACING, int128(RANGE_LIQUIDITY) );
        }
    }

    // ━━━━  CORRECTNESS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_matches_real_swap_up_exact_input( ) external      { _assert_matches( false, -1e19 ); }
    function test_matches_real_swap_down_exact_input( ) external    { _assert_matches( true, -1e19 ); }
    function test_matches_real_swap_up_exact_output( ) external     { _assert_matches( false, 1e18 ); }
    function test_matches_real_swap_down_exact_output( ) external   { _assert_matches( true, 1e18 ); }
    function test_matches_real_swap_tiny( ) external                { _assert_matches( false, -1e17 ); }
    function test_matches_real_swap_large( ) external               { _assert_matches( false, -5e19 ); }

    function _assert_matches( bool zero_for_one, int256 amount ) private
    {
        ( int24 tick_before, int24 sim_tick, )  =  harness.simulate( pool, zero_for_one, amount, BASE_FEE );
        int24 real_tick  =  harness.swap( pool, zero_for_one, amount );

        assertEq( sim_tick, real_tick, "simulated tick must equal the real post-swap tick" );
        emit log_named_int( "tick_before", tick_before );
        emit log_named_int( "tick_after", real_tick );
    }

    // ━━━━  GAS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // Marginal = (sim+swap) − (swap) for each amount, measured on the same pool in separate transactions (fresh setUp
    // each), so the swap pays identical shared cold costs in both and the difference is purely the simulation.

    function test_gas_swap_only_0cross( ) external      { _swap_only( -1e15 ); }   // tiny move, ~0 initialized ticks.
    function test_gas_sim_then_swap_0cross( ) external  { _sim_then_swap( -1e15 ); }

    function test_gas_swap_only_1cross( ) external      { _swap_only( -1e17 ); }   // ~1 initialized tick.
    function test_gas_sim_then_swap_1cross( ) external  { _sim_then_swap( -1e17 ); }

    function test_gas_swap_only_3cross( ) external      { _swap_only( -3e17 ); }   // a few initialized ticks.
    function test_gas_sim_then_swap_3cross( ) external  { _sim_then_swap( -3e17 ); }

    function test_gas_swap_only_large( ) external       { _swap_only( -5e19 ); }   // ~97 ticks (worst case).
    function test_gas_sim_then_swap_large( ) external   { _sim_then_swap( -5e19 ); }

    function _swap_only( int256 amount ) private
    {
        _warm( );
        uint256 g  =  gasleft( );
        int24 tick_after  =  harness.swap( pool, false, amount );
        emit log_named_int( "tick_after", tick_after );
        emit log_named_uint( "SWAP_ONLY_total", g - gasleft( ) );
    }

    function _sim_then_swap( int256 amount ) private
    {
        _warm( );
        uint256 g  =  gasleft( );
        harness.simulate( pool, false, amount, BASE_FEE );
        uint256 sim_gas  =  g - gasleft( );
        g  =  gasleft( );
        harness.swap( pool, false, amount );
        emit log_named_uint( "sim_gas_standalone", sim_gas );
        emit log_named_uint( "SIM_THEN_SWAP_total", sim_gas + ( g - gasleft( ) ) );
    }

    function _warm( ) private
    {
        pm.getSlot0( pool.toId( ) );
        token0.balanceOf( address(harness) );
        token0.balanceOf( address(pm) );
        token1.balanceOf( address(harness) );
        token1.balanceOf( address(pm) );
        harness.pm( );
    }
}

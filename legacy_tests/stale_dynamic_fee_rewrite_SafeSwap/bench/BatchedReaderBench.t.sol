// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import { SwapWalkLib } from "./SwapWalkLib.sol";
import { BatchedSwapWalkLib } from "./BatchedSwapWalkLib.sol";
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


// ━━━━  HARNESS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract BatchHarness is IUnlockCallback {
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

    function swap( PoolKey memory key, bool zero_for_one, int256 amount_specified ) external
    {
        pm.unlock( abi.encode( uint8(1), key, int24(0), int24(0), int128(0), zero_for_one, amount_specified ) );
    }

    function walk_unbatched( PoolKey memory key, uint256 max_crossings ) external view returns ( uint256 )
    {
        return SwapWalkLib.walk_only( pm, key, false, max_crossings );
    }

    function walk_batched( PoolKey memory key, uint256 max_crossings ) external view returns ( uint256 )
    {
        return BatchedSwapWalkLib.walk_only_batched( pm, key, max_crossings );
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

contract BatchedReaderBench is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public pm;
    BatchHarness public harness;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey public pool;

    int24 constant TICK_SPACING  =  10;
    uint24 constant BASE_FEE     =  3000;
    int24 constant TOP_TICK      =  2000;
    uint128 constant RANGE_LIQUIDITY  =  1e21;

    int256 constant LARGE  =  -5e19;   // crosses ~97 initialized ticks (single bitmap word).

    function setUp( ) public
    {
        address deployer  =  vm.deployCode( "ForceCompileV4.sol:PoolManagerDeployer" );
        ( , bytes memory ret )  =  deployer.call( abi.encodeWithSignature( "deploy(address)", address(0) ) );
        pm  =  IPoolManager(abi.decode( ret, (address) ));

        harness  =  new BatchHarness( pm );

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

    function test_batched_reader_crosses_expected_ticks( ) external view
    {
        assertEq( harness.walk_batched( pool, 97 ), 97, "batched walk should cross the requested initialized ticks" );
        assertEq( harness.walk_unbatched( pool, 97 ), 97, "unbatched walk should cross the same count" );
    }

    function test_gas_swap_only( ) external
    {
        _warm( );
        uint256 g  =  gasleft( );
        harness.swap( pool, false, LARGE );
        emit log_named_uint( "SWAP_ONLY_total", g - gasleft( ) );
    }

    function test_gas_walk_unbatched_then_swap( ) external
    {
        _warm( );
        uint256 g  =  gasleft( );
        harness.walk_unbatched( pool, 97 );
        uint256 walk_gas  =  g - gasleft( );
        g  =  gasleft( );
        harness.swap( pool, false, LARGE );
        emit log_named_uint( "walk_unbatched_gas", walk_gas );
        emit log_named_uint( "WALK_UNBATCHED_THEN_SWAP_total", walk_gas + ( g - gasleft( ) ) );
    }

    function test_gas_walk_batched_then_swap( ) external
    {
        _warm( );
        uint256 g  =  gasleft( );
        harness.walk_batched( pool, 97 );
        uint256 walk_gas  =  g - gasleft( );
        g  =  gasleft( );
        harness.swap( pool, false, LARGE );
        emit log_named_uint( "walk_batched_gas", walk_gas );
        emit log_named_uint( "WALK_BATCHED_THEN_SWAP_total", walk_gas + ( g - gasleft( ) ) );
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

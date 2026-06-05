// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

import { ISwapSimulatorTests } from "@test/Common/TestManifest.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";
import { SwapSimulator } from "@SafeSwapCommon/SwapSimulator.sol";

import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@UniswapV4Core/types/BalanceDelta.sol";


/// @dev Handles to the `=0.8.26` deployers force-compiled in test/helpers/ForceCompileV4.sol.
interface IPoolManagerDeployer {
    function deploy( address controller ) external returns ( address );
}

interface IV4TestRouterDeployer {
    function deploy_swap_router( address manager ) external returns ( address );
    function deploy_modify_liquidity_router( address manager ) external returns ( address );
}

/// @dev Minimal handle to Uniswap V4's `PoolSwapTest` / `PoolModifyLiquidityTest` (also `=0.8.26`). The `TestSettings`
///      struct is redeclared with the same layout so ABI encoding matches.
interface IPoolSwapTest {
    struct TestSettings { bool takeClaims; bool settleUsingBurn; }
    function swap( PoolKey memory key, IPoolManager.SwapParams memory params, TestSettings memory testSettings, bytes memory hookData ) external payable returns ( BalanceDelta );
}

interface IPoolModifyLiquidityTest {
    function modifyLiquidity( PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, bytes memory hookData ) external payable returns ( BalanceDelta );
}

/// @dev A PoolManager stand-in whose every `extsload` reverts, to prove the simulator bubbles read failures rather than
///      treating them as zeroed slots.
contract RevertingExtsloadManager {
    function extsload( bytes32 ) external pure returns ( bytes32 )
    {
        revert( "extsload disabled" );
    }
}


/**
 * @title SwapSimulatorTest
 * @notice Validates `SwapSimulator` against real Uniswap V4 swaps: for the same pre-swap state it must predict the exact
 *         post-swap tick, post-swap sqrt price, and counterpart amount the real swap realizes — across exact-input and
 *         exact-output, both directions, and single / multi tick crossings. Uses real V4 (PoolManager + test routers)
 *         deployed from their own `=0.8.26` unit (see ForceCompileV4.sol).
 */
contract SwapSimulatorTest is ISwapSimulatorTests, Test {

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    uint24  internal constant _STATIC_FEE      =  3000;            // 0.3% static LP fee — the simulator is told this fee.
    int24   internal constant _TICK_SPACING    =  60;
    uint160 internal constant _SQRT_PRICE_1_1  =  79228162514264337593543950336;
    uint256 internal constant _MINT_AMOUNT     =  1_000_000_000 ether;

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
    }


    // ━━━━  EXACT INPUT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_simulate_exact_input_matches_real_swap_inside_one_range( )
    external
    {
        _seed({ tick_lower: -6000, tick_upper: 6000, liquidity: 1_000 ether });

        // Small swap: the price stays between the only initialized ticks (±6000), so none is crossed.
        _assert_simulation_matches_real_swap({ zero_for_one: true, amount_specified: -5 ether });
    }

    function test_simulate_exact_input_matches_real_swap_when_crossing_one_initialized_tick( )
    external
    {
        _seed({ tick_lower: -6000, tick_upper: 6000, liquidity: 1_000 ether });
        _seed({ tick_lower: -60,   tick_upper: 6000, liquidity: 1_000 ether });        // adds an initialized tick at -60.

        // Pushes the price below tick -60 (crossing it once) but well short of -6000.
        _assert_simulation_matches_real_swap({ zero_for_one: true, amount_specified: -20 ether });
    }

    function test_simulate_exact_input_matches_real_swap_when_crossing_multiple_initialized_ticks( )
    external
    {
        _seed({ tick_lower: -6000, tick_upper: 6000, liquidity: 1_000 ether });
        _seed({ tick_lower: -60,   tick_upper: 6000, liquidity: 1_000 ether });        // initialized tick at -60.
        _seed({ tick_lower: -120,  tick_upper: 6000, liquidity: 1_000 ether });        // initialized tick at -120.

        // Pushes the price below tick -120, crossing both -60 and -120.
        _assert_simulation_matches_real_swap({ zero_for_one: true, amount_specified: -50 ether });
    }


    // ━━━━  EXACT OUTPUT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_simulate_exact_output_matches_real_swap_inside_one_range( )
    external
    {
        _seed({ tick_lower: -6000, tick_upper: 6000, liquidity: 1_000 ether });

        _assert_simulation_matches_real_swap({ zero_for_one: true, amount_specified: int256(3 ether) });
    }

    function test_simulate_exact_output_matches_real_swap_when_crossing_one_initialized_tick( )
    external
    {
        _seed({ tick_lower: -6000, tick_upper: 6000, liquidity: 1_000 ether });
        _seed({ tick_lower: -60,   tick_upper: 6000, liquidity: 1_000 ether });

        _assert_simulation_matches_real_swap({ zero_for_one: true, amount_specified: int256(20 ether) });
    }

    function test_simulate_exact_output_matches_real_swap_when_crossing_multiple_initialized_ticks( )
    external
    {
        _seed({ tick_lower: -6000, tick_upper: 6000, liquidity: 1_000 ether });
        _seed({ tick_lower: -60,   tick_upper: 6000, liquidity: 1_000 ether });
        _seed({ tick_lower: -120,  tick_upper: 6000, liquidity: 1_000 ether });

        _assert_simulation_matches_real_swap({ zero_for_one: true, amount_specified: int256(50 ether) });
    }


    // ━━━━  EDGE CASES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_simulate_handles_zero_liquidity_without_corrupting_fee_quote( )
    external
    {
        // No liquidity seeded: a swap walks to the price limit producing zero amounts. The simulator must agree, not revert.
        _assert_simulation_matches_real_swap({ zero_for_one: true, amount_specified: -1 ether });
    }

    function test_simulate_bubbles_pool_manager_extsload_failures( )
    external
    {
        RevertingExtsloadManager reverting_manager  =  new RevertingExtsloadManager();

        vm.expectRevert( bytes("extsload disabled") );
        this.simulate_external({ manager: IPoolManager( address(reverting_manager) ), key: _key(), zero_for_one: true, amount_specified: -1 ether, fee_pips: _STATIC_FEE });
    }

    function test_simulate_matches_real_swap_in_both_directions( )
    external
    {
        _seed({ tick_lower: -6000, tick_upper: 6000, liquidity: 1_000 ether });

        // oneForZero (price up) must be simulated as faithfully as zeroForOne (price down).
        _assert_simulation_matches_real_swap({ zero_for_one: false, amount_specified: -5 ether });
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// @dev External wrapper so `vm.expectRevert` can observe a revert raised inside the (internal) library call.
    function simulate_external( IPoolManager manager, PoolKey memory key, bool zero_for_one, int256 amount_specified, uint24 fee_pips )
    external  view returns ( int24, int24, uint160, uint256 )
    {
        return SwapSimulator.simulate( manager, key, zero_for_one, amount_specified, fee_pips );
    }

    function _assert_simulation_matches_real_swap( bool zero_for_one, int256 amount_specified ) internal
    {
        ( , int24 tick_before_state, , )  =  _manager.getSlot0( _key().toId() );

        ( int24 sim_tick_before, int24 sim_tick_after, uint160 sim_sqrt_after, uint256 sim_amount )  =
            SwapSimulator.simulate( _manager, _key(), zero_for_one, amount_specified, _STATIC_FEE );

        assertEq( sim_tick_before, tick_before_state, "Simulated tick_before should equal the live pool tick." );

        BalanceDelta delta  =  _execute_real_swap( zero_for_one, amount_specified );
        ( uint160 real_sqrt_after, int24 real_tick_after, , )  =  _manager.getSlot0( _key().toId() );

        assertEq( sim_tick_after, real_tick_after, "Simulated tick_after should equal the realized tick." );
        assertEq( sim_sqrt_after, real_sqrt_after, "Simulated sqrt price should equal the realized sqrt price." );
        assertEq( sim_amount, _realized_counterpart( zero_for_one, amount_specified, delta ), "Simulated counterpart amount should equal the realized amount." );
    }

    function _execute_real_swap( bool zero_for_one, int256 amount_specified ) internal returns ( BalanceDelta )
    {
        IPoolManager.SwapParams memory params  =  IPoolManager.SwapParams({
            zeroForOne: zero_for_one,
            amountSpecified: amount_specified,
            sqrtPriceLimitX96: zero_for_one  ?  TickMath.MIN_SQRT_PRICE + 1  :  TickMath.MAX_SQRT_PRICE - 1
        });

        return IPoolSwapTest( _swap_router ).swap( _key(), params, IPoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "" );
    }

    /// @dev The counterpart amount the simulator accumulates: total output for exact-input, total required input for exact-output.
    function _realized_counterpart( bool zero_for_one, int256 amount_specified, BalanceDelta delta ) internal pure returns ( uint256 )
    {
        if(  amount_specified < 0  )
        {
            // Exact-input: the output is the positive delta of the output token.
            return zero_for_one  ?  uint256(uint128(delta.amount1()))  :  uint256(uint128(delta.amount0()));
        }

        // Exact-output: the required input is the negative delta of the input token.
        return zero_for_one  ?  uint256(uint128(-delta.amount0()))  :  uint256(uint128(-delta.amount1()));
    }

    function _seed( int24 tick_lower, int24 tick_upper, uint256 liquidity ) internal
    {
        IPoolManager.ModifyLiquidityParams memory params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: tick_lower,
            tickUpper: tick_upper,
            liquidityDelta: int256(liquidity),
            salt: bytes32(0)
        });

        IPoolModifyLiquidityTest( _modify_router ).modifyLiquidity( _key(), params, "" );
    }

    function _approve_and_mint( address token ) internal
    {
        TestERC20( token ).mint( address(this), _MINT_AMOUNT );
        TestERC20( token ).approve( _swap_router, type(uint256).max );
        TestERC20( token ).approve( _modify_router, type(uint256).max );
    }

    function _key( ) internal view returns ( PoolKey memory )
    {
        return PoolKey({
            currency0: Currency.wrap( _currency0 ),
            currency1: Currency.wrap( _currency1 ),
            fee: _STATIC_FEE,
            tickSpacing: _TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }
}

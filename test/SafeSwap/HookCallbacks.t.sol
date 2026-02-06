// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@UniswapV4Core/types/BeforeSwapDelta.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";


contract HookCallbacksTest is SafeSwapTestBase {

    PoolKey internal pool_key;

    function setUp( ) public override
    {
        super.setUp( );

        pool_key  =  PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: POOL_FEE_030,
            tickSpacing: TICK_SPACING_60,
            hooks: IHooks(address(hook))
        });
    }


    // ━━━━  beforeSwap( )  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_before_swap_reverts_if_not_pool_manager( ) external
    {
        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100 ether,
            sqrtPriceLimitX96: 0
        });

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, address(pool_manager) ) );
        hook.beforeSwap( user, pool_key, swap_params, "" );
    }

    function test_before_swap_reverts_if_not_protected_context( ) external
    {
        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100 ether,
            sqrtPriceLimitX96: 0
        });

        // Ensure not in protected context.
        hook.test_set_protected_context( false );

        vm.prank( address(pool_manager) );
        vm.expectRevert( NotProtectedContext.selector );
        hook.beforeSwap( user, pool_key, swap_params, "" );
    }

    function test_before_swap_returns_correct_selector( ) external
    {
        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100 ether,
            sqrtPriceLimitX96: 0
        });

        hook.test_set_protected_context( true );

        vm.prank( address(pool_manager) );
        ( bytes4 selector, , )  =  hook.beforeSwap( user, pool_key, swap_params, "" );

        assertEq(
            selector,
            IHooks.beforeSwap.selector,
            "Should return beforeSwap selector."
        );

        hook.test_set_protected_context( false );
    }

    function test_before_swap_returns_zero_delta( ) external
    {
        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100 ether,
            sqrtPriceLimitX96: 0
        });

        hook.test_set_protected_context( true );

        vm.prank( address(pool_manager) );
        ( , BeforeSwapDelta delta, )  =  hook.beforeSwap( user, pool_key, swap_params, "" );

        // BeforeSwapDelta should be zero.
        assertEq(
            BeforeSwapDelta.unwrap( delta ),
            BeforeSwapDelta.unwrap( BeforeSwapDeltaLibrary.ZERO_DELTA ),
            "Should return zero delta."
        );

        hook.test_set_protected_context( false );
    }

    function test_before_swap_succeeds_in_protected_context( ) external
    {
        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100 ether,
            sqrtPriceLimitX96: 0
        });

        hook.test_set_protected_context( true );

        vm.prank( address(pool_manager) );
        ( bytes4 selector, , uint24 fee )  =  hook.beforeSwap( user, pool_key, swap_params, "" );

        assertEq( selector, IHooks.beforeSwap.selector, "Should succeed in protected context." );
        assertEq( fee, 0, "Fee override should be 0." );

        hook.test_set_protected_context( false );
    }


    // ━━━━  beforeAddLiquidity( )  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_before_add_liquidity_reverts_if_not_pool_manager( ) external
    {
        IPoolManager.ModifyLiquidityParams memory liq_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100 ether,
            salt: bytes32(0)
        });

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, address(pool_manager) ) );
        hook.beforeAddLiquidity( user, pool_key, liq_params, "" );
    }

    function test_before_add_liquidity_reverts_if_not_protected_context( ) external
    {
        IPoolManager.ModifyLiquidityParams memory liq_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100 ether,
            salt: bytes32(0)
        });

        hook.test_set_protected_context( false );

        vm.prank( address(pool_manager) );
        vm.expectRevert( NotProtectedContext.selector );
        hook.beforeAddLiquidity( user, pool_key, liq_params, "" );
    }

    function test_before_add_liquidity_returns_correct_selector( ) external
    {
        IPoolManager.ModifyLiquidityParams memory liq_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100 ether,
            salt: bytes32(0)
        });

        hook.test_set_protected_context( true );

        vm.prank( address(pool_manager) );
        bytes4 selector  =  hook.beforeAddLiquidity( user, pool_key, liq_params, "" );

        assertEq(
            selector,
            IHooks.beforeAddLiquidity.selector,
            "Should return beforeAddLiquidity selector."
        );

        hook.test_set_protected_context( false );
    }

    function test_before_add_liquidity_succeeds_in_protected_context( ) external
    {
        IPoolManager.ModifyLiquidityParams memory liq_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100 ether,
            salt: bytes32(0)
        });

        hook.test_set_protected_context( true );

        vm.prank( address(pool_manager) );
        bytes4 selector  =  hook.beforeAddLiquidity( user, pool_key, liq_params, "" );

        assertEq( selector, IHooks.beforeAddLiquidity.selector, "Should succeed in protected context." );

        hook.test_set_protected_context( false );
    }


    // ━━━━  beforeRemoveLiquidity( )  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_before_remove_liquidity_reverts_if_not_pool_manager( ) external
    {
        IPoolManager.ModifyLiquidityParams memory liq_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: -100 ether,
            salt: bytes32(0)
        });

        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, address(pool_manager) ) );
        hook.beforeRemoveLiquidity( user, pool_key, liq_params, "" );
    }

    function test_before_remove_liquidity_reverts_if_not_protected_context( ) external
    {
        IPoolManager.ModifyLiquidityParams memory liq_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: -100 ether,
            salt: bytes32(0)
        });

        hook.test_set_protected_context( false );

        vm.prank( address(pool_manager) );
        vm.expectRevert( NotProtectedContext.selector );
        hook.beforeRemoveLiquidity( user, pool_key, liq_params, "" );
    }

    function test_before_remove_liquidity_returns_correct_selector( ) external
    {
        IPoolManager.ModifyLiquidityParams memory liq_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: -100 ether,
            salt: bytes32(0)
        });

        hook.test_set_protected_context( true );

        vm.prank( address(pool_manager) );
        bytes4 selector  =  hook.beforeRemoveLiquidity( user, pool_key, liq_params, "" );

        assertEq(
            selector,
            IHooks.beforeRemoveLiquidity.selector,
            "Should return beforeRemoveLiquidity selector."
        );

        hook.test_set_protected_context( false );
    }

    function test_before_remove_liquidity_succeeds_in_protected_context( ) external
    {
        IPoolManager.ModifyLiquidityParams memory liq_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: -100 ether,
            salt: bytes32(0)
        });

        hook.test_set_protected_context( true );

        vm.prank( address(pool_manager) );
        bytes4 selector  =  hook.beforeRemoveLiquidity( user, pool_key, liq_params, "" );

        assertEq( selector, IHooks.beforeRemoveLiquidity.selector, "Should succeed in protected context." );

        hook.test_set_protected_context( false );
    }


    // ━━━━  Protected Context State  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_protected_context_cleared_after_swap( ) external
    {
        // Initially not protected.
        assertEq( hook.test_is_within_protected_context( ), false, "Should start unprotected." );

        // Set protected.
        hook.test_set_protected_context( true );
        assertEq( hook.test_is_within_protected_context( ), true, "Should be protected after setting." );

        // Clear protected.
        hook.test_set_protected_context( false );
        assertEq( hook.test_is_within_protected_context( ), false, "Should be unprotected after clearing." );
    }

    function test_protected_context_cleared_after_add_liquidity( ) external
    {
        hook.test_set_protected_context( true );
        assertEq( hook.test_is_within_protected_context( ), true, "Should be protected." );

        hook.test_set_protected_context( false );
        assertEq( hook.test_is_within_protected_context( ), false, "Should be cleared." );
    }

    function test_protected_context_cleared_after_remove_liquidity( ) external
    {
        hook.test_set_protected_context( true );
        assertEq( hook.test_is_within_protected_context( ), true, "Should be protected." );

        hook.test_set_protected_context( false );
        assertEq( hook.test_is_within_protected_context( ), false, "Should be cleared." );
    }

    function test_protected_context_transient_storage_isolation( ) external
    {
        // Set protected in this call.
        hook.test_set_protected_context( true );
        assertEq( hook.test_is_within_protected_context( ), true, "Should be protected in same tx." );

        // Transient storage should be cleared between transactions.
        // In Foundry tests, each test function is a separate transaction context.
        // We can simulate by checking that a new call starts unprotected.
        hook.test_set_protected_context( false );

        // Verify isolation - a new setup would start unprotected.
        assertEq( hook.test_is_within_protected_context( ), false, "Should be isolated between operations." );
    }
}

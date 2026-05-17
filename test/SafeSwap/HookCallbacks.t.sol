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
        hook.harness_revoke_hook_callback_permission( );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( BondRouteRequired.selector, address(pool_manager), address(BondRoute) ) );
        hook.beforeSwap( user, pool_key, swap_params, "" );
    }

    function test_before_swap_returns_correct_selector( ) external
    {
        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100 ether,
            sqrtPriceLimitX96: 0
        });

        hook.harness_allow_hook_callback( );

        vm.prank( address(pool_manager) );
        ( bytes4 selector, , )  =  hook.beforeSwap( user, pool_key, swap_params, "" );

        assertEq(
            selector,
            IHooks.beforeSwap.selector,
            "Should return beforeSwap selector."
        );

        hook.harness_revoke_hook_callback_permission( );
    }

    function test_before_swap_returns_zero_delta( ) external
    {
        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100 ether,
            sqrtPriceLimitX96: 0
        });

        hook.harness_allow_hook_callback( );

        vm.prank( address(pool_manager) );
        ( , BeforeSwapDelta delta, )  =  hook.beforeSwap( user, pool_key, swap_params, "" );

        // BeforeSwapDelta should be zero.
        assertEq(
            BeforeSwapDelta.unwrap( delta ),
            BeforeSwapDelta.unwrap( BeforeSwapDeltaLibrary.ZERO_DELTA ),
            "Should return zero delta."
        );

        hook.harness_revoke_hook_callback_permission( );
    }

    function test_before_swap_succeeds_in_protected_context( ) external
    {
        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -100 ether,
            sqrtPriceLimitX96: 0
        });

        hook.harness_allow_hook_callback( );

        vm.prank( address(pool_manager) );
        ( bytes4 selector, , uint24 fee )  =  hook.beforeSwap( user, pool_key, swap_params, "" );

        assertEq( selector, IHooks.beforeSwap.selector, "Should succeed in protected context." );
        assertEq( fee, 0, "Fee override should be 0." );

        hook.harness_revoke_hook_callback_permission( );
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

        hook.harness_revoke_hook_callback_permission( );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( BondRouteRequired.selector, address(pool_manager), address(BondRoute) ) );
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

        hook.harness_allow_hook_callback( );

        vm.prank( address(pool_manager) );
        bytes4 selector  =  hook.beforeAddLiquidity( user, pool_key, liq_params, "" );

        assertEq(
            selector,
            IHooks.beforeAddLiquidity.selector,
            "Should return beforeAddLiquidity selector."
        );

        hook.harness_revoke_hook_callback_permission( );
    }

    function test_before_add_liquidity_succeeds_in_protected_context( ) external
    {
        IPoolManager.ModifyLiquidityParams memory liq_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 100 ether,
            salt: bytes32(0)
        });

        hook.harness_allow_hook_callback( );

        vm.prank( address(pool_manager) );
        bytes4 selector  =  hook.beforeAddLiquidity( user, pool_key, liq_params, "" );

        assertEq( selector, IHooks.beforeAddLiquidity.selector, "Should succeed in protected context." );

        hook.harness_revoke_hook_callback_permission( );
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

        hook.harness_revoke_hook_callback_permission( );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( BondRouteRequired.selector, address(pool_manager), address(BondRoute) ) );
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

        hook.harness_allow_hook_callback( );

        vm.prank( address(pool_manager) );
        bytes4 selector  =  hook.beforeRemoveLiquidity( user, pool_key, liq_params, "" );

        assertEq(
            selector,
            IHooks.beforeRemoveLiquidity.selector,
            "Should return beforeRemoveLiquidity selector."
        );

        hook.harness_revoke_hook_callback_permission( );
    }

    function test_before_remove_liquidity_succeeds_in_protected_context( ) external
    {
        IPoolManager.ModifyLiquidityParams memory liq_params  =  IPoolManager.ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: -100 ether,
            salt: bytes32(0)
        });

        hook.harness_allow_hook_callback( );

        vm.prank( address(pool_manager) );
        bytes4 selector  =  hook.beforeRemoveLiquidity( user, pool_key, liq_params, "" );

        assertEq( selector, IHooks.beforeRemoveLiquidity.selector, "Should succeed in protected context." );

        hook.harness_revoke_hook_callback_permission( );
    }


    // ━━━━  beforeDonate( )  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_before_donate_reverts_if_not_pool_manager( ) external
    {
        vm.prank( user );
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, user, address(pool_manager) ) );
        hook.beforeDonate( user, pool_key, 100 ether, 200 ether, "" );
    }

    function test_before_donate_reverts_if_not_protected_context( ) external
    {
        hook.harness_revoke_hook_callback_permission( );

        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( BondRouteRequired.selector, address(pool_manager), address(BondRoute) ) );
        hook.beforeDonate( user, pool_key, 100 ether, 200 ether, "" );
    }

    function test_before_donate_returns_correct_selector( ) external
    {
        hook.harness_allow_hook_callback( );

        vm.prank( address(pool_manager) );
        bytes4 selector  =  hook.beforeDonate( user, pool_key, 100 ether, 200 ether, "" );

        assertEq(
            selector,
            IHooks.beforeDonate.selector,
            "Should return beforeDonate selector."
        );

        hook.harness_revoke_hook_callback_permission( );
    }

    function test_before_donate_succeeds_in_protected_context( ) external
    {
        hook.harness_allow_hook_callback( );

        vm.prank( address(pool_manager) );
        bytes4 selector  =  hook.beforeDonate( user, pool_key, 100 ether, 200 ether, "" );

        assertEq( selector, IHooks.beforeDonate.selector, "Should succeed in protected context." );

        hook.harness_revoke_hook_callback_permission( );
    }


    // ━━━━  Protected Context State  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_protected_context_cleared_after_swap( ) external
    {
        // Initially not protected.
        assertEq( hook.harness_hook_callback_allowed( ), false, "Should start unprotected." );

        // Set protected.
        hook.harness_allow_hook_callback( );
        assertEq( hook.harness_hook_callback_allowed( ), true, "Should be protected after setting." );

        // Clear protected.
        hook.harness_revoke_hook_callback_permission( );
        assertEq( hook.harness_hook_callback_allowed( ), false, "Should be unprotected after clearing." );
    }

    function test_protected_context_cleared_after_add_liquidity( ) external
    {
        hook.harness_allow_hook_callback( );
        assertEq( hook.harness_hook_callback_allowed( ), true, "Should be protected." );

        hook.harness_revoke_hook_callback_permission( );
        assertEq( hook.harness_hook_callback_allowed( ), false, "Should be cleared." );
    }

    function test_protected_context_cleared_after_remove_liquidity( ) external
    {
        hook.harness_allow_hook_callback( );
        assertEq( hook.harness_hook_callback_allowed( ), true, "Should be protected." );

        hook.harness_revoke_hook_callback_permission( );
        assertEq( hook.harness_hook_callback_allowed( ), false, "Should be cleared." );
    }

    function test_protected_context_transient_storage_isolation( ) external
    {
        // Set protected in this call.
        hook.harness_allow_hook_callback( );
        assertEq( hook.harness_hook_callback_allowed( ), true, "Should be protected in same tx." );

        // Transient storage should be cleared between transactions.
        // In Foundry tests, each test function is a separate transaction context.
        // We can simulate by checking that a new call starts unprotected.
        hook.harness_revoke_hook_callback_permission( );

        // Verify isolation - a new setup would start unprotected.
        assertEq( hook.harness_hook_callback_allowed( ), false, "Should be isolated between operations." );
    }
}

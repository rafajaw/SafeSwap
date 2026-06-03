// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@test/SafeSwap/TestBase.t.sol";
import "@SafeSwapRouter/HookRegistry.sol";
import { SafeSwapHook } from "@SafeSwapHook/SafeSwapHook.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BeforeSwapDelta } from "@UniswapV4Core/types/BeforeSwapDelta.sol";


contract RepricingRebateTest is SafeSwapTestBase {

    // ━━━━  HOOK ADDRESS CONFIG  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_hook_decodes_its_rebate_profile_from_address( ) external view
    {
        assertEq( hook.rebate_profile( ), REBATE_PROFILE_50, "hook should decode profile 5 from its address." );
        assertEq( uint8(uint160(address(hook)) >> HOOK_ADDRESS_MAGIC_SHIFT), SAFESWAP_HOOK_ADDRESS_MAGIC, "magic byte." );
    }


    // ━━━━  REGISTRY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_registered_hook_is_resolvable( ) external view
    {
        assertEq( router.get_hook( REBATE_PROFILE_50 ), address(hook), "profile 5 should resolve to the deployed hook." );
        assertTrue( router.registeredHook( address(hook) ), "hook should be marked registered." );
    }

    function test_get_hook_reverts_for_unregistered_profile( ) external
    {
        vm.expectRevert( abi.encodeWithSelector( HookConfigNotRegistered.selector, uint8(3) ) );
        router.get_hook( 3 );
    }

    function test_register_reverts_on_unapproved_codehash( ) external
    {
        // A contract whose runtime codehash is not the approved SafeSwap hook code cannot register.
        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( UnauthorizedHookCode.selector, address(pool_manager), address(pool_manager).codehash ) );
        router.register_hook( REBATE_PROFILE_50 );
    }

    function test_register_reverts_on_profile_mismatch( ) external
    {
        // The hook's address encodes profile 5; submitting a different profile must revert.
        vm.prank( address(hook) );
        vm.expectRevert( abi.encodeWithSelector( HookAddressConfigMismatch.selector, address(hook), SAFESWAP_HOOK_ADDRESS_MAGIC, REBATE_PROFILE_50, uint8(6) ) );
        router.register_hook( 6 );
    }

    function test_register_reverts_on_duplicate_profile_from_different_hook( ) external
    {
        // A second, distinct hook address for the same profile cannot displace the first registration.
        address second  =  address( uint160(address(hook)) | (uint160(1) << 60) );
        deployCodeTo( "SafeSwapHook.sol:SafeSwapHook", second );

        vm.expectRevert( abi.encodeWithSelector( HookConfigAlreadyRegistered.selector, REBATE_PROFILE_50, address(hook) ) );
        SafeSwapHook(second).initialize_once( );
    }

    function test_register_is_idempotent_for_same_hook( ) external
    {
        // Re-registering the same hook for its profile is a no-op, not a revert.
        hook.initialize_once( );
        assertEq( router.get_hook( REBATE_PROFILE_50 ), address(hook), "registration should remain stable." );
    }


    // ━━━━  HOOK GATING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_before_swap_requires_pool_manager_caller( ) external
    {
        vm.expectRevert( abi.encodeWithSelector( CallerNotPoolManager.selector, address(this), address(pool_manager) ) );
        hook.beforeSwap( address(router), _dummy_pool_key( ), _dummy_swap_params( ), "" );
    }

    function test_before_swap_requires_router_sender( ) external
    {
        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( CallerNotRouter.selector, other_user, address(router) ) );
        hook.beforeSwap( other_user, _dummy_pool_key( ), _dummy_swap_params( ), "" );
    }

    function test_before_swap_succeeds_for_router_initiated_action( ) external
    {
        vm.prank( address(pool_manager) );
        ( bytes4 selector, BeforeSwapDelta delta, uint24 fee )  =  hook.beforeSwap( address(router), _dummy_pool_key( ), _dummy_swap_params( ), "" );

        assertEq( selector, IHooks.beforeSwap.selector, "should return the beforeSwap selector." );
        assertEq( fee, 0, "static-fee pools return a zero LP fee override." );
        delta;  // ZERO_DELTA.
    }

    function test_before_initialize_requires_router_sender( ) external
    {
        vm.prank( address(pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( CallerNotRouter.selector, other_user, address(router) ) );
        hook.beforeInitialize( other_user, _dummy_pool_key( ), SQRT_PRICE_1_1 );
    }


    // ━━━━  REBATE MATH  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_rebate_is_proportional_to_tick_movement_and_profile( ) external view
    {
        // profile 5 = 50% share; 200 ticks ~ 200 bps movement -> effective 100 bps -> 1% of the charged amount.
        ( uint256 rebate, uint256 movement_bps )  =  router.__OFF_CHAIN__preview_repricing_rebate( REBATE_PROFILE_50, 1000 ether, 0, 200 );

        assertEq( movement_bps, 200, "200 ticks ~ 200 bps." );
        assertEq( rebate, 10 ether, "50% of 200 bps = 100 bps = 1% of 1000 = 10." );
    }

    function test_rebate_is_zero_without_movement( ) external view
    {
        ( uint256 rebate, uint256 movement_bps )  =  router.__OFF_CHAIN__preview_repricing_rebate( REBATE_PROFILE_50, 1000 ether, 100, 100 );

        assertEq( movement_bps, 0, "no tick movement." );
        assertEq( rebate, 0, "no movement -> no rebate." );
    }

    function test_rebate_is_symmetric_in_direction( ) external view
    {
        ( uint256 up, )    =  router.__OFF_CHAIN__preview_repricing_rebate( REBATE_PROFILE_50, 1000 ether, 0, 200 );
        ( uint256 down, )  =  router.__OFF_CHAIN__preview_repricing_rebate( REBATE_PROFILE_50, 1000 ether, 0, -200 );

        assertEq( up, down, "rebate depends on absolute movement, not direction." );
    }

    function test_rebate_is_zero_for_profile_zero( ) external view
    {
        ( uint256 rebate, )  =  router.__OFF_CHAIN__preview_repricing_rebate( 0, 1000 ether, 0, 500 );

        assertEq( rebate, 0, "profile 0 = 0% rebate." );
    }

    function test_rebate_is_capped_on_violent_repricing( ) external view
    {
        // profile 10 = 100% share; a 5000-bps move would imply 50% but the cap is 10% of the charged amount.
        ( uint256 rebate, uint256 movement_bps )  =  router.__OFF_CHAIN__preview_repricing_rebate( 10, 1000 ether, 0, 5000 );

        assertEq( movement_bps, 5000, "5000 ticks ~ 5000 bps." );
        assertEq( rebate, 100 ether, "capped at MAX_REPRICING_REBATE_BPS = 1000 bps = 10% of 1000." );
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _dummy_pool_key( ) private view returns ( PoolKey memory )
    {
        return PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: 3000,
            tickSpacing: TICK_SPACING_60,
            hooks: IHooks(address(hook))
        });
    }

    function _dummy_swap_params( ) private pure returns ( IPoolManager.SwapParams memory )
    {
        return IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: SQRT_PRICE_1_1 });
    }
}

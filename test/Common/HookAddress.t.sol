// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IHookAddressTests } from "@test/Common/TestManifest.sol";
import { SafeSwapTestHelper } from "@test/helpers/SafeSwapTestHelper.t.sol";
import { HookAddress } from "@SafeSwapCommon/HookAddress.sol";


/**
 * @title HookAddressTest
 * @notice Tests BCD hook-address config decoding and exact v4 permission matching.
 * @dev Implements IHookAddressTests from TestManifest.sol.
 */
contract HookAddressTest is IHookAddressTests, SafeSwapTestHelper {

    function decode_external( address hook )
    external  pure returns ( uint16 base_fee_bps, uint8 rebate_percent )
    {
        return HookAddress.decode( hook );
    }

    function test_decode_valid_bcd_hook_address_returns_base_fee_and_rebate_percent( )
    external  pure
    {
        address hook  =  _hook_address( 30, 50, HookAddress.REQUIRED_PERMISSIONS );

        ( uint16 base_fee_bps, uint8 rebate_percent )  =  HookAddress.decode( hook );

        assertEq( base_fee_bps, 30, "Base fee should decode from F030." );
        assertEq( rebate_percent, 50, "Rebate percent should decode from C50." );
    }

    function test_decode_zero_digits_returns_zero_base_fee_and_zero_rebate_percent( )
    external  pure
    {
        address hook  =  _hook_address( 0, 0, HookAddress.REQUIRED_PERMISSIONS );

        ( uint16 base_fee_bps, uint8 rebate_percent )  =  HookAddress.decode( hook );

        assertEq( base_fee_bps, 0, "Zero base-fee digits should decode to zero bps." );
        assertEq( rebate_percent, 0, "Zero rebate digits should decode to zero percent." );
    }

    function test_decode_max_supported_digits_returns_nine_hundred_ninety_nine_bps_and_ninety_percent( )
    external  pure
    {
        address hook  =  _hook_address( 999, 90, HookAddress.REQUIRED_PERMISSIONS );

        ( uint16 base_fee_bps, uint8 rebate_percent )  =  HookAddress.decode( hook );

        assertEq( base_fee_bps, 999, "F999 should decode to 999 bps." );
        assertEq( rebate_percent, 90, "C90 should decode to 90 percent." );
    }

    function test_decode_reverts_when_fee_marker_is_not_f( )
    external
    {
        address hook  =  _hook_address_with_config_nibbles( 0xE, 0, 3, 0, HookAddress.CAPTURE_MARKER, 5, 0, HookAddress.REQUIRED_PERMISSIONS );

        vm.expectRevert( abi.encodeWithSelector( HookAddress.InvalidHookConfig.selector, hook ) );
        this.decode_external( hook );
    }

    function test_decode_reverts_when_capture_marker_is_not_c( )
    external
    {
        address hook  =  _hook_address_with_config_nibbles( HookAddress.FEE_MARKER, 0, 3, 0, 0xB, 5, 0, HookAddress.REQUIRED_PERMISSIONS );

        vm.expectRevert( abi.encodeWithSelector( HookAddress.InvalidHookConfig.selector, hook ) );
        this.decode_external( hook );
    }

    function test_decode_reverts_when_base_fee_hundreds_digit_is_not_decimal( )
    external
    {
        address hook  =  _hook_address_with_config_nibbles( HookAddress.FEE_MARKER, 0xA, 3, 0, HookAddress.CAPTURE_MARKER, 5, 0, HookAddress.REQUIRED_PERMISSIONS );

        vm.expectRevert( abi.encodeWithSelector( HookAddress.InvalidHookConfig.selector, hook ) );
        this.decode_external( hook );
    }

    function test_decode_reverts_when_base_fee_tens_digit_is_not_decimal( )
    external
    {
        address hook  =  _hook_address_with_config_nibbles( HookAddress.FEE_MARKER, 0, 0xA, 0, HookAddress.CAPTURE_MARKER, 5, 0, HookAddress.REQUIRED_PERMISSIONS );

        vm.expectRevert( abi.encodeWithSelector( HookAddress.InvalidHookConfig.selector, hook ) );
        this.decode_external( hook );
    }

    function test_decode_reverts_when_base_fee_ones_digit_is_not_decimal( )
    external
    {
        address hook  =  _hook_address_with_config_nibbles( HookAddress.FEE_MARKER, 0, 3, 0xA, HookAddress.CAPTURE_MARKER, 5, 0, HookAddress.REQUIRED_PERMISSIONS );

        vm.expectRevert( abi.encodeWithSelector( HookAddress.InvalidHookConfig.selector, hook ) );
        this.decode_external( hook );
    }

    function test_decode_reverts_when_rebate_tens_digit_is_not_decimal( )
    external
    {
        address hook  =  _hook_address_with_config_nibbles( HookAddress.FEE_MARKER, 0, 3, 0, HookAddress.CAPTURE_MARKER, 0xA, 0, HookAddress.REQUIRED_PERMISSIONS );

        vm.expectRevert( abi.encodeWithSelector( HookAddress.InvalidHookConfig.selector, hook ) );
        this.decode_external( hook );
    }

    function test_decode_reverts_when_rebate_ones_digit_is_not_zero( )
    external
    {
        address hook  =  _hook_address_with_config_nibbles( HookAddress.FEE_MARKER, 0, 3, 0, HookAddress.CAPTURE_MARKER, 5, 5, HookAddress.REQUIRED_PERMISSIONS );

        vm.expectRevert( abi.encodeWithSelector( HookAddress.InvalidHookConfig.selector, hook ) );
        this.decode_external( hook );
    }

    function test_has_required_permissions_accepts_exact_safeswap_permission_bitmap( )
    external  pure
    {
        address hook  =  _hook_address( 30, 50, HookAddress.REQUIRED_PERMISSIONS );

        assertTrue( HookAddress.has_required_permissions( hook ), "Exact SafeSwap permissions should be accepted." );
    }

    function test_has_required_permissions_rejects_missing_before_initialize_permission( )
    external  pure
    {
        address hook  =  _hook_address( 30, 50, HookAddress.REQUIRED_PERMISSIONS & ~uint160(1 << 13) );

        assertFalse( HookAddress.has_required_permissions( hook ), "Missing beforeInitialize should be rejected." );
    }

    function test_has_required_permissions_rejects_missing_before_add_liquidity_permission( )
    external  pure
    {
        address hook  =  _hook_address( 30, 50, HookAddress.REQUIRED_PERMISSIONS & ~uint160(1 << 11) );

        assertFalse( HookAddress.has_required_permissions( hook ), "Missing beforeAddLiquidity should be rejected." );
    }

    function test_has_required_permissions_rejects_missing_before_remove_liquidity_permission( )
    external  pure
    {
        address hook  =  _hook_address( 30, 50, HookAddress.REQUIRED_PERMISSIONS & ~uint160(1 << 9) );

        assertFalse( HookAddress.has_required_permissions( hook ), "Missing beforeRemoveLiquidity should be rejected." );
    }

    function test_has_required_permissions_rejects_missing_before_swap_permission( )
    external  pure
    {
        address hook  =  _hook_address( 30, 50, HookAddress.REQUIRED_PERMISSIONS & ~uint160(1 << 7) );

        assertFalse( HookAddress.has_required_permissions( hook ), "Missing beforeSwap should be rejected." );
    }

    function test_has_required_permissions_rejects_extra_before_donate_permission( )
    external  pure
    {
        address hook  =  _hook_address( 30, 50, HookAddress.REQUIRED_PERMISSIONS | uint160(1 << 5) );

        assertFalse( HookAddress.has_required_permissions( hook ), "Extra beforeDonate should be rejected." );
    }

    function test_has_required_permissions_rejects_extra_return_delta_permission( )
    external  pure
    {
        address hook  =  _hook_address( 30, 50, HookAddress.REQUIRED_PERMISSIONS | uint160(1 << 3) );

        assertFalse( HookAddress.has_required_permissions( hook ), "Extra beforeSwapReturnDelta should be rejected." );
    }
}

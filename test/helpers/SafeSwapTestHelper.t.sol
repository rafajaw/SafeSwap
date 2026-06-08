// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import { HookAddress } from "@SafeSwapCommon/HookAddress.sol";


contract SafeSwapTestHelper is Test {

    function _hook_address( uint16 base_fee_bps, uint8 rebate_percent, uint160 permission_bits ) internal pure returns ( address hook )
    {
        uint256 d2  =  base_fee_bps / 100;
        uint256 d1  =  ( base_fee_bps / 10 ) % 10;
        uint256 d0  =  base_fee_bps % 10;
        uint256 rebate_tens_digit  =  rebate_percent / 10;

        uint160 bits  =  uint160(
            ( uint256(HookAddress.FEE_MARKER) << HookAddress.FEE_MARKER_SHIFT )
            | ( d2 << HookAddress.BASE_FEE_D2_SHIFT )
            | ( d1 << HookAddress.BASE_FEE_D1_SHIFT )
            | ( d0 << HookAddress.BASE_FEE_D0_SHIFT )
            | ( uint256(HookAddress.CAPTURE_MARKER) << HookAddress.CAPTURE_MARKER_SHIFT )
            | ( rebate_tens_digit << HookAddress.REBATE_TENS_SHIFT )
            | uint256(permission_bits)
        );

        hook  =  address(bits);
    }

    function _hook_address_with_config_nibbles(
        uint8 fee_marker,
        uint8 base_fee_hundreds,
        uint8 base_fee_tens,
        uint8 base_fee_ones,
        uint8 capture_marker,
        uint8 rebate_tens_digit,
        uint8 rebate_ones_digit,
        uint160 permission_bits
    ) internal pure returns ( address hook )
    {
        uint160 bits  =  uint160(
            ( uint256(fee_marker) << HookAddress.FEE_MARKER_SHIFT )
            | ( uint256(base_fee_hundreds) << HookAddress.BASE_FEE_D2_SHIFT )
            | ( uint256(base_fee_tens) << HookAddress.BASE_FEE_D1_SHIFT )
            | ( uint256(base_fee_ones) << HookAddress.BASE_FEE_D0_SHIFT )
            | ( uint256(capture_marker) << HookAddress.CAPTURE_MARKER_SHIFT )
            | ( uint256(rebate_tens_digit) << HookAddress.REBATE_TENS_SHIFT )
            | ( uint256(rebate_ones_digit) << HookAddress.REBATE_ONES_SHIFT )
            | uint256(permission_bits)
        );

        hook  =  address(bits);
    }
}

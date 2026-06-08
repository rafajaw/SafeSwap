// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;


/**
 * @title ISafeSwapHook
 * @notice Minimal interface for a SafeSwap config hook (an EIP-1167 clone of the implementation). Config is decoded
 *         from the clone's own address, so `get_hook_config` reverts when called on the implementation rather than a clone.
 */
interface ISafeSwapHook {
    function get_hook_config( ) external view returns ( uint16 base_fee_bps, uint8 rebate_percent );
    function initialize_once( ) external;
}

/**
 * @notice Registration surface the SafeSwap config hook calls on the canonical router.
 */
interface ISafeSwapHookRegistry {
    function register_hook( uint16 base_fee_bps, uint8 rebate_percent ) external;
}

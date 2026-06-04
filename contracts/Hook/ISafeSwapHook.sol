// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;


/**
 * @title ISafeSwapHook
 * @notice Minimal interface for a SafeSwap config hook (an EIP-1167 clone of the audited implementation). Config is decoded
 *         from the clone's own address, so these getters only return meaningful values when called on a clone, not the impl.
 */
interface ISafeSwapHook {
    function base_fee_bps( ) external view returns ( uint16 );
    function rebate_percent( ) external view returns ( uint8 );
    function initialize_once( ) external;
}

/**
 * @notice Registration surface the SafeSwap config hook calls on the canonical router.
 */
interface ISafeSwapHookRegistry {
    function register_hook( uint16 base_fee_bps, uint8 rebate_percent ) external;
}

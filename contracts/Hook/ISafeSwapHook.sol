// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;


/**
 * @title ISafeSwapHook
 * @notice Minimal interface for a SafeSwap config hook instance.
 */
interface ISafeSwapHook {
    function rebate_profile( ) external view returns ( uint8 );
    function initialize_once( ) external;
}

/**
 * @notice Registration surface the SafeSwap config hook calls on the canonical router.
 */
interface ISafeSwapHookRegistry {
    function register_hook( uint8 rebate_profile ) external;
}

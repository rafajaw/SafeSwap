// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwapRouter/Definitions.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error UnauthorizedHookCode( address caller, bytes32 codehash );
error HookAddressConfigMismatch( address hook, uint8 magic, uint8 encoded_rebate_profile, uint8 submitted_rebate_profile );
error HookPermissionsMismatch( address hook, uint160 permission_bits, uint160 required_permission_bits );
error HookConfigAlreadyRegistered( uint8 rebate_profile, address existing_hook );
error HookConfigNotRegistered( uint8 rebate_profile );


// ━━━━  EVENTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

event HookRegistered( uint8 indexed rebate_profile, address indexed hook );


/**
 * @title HookRegistry
 * @notice Permissionless-deployment registry binding each LP repricing rebate profile to its SafeSwap config hook.
 *
 * @dev Hooks are deployed permissionlessly but registered under three independent proofs:
 *      - exact runtime codehash allowlist  → proves the hook runs the audited SafeSwap hook bytecode (proves behavior);
 *      - address-bit config validation     → proves the hook's CREATE2 address encodes the claimed rebate profile;
 *      - Uniswap V4 permission validation   → proves the hook address carries exactly the required hook permission bits.
 *
 *      The approved runtime codehash is published in ChainConfig by the protocol config signer and read lazily so the
 *      router can be deployed before the audited hook bytecode hash is finalized.
 */
abstract contract HookRegistry {

    mapping( uint8 => address ) public hookByProfile;
    mapping( address => bool ) public registeredHook;


    // ━━━━  REGISTRATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Register the calling SafeSwap config hook for its rebate profile. Called once by the hook itself after deploy.
     * @param rebate_profile LP repricing rebate profile the caller claims to serve. Must match the caller's address bits.
     *
     * @dev EMITTED EVENTS:
     *      - `HookRegistered(rebate_profile, hook)` on success.
     *
     * @dev ERROR CODES:
     *      - `UnauthorizedHookCode(caller, codehash)` if the caller's runtime codehash is not the approved SafeSwap hook code.
     *      - `HookAddressConfigMismatch(...)` if the caller's address bits do not encode the SafeSwap magic and `rebate_profile`.
     *      - `HookPermissionsMismatch(...)` if the caller's address does not carry exactly the required V4 hook permissions.
     *      - `HookConfigAlreadyRegistered(rebate_profile, existing)` if a different hook already serves this profile.
     */
    function register_hook( uint8 rebate_profile )
    external
    {
        _require_approved_hook_runtime( msg.sender );
        _require_address_config_matches( msg.sender, rebate_profile );
        _require_hook_permissions( msg.sender );

        address existing  =  hookByProfile[ rebate_profile ];
        if(  existing != address(0)  &&  existing != msg.sender  )  revert HookConfigAlreadyRegistered({ rebate_profile: rebate_profile, existing_hook: existing });

        hookByProfile[ rebate_profile ]  =  msg.sender;
        registeredHook[ msg.sender ]     =  true;

        emit HookRegistered( rebate_profile, msg.sender );
    }


    // ━━━━  RESOLUTION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Resolve the registered SafeSwap config hook for a rebate profile.
     * @param rebate_profile LP repricing rebate profile.
     * @return hook Registered config hook address. Reverts if no hook is registered for the profile.
     */
    function get_hook( uint8 rebate_profile )
    external  view returns ( address hook )
    {
        hook  =  _resolve_hook( rebate_profile );
    }

    function _resolve_hook( uint8 rebate_profile ) internal view returns ( address hook )
    {
        hook  =  hookByProfile[ rebate_profile ];
        if(  hook == address(0)  )  revert HookConfigNotRegistered({ rebate_profile: rebate_profile });
    }


    // ━━━━  VALIDATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // *SECURITY*  -  Authorize the hook by EXACT local runtime codehash, never by interface self-identification or tx.origin.
    //                An EIP-7702 delegated EOA's code is the `0xef0100 || delegate` designator, whose hash never equals the
    //                audited hook runtime codehash, so this rejects delegated EOAs impersonating a hook.
    function _require_approved_hook_runtime( address account ) internal view
    {
        bytes32 approved_codehash  =  ChainConfig.read_bytes32( CONFIG_SIGNER, SAFESWAP_HOOK_CODEHASH_KEY );

        bytes32 codehash;
        assembly { codehash := extcodehash( account ) }

        if(  codehash != approved_codehash  )  revert UnauthorizedHookCode({ caller: account, codehash: codehash });
    }

    function _require_address_config_matches( address hook, uint8 rebate_profile ) internal pure
    {
        uint160 hook_bits        =  uint160(hook);
        uint8 magic              =  uint8(hook_bits >> HOOK_ADDRESS_MAGIC_SHIFT);
        uint8 encoded_profile    =  uint8((hook_bits >> HOOK_ADDRESS_REBATE_PROFILE_SHIFT) & HOOK_ADDRESS_REBATE_PROFILE_MASK);

        bool magic_matches    =  magic == SAFESWAP_HOOK_ADDRESS_MAGIC;
        bool profile_matches  =  encoded_profile == rebate_profile  &&  rebate_profile <= MAX_REBATE_PROFILE;

        if(  magic_matches == false  ||  profile_matches == false  )
        {
            revert HookAddressConfigMismatch({ hook: hook, magic: magic, encoded_rebate_profile: encoded_profile, submitted_rebate_profile: rebate_profile });
        }
    }

    function _require_hook_permissions( address hook ) internal pure
    {
        uint160 permission_bits  =  uint160(hook) & HOOK_PERMISSIONS_MASK;

        if(  permission_bits != REQUIRED_HOOK_PERMISSIONS  )
        {
            revert HookPermissionsMismatch({ hook: hook, permission_bits: permission_bits, required_permission_bits: REQUIRED_HOOK_PERMISSIONS });
        }
    }
}

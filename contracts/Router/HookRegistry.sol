// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwapCommon/Definitions.sol";
import { HookAddress } from "@SafeSwapCommon/HookAddress.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error UnauthorizedHookCode( address caller, bytes32 codehash );
error HookConfigMismatch( address hook, uint16 decoded_base_fee_bps, uint8 decoded_rebate_percent, uint16 submitted_base_fee_bps, uint8 submitted_rebate_percent );
error HookPermissionsMismatch( address hook );
error HookConfigAlreadyRegistered( uint16 base_fee_bps, uint8 rebate_percent, address existing_hook );
error HookConfigNotRegistered( uint16 base_fee_bps, uint8 rebate_percent );


// ━━━━  EVENTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

event HookRegistered( address indexed hook, uint16 indexed base_fee_bps, uint8 indexed rebate_percent );


/**
 * @title HookRegistry
 * @notice Permissionless-deployment registry binding each `(base fee, capture)` config to its SafeSwap hook clone.
 *
 * @dev Hooks are deployed permissionlessly as EIP-1167 clones of the implementation but registered under three independent
 *      proofs: exact runtime codehash (the clone stub, with the impl address baked in — proves the clone delegatecalls the
 *      implementation); address-bit config (the `HookAddress` BCD must decode to the submitted config); and the Uniswap V4
 *      permission bits. The approved stub codehash is published in ChainConfig and read lazily so the router can deploy
 *      before the stub bytecode hash is finalized.
 */
abstract contract HookRegistry {

    mapping( uint256 => address ) internal _hook_by_config;


    // ━━━━  REGISTRATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Register the calling hook clone for its `(base_fee_bps, rebate_percent)` config. Called once by the clone.
     *
     * @dev EMITTED EVENTS:
     *      - `HookRegistered(hook, base_fee_bps, rebate_percent)` on success.
     *
     * @dev ERROR CODES:
     *      - `UnauthorizedHookCode(caller, codehash)` if the caller's runtime codehash is not the approved clone stub.
     *      - `HookConfigMismatch(...)` if the caller's address does not decode to the submitted config.
     *      - `HookPermissionsMismatch(hook)` if the caller's address lacks the required V4 hook permissions.
     *      - `HookConfigAlreadyRegistered(...)` if a different hook already serves this config.
     */
    function register_hook( uint16 base_fee_bps, uint8 rebate_percent )
    external
    {
        _require_approved_hook_runtime( msg.sender );

        ( uint16 decoded_base_fee_bps, uint8 decoded_rebate_percent )  =  HookAddress.decode( msg.sender );
        if(  decoded_base_fee_bps != base_fee_bps  ||  decoded_rebate_percent != rebate_percent  )
        {
            revert HookConfigMismatch({
                hook: msg.sender,
                decoded_base_fee_bps: decoded_base_fee_bps,
                decoded_rebate_percent: decoded_rebate_percent,
                submitted_base_fee_bps: base_fee_bps,
                submitted_rebate_percent: rebate_percent
            });
        }

        if(  HookAddress.has_required_permissions( msg.sender ) == false  )  revert HookPermissionsMismatch({ hook: msg.sender });

        // *DESIGN*  -  First valid clone to claim a config wins (a duplicate reverts); hook addresses are intentionally per-chain, not deterministic.
        //             The base-fee / rebate config choice is permissionless and trustless: anyone mines + deploys a clone; router/NFT gate every hook touch.
        uint256 key       =  _config_key( base_fee_bps, rebate_percent );
        address existing  =  _hook_by_config[ key ];
        if(  existing != address(0)  &&  existing != msg.sender  )  revert HookConfigAlreadyRegistered({ base_fee_bps: base_fee_bps, rebate_percent: rebate_percent, existing_hook: existing });

        _hook_by_config[ key ]  =  msg.sender;

        emit HookRegistered( msg.sender, base_fee_bps, rebate_percent );
    }


    // ━━━━  RESOLUTION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Resolve the registered hook clone for a `(base_fee_bps, rebate_percent)` config. Reverts if none is registered.
     */
    function get_hook_address( uint16 base_fee_bps, uint8 rebate_percent )
    external  view returns ( address hook )
    {
        hook  =  _resolve_hook( base_fee_bps, rebate_percent );
    }

    /**
     * @notice Reverse lookup: the `(base_fee_bps, rebate_percent)` config a registered hook clone serves, decoded from its
     *         address. Reverts with `HookConfigNotRegistered` if `hook` is not the registered hook for that config.
     */
    function get_hook_config( address hook )
    external  view returns ( uint16 base_fee_bps, uint8 rebate_percent )
    {
        ( base_fee_bps, rebate_percent )  =  HookAddress.decode( hook );
        if(  _hook_by_config[ _config_key( base_fee_bps, rebate_percent ) ] != hook  )  revert HookConfigNotRegistered({ base_fee_bps: base_fee_bps, rebate_percent: rebate_percent });
    }

    function _resolve_hook( uint16 base_fee_bps, uint8 rebate_percent ) internal view returns ( address hook )
    {
        hook  =  _hook_by_config[ _config_key( base_fee_bps, rebate_percent ) ];
        if(  hook == address(0)  )  revert HookConfigNotRegistered({ base_fee_bps: base_fee_bps, rebate_percent: rebate_percent });
    }

    function _config_key( uint16 base_fee_bps, uint8 rebate_percent ) private pure returns ( uint256 )
    {
        return ( uint256(base_fee_bps) << 8 ) | uint256(rebate_percent);
    }


    // ━━━━  VALIDATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // *SECURITY*  -  Authorize the clone by EXACT runtime codehash (the EIP-1167 stub with the impl address baked in),
    //                never by interface self-identification or tx.origin. An EIP-7702 delegated EOA's code is the
    //                `0xef0100 || delegate` designator, whose hash never equals the stub codehash, so this rejects it.
    function _require_approved_hook_runtime( address account ) internal view
    {
        bytes32 approved_codehash  =  ChainConfig.read_bytes32( CONFIG_SIGNER, SAFESWAP_HOOK_CODEHASH_KEY );

        bytes32 codehash;
        assembly { codehash := extcodehash( account ) }

        if(  codehash != approved_codehash  )  revert UnauthorizedHookCode({ caller: account, codehash: codehash });
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console } from "forge-std/Script.sol";
import { SafeSwapHook } from "@SafeSwapHook/SafeSwapHook.sol";
import { ISafeSwapHook } from "@SafeSwapHook/ISafeSwapHook.sol";
import {
    SAFESWAP_HOOK_ADDRESS_MAGIC,
    HOOK_ADDRESS_MAGIC_SHIFT,
    HOOK_ADDRESS_REBATE_PROFILE_SHIFT,
    HOOK_ADDRESS_REBATE_PROFILE_MASK,
    HOOK_PERMISSIONS_MASK,
    REQUIRED_HOOK_PERMISSIONS,
    MAX_REBATE_PROFILE
} from "@SafeSwapRouter/Definitions.sol";


/**
 * @title DeploySafeSwapHook
 * @notice Mine a CREATE2 salt for a SafeSwapHook serving a given LP repricing rebate profile, deploy it through the
 *         canonical deterministic CREATE2 factory, and register it with the router.
 *
 * @dev The mined address must satisfy: magic byte 0x55, the encoded rebate profile, and exactly the required Uniswap V4
 *      hook permission bits. Only ~26 bits are constrained, so mining is fast. Run with the audited SafeSwapHook bytecode
 *      and the router/PoolManager already published in ChainConfig.
 *
 *      Usage: REBATE_PROFILE=5 forge script script/DeploySafeSwapHook.s.sol --broadcast --rpc-url <url>
 */
contract DeploySafeSwapHook is Script {

    // *NOTE*  -  `CREATE2_FACTORY` (the canonical deterministic deployment proxy, same address on every EVM chain) is
    //            inherited from forge-std's CommonBase.

    function run( ) external
    {
        uint8 rebate_profile  =  uint8(vm.envUint( "REBATE_PROFILE" ));
        require( rebate_profile <= MAX_REBATE_PROFILE, "rebate_profile out of range" );

        bytes memory init_code  =  type(SafeSwapHook).creationCode;
        bytes32 init_code_hash  =  keccak256( init_code );

        ( bytes32 salt, address predicted )  =  mine_salt( CREATE2_FACTORY, init_code_hash, rebate_profile, 0, 5_000_000 );
        require( predicted != address(0), "salt not found in iteration budget" );

        console.log( "SafeSwapHook predicted address:", predicted );
        console.log( "rebate_profile:", rebate_profile );

        vm.startBroadcast( );

        // CREATE2 factory calldata is `salt ++ init_code`; it deploys and returns the new address.
        ( bool ok, bytes memory ret )  =  CREATE2_FACTORY.call( abi.encodePacked( salt, init_code ) );
        require( ok, "CREATE2 deploy failed" );

        address deployed  =  predicted;
        if(  ret.length == 20  )  deployed  =  address(bytes20(ret));
        require( deployed == predicted, "deployed address mismatch" );

        ISafeSwapHook(deployed).initialize_once( );

        vm.stopBroadcast( );

        console.log( "SafeSwapHook deployed and registered:", deployed );
    }

    /**
     * @notice Search for a CREATE2 salt producing a SafeSwapHook address that encodes the rebate profile and required bits.
     * @return salt First salt whose address satisfies the SafeSwap config-hook constraints (or zero if none found).
     * @return hook Predicted hook address for that salt (or zero address if not found).
     */
    function mine_salt( address deployer, bytes32 init_code_hash, uint8 rebate_profile, uint256 start, uint256 max_iterations )
    public pure returns ( bytes32 salt, address hook )
    {
        for(  uint256 i = start  ;  i < start + max_iterations  ;  i = i + 1  )
        {
            bytes32 candidate_salt  =  bytes32(i);
            address candidate       =  _create2_address( deployer, candidate_salt, init_code_hash );

            if(  _address_matches( candidate, rebate_profile )  )  return ( candidate_salt, candidate );
        }

        return ( bytes32(0), address(0) );
    }

    function _address_matches( address candidate, uint8 rebate_profile ) private pure returns ( bool )
    {
        uint160 bits  =  uint160(candidate);

        bool magic_ok    =  uint8(bits >> HOOK_ADDRESS_MAGIC_SHIFT) == SAFESWAP_HOOK_ADDRESS_MAGIC;
        bool profile_ok  =  uint8((bits >> HOOK_ADDRESS_REBATE_PROFILE_SHIFT) & HOOK_ADDRESS_REBATE_PROFILE_MASK) == rebate_profile;
        bool perms_ok    =  (bits & HOOK_PERMISSIONS_MASK) == REQUIRED_HOOK_PERMISSIONS;

        return magic_ok  &&  profile_ok  &&  perms_ok;
    }

    function _create2_address( address deployer, bytes32 salt, bytes32 init_code_hash ) private pure returns ( address )
    {
        bytes32 hash  =  keccak256( abi.encodePacked( bytes1(0xff), deployer, salt, init_code_hash ) );

        return address(uint160(uint256(hash)));
    }
}

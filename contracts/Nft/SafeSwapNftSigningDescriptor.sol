// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { PoolManagerIntegration } from "@SafeSwapCommon/PoolManagerIntegration.sol";
import { SafeSwapPositionInfo } from "@SafeSwapCommon/Types.sol";
import { ISafeSwapNft } from "@SafeSwapNft/ISafeSwapNft.sol";
import {
    ISafeSwapNftActions,
    ISafeSwapNftSigningDescriptor
} from "@SafeSwapNft/ISafeSwapNftSigningDescriptor.sol";
import {
    AddPositionLiquidityParams,
    CollectFeesParams,
    CreatePositionParams,
    ModifyLiquidityLib,
    RemovePositionLiquidityParams
} from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";
import { UnsupportedCall } from "@BondRouteProtected/BondRouteProtected.sol";


/**
 * @title SafeSwapNftSigningDescriptor
 * @notice Immutable, stateless REFERENCE_2 signing-receipt renderer for SafeSwap NFT lifecycle calls.
 * @dev Reads the canonical PoolManager from ChainConfig and position identity from the caller-supplied NFT. SafeSwapNft
 *      stores this descriptor address as an immutable, so its BondRoute signing surface cannot be redirected after deploy.
 */
contract SafeSwapNftSigningDescriptor is ISafeSwapNftSigningDescriptor, PoolManagerIntegration {

    function build_signing_info( ISafeSwapNft safe_swap_nft, bytes calldata protected_call )
    external  view returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        if(  protected_call.length < 4  )  revert UnsupportedCall( );

        bytes4 selector  =  bytes4(protected_call);

        if(  selector == ISafeSwapNftActions.create_position.selector  )
        {
            CreatePositionParams memory params  =  abi.decode( protected_call[ 4: ], (CreatePositionParams) );
            return ModifyLiquidityLib.get_create_position_signing_info( params );
        }
        else if(  selector == ISafeSwapNftActions.add_liquidity.selector  )
        {
            AddPositionLiquidityParams memory params  =  abi.decode( protected_call[ 4: ], (AddPositionLiquidityParams) );
            SafeSwapPositionInfo memory position_info  =  safe_swap_nft.get_lp_position( params.token_id );
            return ModifyLiquidityLib.get_add_liquidity_signing_info( params, position_info, PoolManager );
        }
        else if(  selector == ISafeSwapNftActions.remove_liquidity.selector  )
        {
            RemovePositionLiquidityParams memory params  =  abi.decode( protected_call[ 4: ], (RemovePositionLiquidityParams) );
            return ModifyLiquidityLib.get_remove_liquidity_signing_info( params, safe_swap_nft.get_lp_position( params.token_id ) );
        }
        else if(  selector == ISafeSwapNftActions.collect_fees.selector  )
        {
            CollectFeesParams memory params  =  abi.decode( protected_call[ 4: ], (CollectFeesParams) );
            return ModifyLiquidityLib.get_collect_fees_signing_info( params, safe_swap_nft.get_lp_position( params.token_id ) );
        }
        else
        {
            revert UnsupportedCall( );
        }
    }
}

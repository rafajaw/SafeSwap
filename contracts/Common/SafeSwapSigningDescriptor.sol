// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { PoolManagerIntegration } from "@SafeSwapCommon/PoolManagerIntegration.sol";
import { SafeSwapPositionInfo } from "@SafeSwapCommon/Types.sol";
import { ISafeSwapNft } from "@SafeSwapNft/ISafeSwapNft.sol";
import {
    ISafeSwapNftActions,
    ISafeSwapRouterActions,
    ISafeSwapSigningDescriptor
} from "@SafeSwapCommon/ISafeSwapSigningDescriptor.sol";
import {
    AddPositionLiquidityParams,
    CollectFeesParams,
    CreatePositionParams,
    ModifyLiquidityLib,
    RemovePositionLiquidityParams
} from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";
import {
    ExactInputSwapLib,
    ExactInputSwapParams
} from "@SafeSwapRouter/libraries/ExactInputSwapLib.sol";
import {
    ExactOutputSwapLib,
    ExactOutputSwapParams
} from "@SafeSwapRouter/libraries/ExactOutputSwapLib.sol";
import { UnsupportedCall } from "@BondRouteProtected/BondRouteProtected.sol";
import { StringHelperLib } from "@SafeSwapNft/libraries/StringHelperLib.sol";


/**
 * @title SafeSwapSigningDescriptor
 * @notice Immutable, stateless REFERENCE_2 signing-receipt renderer shared by the SafeSwap router and NFT.
 * @dev Reads the canonical PoolManager from ChainConfig and position identity from the caller-supplied NFT. The router and
 *      NFT store this descriptor address as an immutable, so neither BondRoute signing surface can be redirected after deploy.
 */
contract SafeSwapSigningDescriptor is ISafeSwapSigningDescriptor, PoolManagerIntegration {

    // Fail-fast: native-token symbol / decimals feed the signed EIP-712 receipt, so require both keys at deploy, not lazily.
    constructor( )
    {
        StringHelperLib.validate_native_token_config( );
    }

    function build_router_signing_info( bytes calldata protected_call )
    external  view returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        if(  protected_call.length < 4  )  revert UnsupportedCall( );

        bytes4 call_selector  =  bytes4(protected_call);

        if(  call_selector == ISafeSwapRouterActions.swap_exact_input.selector  )
        {
            ExactInputSwapParams memory params  =  abi.decode( protected_call[ 4: ], (ExactInputSwapParams) );
            return ExactInputSwapLib.get_signing_info( params );
        }
        else if(  call_selector == ISafeSwapRouterActions.swap_exact_output.selector  )
        {
            ExactOutputSwapParams memory params  =  abi.decode( protected_call[ 4: ], (ExactOutputSwapParams) );
            return ExactOutputSwapLib.get_signing_info( params );
        }
        else
        {
            revert UnsupportedCall( );
        }
    }

    function build_nft_signing_info( ISafeSwapNft safe_swap_nft, bytes calldata protected_call )
    external  view returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )
    {
        if(  protected_call.length < 4  )  revert UnsupportedCall( );

        bytes4 call_selector  =  bytes4(protected_call);

        if(  call_selector == ISafeSwapNftActions.create_position.selector  )
        {
            CreatePositionParams memory params  =  abi.decode( protected_call[ 4: ], (CreatePositionParams) );
            return ModifyLiquidityLib.get_create_position_signing_info( params );
        }
        else if(  call_selector == ISafeSwapNftActions.add_liquidity.selector  )
        {
            AddPositionLiquidityParams memory params  =  abi.decode( protected_call[ 4: ], (AddPositionLiquidityParams) );
            SafeSwapPositionInfo memory position_info  =  safe_swap_nft.get_lp_position( params.token_id );
            return ModifyLiquidityLib.get_add_liquidity_signing_info( params, position_info );
        }
        else if(  call_selector == ISafeSwapNftActions.remove_liquidity.selector  )
        {
            RemovePositionLiquidityParams memory params  =  abi.decode( protected_call[ 4: ], (RemovePositionLiquidityParams) );
            return ModifyLiquidityLib.get_remove_liquidity_signing_info( params, safe_swap_nft.get_lp_position( params.token_id ) );
        }
        else if(  call_selector == ISafeSwapNftActions.collect_fees.selector  )
        {
            CollectFeesParams memory params  =  abi.decode( protected_call[ 4: ], (CollectFeesParams) );
            return ModifyLiquidityLib.get_collect_fees_signing_info( params, safe_swap_nft.get_lp_position( params.token_id ) );
        }
        else
        {
            revert UnsupportedCall( );
        }
    }

    function build_router_signing_values( bytes calldata protected_call )
    external  view returns ( string[] memory display_values, address[] memory token_addresses )
    {
        if(  protected_call.length < 4  )  revert UnsupportedCall( );

        bytes4 call_selector  =  bytes4(protected_call);

        if(  call_selector == ISafeSwapRouterActions.swap_exact_input.selector  )
        {
            return ExactInputSwapLib.get_signing_values( abi.decode( protected_call[ 4: ], (ExactInputSwapParams) ) );
        }
        else if(  call_selector == ISafeSwapRouterActions.swap_exact_output.selector  )
        {
            return ExactOutputSwapLib.get_signing_values( abi.decode( protected_call[ 4: ], (ExactOutputSwapParams) ) );
        }
        else
        {
            revert UnsupportedCall( );
        }
    }

    function build_nft_signing_values( ISafeSwapNft safe_swap_nft, bytes calldata protected_call )
    external  view returns ( string[] memory display_values, address[] memory token_addresses )
    {
        if(  protected_call.length < 4  )  revert UnsupportedCall( );

        bytes4 call_selector  =  bytes4(protected_call);

        if(  call_selector == ISafeSwapNftActions.create_position.selector  )
        {
            return ModifyLiquidityLib.get_create_position_signing_values( abi.decode( protected_call[ 4: ], (CreatePositionParams) ) );
        }
        else if(  call_selector == ISafeSwapNftActions.add_liquidity.selector  )
        {
            AddPositionLiquidityParams memory params  =  abi.decode( protected_call[ 4: ], (AddPositionLiquidityParams) );
            return ModifyLiquidityLib.get_add_liquidity_signing_values( params, safe_swap_nft.get_lp_position( params.token_id ) );
        }
        else if(  call_selector == ISafeSwapNftActions.remove_liquidity.selector  )
        {
            RemovePositionLiquidityParams memory params  =  abi.decode( protected_call[ 4: ], (RemovePositionLiquidityParams) );
            return ModifyLiquidityLib.get_remove_liquidity_signing_values( params, safe_swap_nft.get_lp_position( params.token_id ) );
        }
        else if(  call_selector == ISafeSwapNftActions.collect_fees.selector  )
        {
            CollectFeesParams memory params  =  abi.decode( protected_call[ 4: ], (CollectFeesParams) );
            return ModifyLiquidityLib.get_collect_fees_signing_values( params, safe_swap_nft.get_lp_position( params.token_id ) );
        }
        else
        {
            revert UnsupportedCall( );
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ISafeSwapNft } from "@SafeSwapNft/ISafeSwapNft.sol";
import {
    AddPositionLiquidityParams,
    CollectFeesParams,
    CreatePositionParams,
    RemovePositionLiquidityParams
} from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";
import { ExactInputSwapParams } from "@SafeSwapRouter/libraries/ExactInputSwapLib.sol";
import { ExactOutputSwapParams } from "@SafeSwapRouter/libraries/ExactOutputSwapLib.sol";


/**
 * @notice Selector-only surface for the four BondRoute-protected NFT lifecycle actions.
 */
interface ISafeSwapNftActions {
    function create_position( CreatePositionParams calldata params )
    external;

    function add_liquidity( AddPositionLiquidityParams calldata params )
    external;

    function remove_liquidity( RemovePositionLiquidityParams calldata params )
    external;

    function collect_fees( CollectFeesParams calldata params )
    external;
}


/**
 * @notice Selector-only surface for the two BondRoute-protected router swap actions.
 */
interface ISafeSwapRouterActions {
    function swap_exact_input( ExactInputSwapParams calldata params )
    external;

    function swap_exact_output( ExactOutputSwapParams calldata params )
    external;
}


/**
 * @title ISafeSwapSigningDescriptor
 * @notice External REFERENCE_2 receipt renderer shared by the SafeSwap router and NFT.
 */
interface ISafeSwapSigningDescriptor {
    function build_router_signing_info( bytes calldata protected_call )
    external  view returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset );

    function build_nft_signing_info( ISafeSwapNft safe_swap_nft, bytes calldata protected_call )
    external  view returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset );
}

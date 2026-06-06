// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ISafeSwapNft } from "@SafeSwapNft/ISafeSwapNft.sol";
import {
    AddPositionLiquidityParams,
    CollectFeesParams,
    CreatePositionParams,
    RemovePositionLiquidityParams
} from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";


/**
 * @notice Selector-only surface for the four BondRoute-protected NFT lifecycle actions.
 */
interface ISafeSwapNftActions {
    function create_position( CreatePositionParams calldata params ) external;
    function add_liquidity( AddPositionLiquidityParams calldata params ) external;
    function remove_liquidity( RemovePositionLiquidityParams calldata params ) external;
    function collect_fees( CollectFeesParams calldata params ) external;
}


/**
 * @title ISafeSwapNftSigningDescriptor
 * @notice External REFERENCE_2 receipt renderer for SafeSwap NFT lifecycle calls. The size-bound NFT forwards its
 *         `BondRoute_get_signing_info` surface here so dynamic string rendering and price/liquidity math are not embedded
 *         in the NFT runtime.
 */
interface ISafeSwapNftSigningDescriptor {
    function build_signing_info( ISafeSwapNft safe_swap_nft, bytes calldata protected_call )
    external  view returns ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset );
}

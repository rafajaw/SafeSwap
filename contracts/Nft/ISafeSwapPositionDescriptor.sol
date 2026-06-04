// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ISafeSwapNft } from "@SafeSwapNft/ISafeSwapNft.sol";


/**
 * @title ISafeSwapPositionDescriptor
 * @notice External renderer for SafeSwap LP NFT metadata. `SafeSwapNft` is the EIP-170 size-bound contract, so all on-chain
 *         art and JSON assembly lives here; the NFT only forwards `tokenURI` / `contractURI` to this descriptor.
 */
interface ISafeSwapPositionDescriptor {

    /**
     * @notice Build a position's ERC721 metadata as a `data:application/json;base64,...` URI whose `image` is a fully
     *         on-chain `data:image/svg+xml;base64,...` card. Reads the position from `nft` and its live state from the V4
     *         PoolManager.
     */
    function build_token_uri( ISafeSwapNft nft, uint256 token_id ) external view returns ( string memory );

    /**
     * @notice Build collection-level metadata as a `data:application/json;base64,...` URI (OpenSea `contractURI`).
     */
    function build_contract_uri( ) external view returns ( string memory );
}

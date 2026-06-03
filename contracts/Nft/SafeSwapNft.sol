// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@SafeSwapNft/ISafeSwapNft.sol";
import { CONFIG_SIGNER, SAFESWAP_HOOK_KEY } from "@SafeSwap/Definitions.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { ERC721 } from "@OpenZeppelin/token/ERC721/ERC721.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error OnlySafeSwapHook( address caller, address expected_hook );


/**
 * @title SafeSwapNft
 * @notice ERC721 ownership layer for SafeSwap LP positions.
 */
contract SafeSwapNft is ERC721, ISafeSwapNft {

    address public immutable SafeSwapHook;

    uint256 private _next_token_id;

    mapping( uint256 => SafeSwapPositionInfo ) private _position_infos;

    constructor( )
    ERC721( "SafeSwap LP Positions", "SSWAP-LP" )
    {
        address safeswap_hook  =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_HOOK_KEY );
        if(  safeswap_hook == address(0)  )  revert( "SafeSwapNft: Invalid safeswap_hook" );

        SafeSwapHook    =  safeswap_hook;
        _next_token_id  =  1;
    }


    // ━━━━  POSITION MINTING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Mint an LP position NFT. Only callable by the configured SafeSwap hook.
     * @param owner User receiving the LP NFT.
     * @param position_info Immutable metadata for the SafeSwap-managed V4 position.
     * @return token_id Minted LP NFT id.
     */
    function mint_position( address owner, SafeSwapPositionInfo calldata position_info )
    external returns ( uint256 token_id )
    {
        if(  msg.sender != SafeSwapHook  )  revert OnlySafeSwapHook({ caller: msg.sender, expected_hook: SafeSwapHook });

        token_id        =  _next_token_id;
        _next_token_id  =  _next_token_id + 1;

        _position_infos[ token_id ]  =  position_info;

        _mint( owner, token_id );
    }


    // ━━━━  POSITION GETTERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @notice Read immutable metadata for an NFT-backed SafeSwap LP position.
     * @param token_id SafeSwap LP NFT id.
     * @return position_info Stored position metadata.
     */
    function get_lp_position( uint256 token_id )
    external  view returns ( SafeSwapPositionInfo memory position_info )
    {
        _requireOwned( token_id );

        position_info  =  _position_infos[ token_id ];
    }
}

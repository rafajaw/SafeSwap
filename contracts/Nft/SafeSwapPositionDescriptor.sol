// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*

        ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
        ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
        ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
        ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
        ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
        ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
        ━━━━━━━━━━━━━━  SafeSwap LP position metadata renderer  ━━━━━━━━━━━

*/

import { ISafeSwapPositionDescriptor } from "@SafeSwapNft/ISafeSwapPositionDescriptor.sol";
import { ISafeSwapNft } from "@SafeSwapNft/ISafeSwapNft.sol";
import { SafeSwapPositionInfo } from "@SafeSwapCommon/Types.sol";
import { SafeSwapCommon } from "@SafeSwapCommon/SafeSwapCommon.sol";
import {
    CONFIG_SIGNER,
    POOL_MANAGER_KEY,
    SAFESWAP_POSITIONS_NAME,
    SAFESWAP_POSITIONS_DESCRIPTION
} from "@SafeSwapCommon/Definitions.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { IERC20 } from "@BondRouteProtected/BondRouteProtected.sol";
import { IERC20Metadata } from "@OpenZeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import { Base64 } from "@OpenZeppelin/utils/Base64.sol";
import { Strings } from "@OpenZeppelin/utils/Strings.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";

using StateLibrary for IPoolManager;
using PoolIdLibrary for PoolKey;


/**
 * @title SafeSwapPositionDescriptor
 * @notice Renders SafeSwap LP NFT metadata fully on-chain: `tokenURI` returns a base64 `application/json` data URI whose
 *         `image` is a base64 `image/svg+xml` card. Stateless except for the immutable V4 PoolManager it reads live position
 *         state from. Deployed once and referenced by `SafeSwapNft` (the EIP-170 size-bound contract that only forwards here).
 */
contract SafeSwapPositionDescriptor is ISafeSwapPositionDescriptor {

    uint256 internal constant MAX_SYMBOL_LENGTH  =  12;

    IPoolManager public immutable PoolManager;

    // Everything needed to render a position, gathered once to keep the render helpers off the stack.
    struct PositionView {
        string  symbol0;
        string  symbol1;
        string  base_fee_percent;
        uint8   rebate_percent;
        int24   tick_lower;
        int24   tick_upper;
        uint128 liquidity;
        bool    initialized;
        bool    in_range;
        uint256 token_id;
    }

    constructor( )
    {
        address pool_manager  =  ChainConfig.read_address( CONFIG_SIGNER, POOL_MANAGER_KEY );
        if(  pool_manager.code.length == 0  )  revert( "SafeSwapDescriptor: Invalid pool_manager" );

        PoolManager  =  IPoolManager(pool_manager);
    }


    // ━━━━  METADATA  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function build_token_uri( ISafeSwapNft nft, uint256 token_id )
    external  view returns ( string memory )
    {
        PositionView memory position  =  _load_position( nft, token_id );

        string memory image  =  string.concat( "data:image/svg+xml;base64,", Base64.encode( bytes(_render_svg( position )) ) );

        bytes memory json  =  abi.encodePacked(
            '{"name":"', SAFESWAP_POSITIONS_NAME, ' #', Strings.toString( token_id ), ' ', position.symbol0, '/', position.symbol1, '",',
            '"description":"', SAFESWAP_POSITIONS_DESCRIPTION, '",',
            '"image":"', image, '",',
            '"attributes":', _render_attributes( position ),
            '}'
        );

        return string.concat( "data:application/json;base64,", Base64.encode( json ) );
    }

    function build_contract_uri( )
    external  pure returns ( string memory )
    {
        bytes memory json  =  abi.encodePacked(
            '{"name":"', SAFESWAP_POSITIONS_NAME, '",',
            '"description":"', SAFESWAP_POSITIONS_DESCRIPTION, '"}'
        );

        return string.concat( "data:application/json;base64,", Base64.encode( json ) );
    }


    // ━━━━  STATE LOADING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _load_position( ISafeSwapNft nft, uint256 token_id )
    internal view returns ( PositionView memory position )
    {
        SafeSwapPositionInfo memory info  =  nft.get_lp_position( token_id );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( info.token0, info.token1, LPFeeLibrary.DYNAMIC_FEE_FLAG, info.tick_spacing, info.hook );
        PoolId pool_id           =  pool_key.toId( );

        ( uint160 sqrt_price_x96, int24 current_tick, , )  =  PoolManager.getSlot0( pool_id );
        ( uint128 liquidity, , )                           =  PoolManager.getPositionInfo( pool_id, address(nft), info.tick_lower, info.tick_upper, bytes32(token_id) );

        position.symbol0           =  _token_symbol( info.token0 );
        position.symbol1           =  _token_symbol( info.token1 );
        position.base_fee_percent  =  _format_bps_as_percent( info.base_fee_bps );
        position.rebate_percent    =  info.rebate_percent;
        position.tick_lower        =  info.tick_lower;
        position.tick_upper        =  info.tick_upper;
        position.liquidity         =  liquidity;
        position.initialized       =  sqrt_price_x96 != 0;
        position.in_range          =  sqrt_price_x96 != 0  &&  current_tick >= info.tick_lower  &&  current_tick < info.tick_upper;
        position.token_id          =  token_id;
    }


    // ━━━━  SVG  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _render_svg( PositionView memory position )
    internal pure returns ( string memory )
    {
        return string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' width='300' height='400' viewBox='0 0 300 400'>",
            "<defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'>",
            "<stop offset='0' stop-color='#0f2027'/><stop offset='0.55' stop-color='#203a43'/><stop offset='1' stop-color='#2c5364'/>",
            "</linearGradient></defs>",
            "<rect width='300' height='400' rx='20' fill='url(#g)'/>",
            "<text x='24' y='52' fill='#ffffff' font-family='monospace' font-size='24' font-weight='bold'>SafeSwap LP</text>",
            "<text x='24' y='84' fill='#8fd3ff' font-family='monospace' font-size='18'>", position.symbol0, " / ", position.symbol1, "</text>",
            _render_svg_rows( position ),
            "<text x='24' y='372' fill='#5a7a8a' font-family='monospace' font-size='13'>#", Strings.toString( position.token_id ), "</text>",
            "</svg>"
        );
    }

    function _render_svg_rows( PositionView memory position )
    internal pure returns ( string memory )
    {
        return string.concat(
            "<text x='24' y='150' fill='#cfe8ff' font-family='monospace' font-size='14'>Base fee: ", position.base_fee_percent, "%</text>",
            "<text x='24' y='178' fill='#cfe8ff' font-family='monospace' font-size='14'>LP rebate: ", Strings.toString( position.rebate_percent ), "%</text>",
            "<text x='24' y='206' fill='#cfe8ff' font-family='monospace' font-size='14'>Ticks: ", Strings.toStringSigned( position.tick_lower ), " to ", Strings.toStringSigned( position.tick_upper ), "</text>",
            "<text x='24' y='234' fill='", position.in_range ? "#7CFFB2" : "#FF9F9F", "' font-family='monospace' font-size='14'>", _status_label( position ), "</text>"
        );
    }


    // ━━━━  ATTRIBUTES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _render_attributes( PositionView memory position )
    internal pure returns ( string memory )
    {
        return string.concat(
            "[",
            _attribute( "Token 0", position.symbol0 ), ",",
            _attribute( "Token 1", position.symbol1 ), ",",
            _attribute( "Base Fee", string.concat( position.base_fee_percent, "%" ) ), ",",
            _attribute( "LP Rebate", string.concat( Strings.toString( position.rebate_percent ), "%" ) ), ",",
            _attribute( "Tick Lower", Strings.toStringSigned( position.tick_lower ) ), ",",
            _attribute( "Tick Upper", Strings.toStringSigned( position.tick_upper ) ), ",",
            _attribute( "Liquidity", Strings.toString( position.liquidity ) ), ",",
            _attribute( "Status", _status_label( position ) ),
            "]"
        );
    }

    function _attribute( string memory trait, string memory value )
    internal pure returns ( string memory )
    {
        return string.concat( '{"trait_type":"', trait, '","value":"', value, '"}' );
    }

    function _status_label( PositionView memory position )
    internal pure returns ( string memory )
    {
        if(  position.initialized == false  )  return "Uninitialized";

        return position.in_range  ?  "In Range"  :  "Out of Range";
    }


    // ━━━━  FORMATTING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // Basis points to a percent string with two decimals: 30 -> "0.30", 5 -> "0.05", 999 -> "9.99".
    function _format_bps_as_percent( uint16 base_fee_bps )
    internal pure returns ( string memory )
    {
        uint256 whole       =  uint256(base_fee_bps) / 100;
        uint256 fractional  =  uint256(base_fee_bps) % 100;
        string memory pad   =  fractional < 10  ?  "0"  :  "";

        return string.concat( Strings.toString( whole ), ".", pad, Strings.toString( fractional ) );
    }

    // Safe token symbol for embedding in JSON and SVG: native ETH is labelled directly; a non-conforming `symbol()`
    // (missing, reverting, or non-string) falls back to the short address; the result is filtered to an alphanumeric
    // subset so it can never break out of the surrounding XML/JSON or exceed a sane length.
    function _token_symbol( IERC20 token )
    internal view returns ( string memory )
    {
        if(  address(token) == address(0)  )  return "ETH";

        try IERC20Metadata( address(token) ).symbol( ) returns ( string memory symbol )
        {
            return _sanitize( symbol );
        }
        catch
        {
            return _sanitize( Strings.toHexString( address(token) ) );
        }
    }

    // Keep only [0-9A-Za-z], '.', '-' and cap the length. Drops quotes, angle brackets, backslashes, control bytes — so a
    // hostile token symbol cannot inject markup into the SVG or escape the JSON string.
    function _sanitize( string memory input )
    internal pure returns ( string memory )
    {
        bytes memory raw    =  bytes(input);
        uint256 limit       =  raw.length < MAX_SYMBOL_LENGTH  ?  raw.length  :  MAX_SYMBOL_LENGTH;
        bytes memory clean  =  new bytes( limit );
        uint256 count       =  0;

        for(  uint256 i = 0  ;  i < limit  ;  i = i + 1  )
        {
            bytes1 c  =  raw[ i ];

            bool is_allowed  =  ( c >= 0x30 && c <= 0x39 )       // 0-9
                                ||  ( c >= 0x41 && c <= 0x5A )   // A-Z
                                ||  ( c >= 0x61 && c <= 0x7A )   // a-z
                                ||  c == 0x2E                    // .
                                ||  c == 0x2D;                   // -

            if(  is_allowed  )
            {
                clean[ count ]  =  c;
                count           =  count + 1;
            }
        }

        if(  count == 0  )  return "TOKEN";

        assembly { mstore( clean, count ) }    // Truncate to the kept bytes.

        return string(clean);
    }
}

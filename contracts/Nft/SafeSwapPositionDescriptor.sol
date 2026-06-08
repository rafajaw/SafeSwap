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
import { StringHelperLib } from "@SafeSwapNft/libraries/StringHelperLib.sol";
import { PriceLib } from "@SafeSwapNft/libraries/PriceLib.sol";
import { SafeSwapPositionInfo } from "@SafeSwapCommon/Types.sol";
import { SafeSwapCommon } from "@SafeSwapCommon/SafeSwapCommon.sol";
import {
    CONFIG_SIGNER,
    POOL_MANAGER_KEY,
    SAFESWAP_POSITIONS_NAME,
    SAFESWAP_POSITIONS_DESCRIPTION
} from "@SafeSwapCommon/Definitions.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { Base64 } from "@OpenZeppelin/utils/Base64.sol";
import { LibString } from "@Solady/utils/LibString.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";
import { FullMath } from "@UniswapV4Core/libraries/FullMath.sol";
import { FixedPoint128 } from "@UniswapV4Core/libraries/FixedPoint128.sol";
import { FixedPoint96 } from "@UniswapV4Core/libraries/FixedPoint96.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { SqrtPriceMath } from "@UniswapV4Core/libraries/SqrtPriceMath.sol";

using StateLibrary for IPoolManager;
using PoolIdLibrary for PoolKey;


/**
 * @title SafeSwapPositionDescriptor
 * @notice Renders SafeSwap LP NFT metadata fully on-chain: `tokenURI` returns a base64 `application/json` data URI whose
 *         `image` is a base64 `image/svg+xml` card. Stateless except for the immutable V4 PoolManager it reads live position
 *         state from. Deployed once and referenced by `SafeSwapNft` (the EIP-170 size-bound contract that only forwards here).
 */
contract SafeSwapPositionDescriptor is ISafeSwapPositionDescriptor {

    IPoolManager public immutable PoolManager;

    /// @notice Fractional-digit cap for token amounts shown on the cosmetic position card. The card is
    ///         display-only, so a 4-decimal cap keeps it readable. This rendering is intentionally LOSSY and
    ///         must never back a signed commitment — signing paths render with `StringHelperLib.FULL_PRECISION`.
    uint8 internal constant DISPLAY_AMOUNTS_MAX_DECIMALS  =  4;

    struct PositionIdentity {
        uint256 token_id;
        address nft_contract;
        address hook;
        int24   tick_spacing;
        bytes32 pool_id;
    }

    struct PriceView {
        uint256 current;
        uint256 lower;
        uint256 upper;
        uint256 fill;
    }

    struct TokenView {
        string symbol0;
        string symbol1;
        uint8  decimals0;
        uint8  decimals1;
    }

    struct PositionConfigView {
        string  base_fee_percent;
        uint8   rebate_percent;
        int24   tick_lower;
        int24   tick_upper;
        uint128 liquidity;
        uint40  opened_at;
        bool    initialized;
        bool    in_range;
    }

    struct AmountView {
        uint256 position0;
        uint256 position1;
        uint256 claimable0;
        uint256 claimable1;
        uint256 earned0;
        uint256 earned1;
    }

    struct YieldView {
        uint256 lifetime_bps;
        uint256 annualized_bps;
    }

    // Everything needed to render a position, gathered once to keep the render helpers off the stack.
    struct PositionView {
        TokenView tokens;
        PositionConfigView config;
        PriceView prices;
        AmountView amounts;
        YieldView yield;
        PositionIdentity identity;
    }

    constructor( )
    {
        address pool_manager  =  ChainConfig.read_address( CONFIG_SIGNER, POOL_MANAGER_KEY );
        if(  pool_manager.code.length == 0  )  revert( "SafeSwapDescriptor: Invalid pool_manager" );

        // Fail-fast: the native-token display keys are read lazily at render, but require them at deploy so a chain can never
        // ship a descriptor without its native symbol / decimals set.
        StringHelperLib.validate_native_token_config( );

        PoolManager  =  IPoolManager(pool_manager);
    }


    // ━━━━  METADATA  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function build_token_uri( ISafeSwapNft nft, uint256 token_id )
    external  view returns ( string memory )
    {
        PositionView memory position  =  _load_position( nft, token_id );

        string memory image  =  string.concat( "data:image/svg+xml;base64,", Base64.encode( bytes(_render_svg( position )) ) );

        string memory json  =  string.concat(
            '{"name":"', SAFESWAP_POSITIONS_NAME, ' #', _token_id_hex( token_id ), ' ', position.tokens.symbol0, '/', position.tokens.symbol1, '",',
            '"description":"', SAFESWAP_POSITIONS_DESCRIPTION, '",',
            '"image":"', image, '",',
            '"attributes":', _render_attributes( position ),
            '}'
        );

        return string.concat( "data:application/json;base64,", Base64.encode( bytes(json) ) );
    }

    function build_contract_uri( )
    external  pure returns ( string memory )
    {
        string memory json  =  string.concat(
            '{"name":"', SAFESWAP_POSITIONS_NAME, '",',
            '"description":"', SAFESWAP_POSITIONS_DESCRIPTION, '"}'
        );

        return string.concat( "data:application/json;base64,", Base64.encode( bytes(json) ) );
    }


    // ━━━━  STATE LOADING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _load_position( ISafeSwapNft nft, uint256 token_id ) internal view returns ( PositionView memory position )
    {
        SafeSwapPositionInfo memory info  =  nft.get_lp_position( token_id );
        PoolId pool_id                    =  _pool_id( info );

        ( uint160 sqrt_price_x96, int24 current_tick, , )  =  PoolManager.getSlot0( pool_id );
        uint8 decimals0  =  StringHelperLib.get_token_decimals( info.token0 );
        uint8 decimals1  =  StringHelperLib.get_token_decimals( info.token1 );

        ( AmountView memory amounts, uint128 liquidity )  =  _load_amounts( nft, token_id, info, pool_id, sqrt_price_x96 );

        position.tokens            =  TokenView({
            symbol0:   StringHelperLib.get_sanitized_token_symbol( info.token0 ),
            symbol1:   StringHelperLib.get_sanitized_token_symbol( info.token1 ),
            decimals0: decimals0,
            decimals1: decimals1
        });
        position.config            =  _load_config( info, sqrt_price_x96, current_tick, liquidity );
        position.prices            =  _load_prices( sqrt_price_x96, info, decimals0, decimals1 );
        position.amounts           =  amounts;
        position.yield             =  _load_yield( sqrt_price_x96, amounts, info );
        position.identity          =  PositionIdentity({
            token_id:      token_id,
            nft_contract:  address(nft),
            hook:          info.hook,
            tick_spacing:  info.tick_spacing,
            pool_id:       PoolId.unwrap( pool_id )
        });
    }

    function _pool_id( SafeSwapPositionInfo memory info ) internal pure returns ( PoolId )
    {
        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( info.token0, info.token1, LPFeeLibrary.DYNAMIC_FEE_FLAG, info.tick_spacing, info.hook );
        return pool_key.toId( );
    }

    function _load_config( SafeSwapPositionInfo memory info, uint160 sqrt_price_x96, int24 current_tick, uint128 liquidity )
    internal pure returns ( PositionConfigView memory config )
    {
        config  =  PositionConfigView({
            base_fee_percent: StringHelperLib.format_bps_as_percent( info.base_fee_bps ),
            rebate_percent:   info.rebate_percent,
            tick_lower:       info.tick_lower,
            tick_upper:       info.tick_upper,
            liquidity:        liquidity,
            opened_at:        info.opened_at,
            initialized:      sqrt_price_x96 != 0,
            in_range:         sqrt_price_x96 != 0  &&  current_tick >= info.tick_lower  &&  current_tick < info.tick_upper
        });
    }

    function _load_prices( uint160 sqrt_price_x96, SafeSwapPositionInfo memory info, uint8 decimals0, uint8 decimals1 )
    internal pure returns ( PriceView memory prices )
    {
        uint256 current_price  =  PriceLib.price1_per_0_scaled( sqrt_price_x96, decimals0, decimals1 );
        uint256 lower_price    =  PriceLib.price_at_tick_scaled( info.tick_lower, decimals0, decimals1 );
        uint256 upper_price    =  PriceLib.price_at_tick_scaled( info.tick_upper, decimals0, decimals1 );

        prices  =  PriceView({
            current: current_price,
            lower:   lower_price,
            upper:   upper_price,
            fill:    PriceLib.fill_width( current_price, lower_price, upper_price, 85 )
        });
    }

    function _load_amounts(
        ISafeSwapNft nft,
        uint256 token_id,
        SafeSwapPositionInfo memory info,
        PoolId pool_id,
        uint160 sqrt_price_x96
    ) internal view returns ( AmountView memory amounts, uint128 liquidity )
    {
        uint256 fee_growth_0_last;
        uint256 fee_growth_1_last;
        ( liquidity, fee_growth_0_last, fee_growth_1_last )  =  _position_state( nft, token_id, info, pool_id );
        ( uint256 checkpointed_earned0, uint256 checkpointed_earned1 )  =  nft.get_lp_fee_totals( token_id );
        ( uint256 claimable0, uint256 claimable1 )  =  _claimable_fees( pool_id, info, liquidity, fee_growth_0_last, fee_growth_1_last );
        ( uint256 position0, uint256 position1 )    =  _position_amounts( sqrt_price_x96, info.tick_lower, info.tick_upper, liquidity );

        amounts  =  AmountView({
            position0:  position0,
            position1:  position1,
            claimable0: claimable0,
            claimable1: claimable1,
            earned0:    checkpointed_earned0 + claimable0,
            earned1:    checkpointed_earned1 + claimable1
        });
    }

    function _position_state( ISafeSwapNft nft, uint256 token_id, SafeSwapPositionInfo memory info, PoolId pool_id )
    internal view returns ( uint128 liquidity, uint256 fee_growth_0_last, uint256 fee_growth_1_last )
    {
        ( liquidity, fee_growth_0_last, fee_growth_1_last )  =  PoolManager.getPositionInfo( pool_id, address(nft), info.tick_lower, info.tick_upper, bytes32(token_id) );
    }

    function _load_yield( uint160 sqrt_price_x96, AmountView memory amounts, SafeSwapPositionInfo memory info )
    internal view returns ( YieldView memory fee_yield )
    {
        ( uint256 lifetime_bps, uint256 annualized_bps )  =
            _yield_current_basis( sqrt_price_x96, amounts.position0, amounts.position1, info, amounts.earned0, amounts.earned1 );

        fee_yield  =  YieldView({ lifetime_bps: lifetime_bps, annualized_bps: annualized_bps });
    }


    // ━━━━  SVG  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _render_svg( PositionView memory position ) internal view returns ( string memory )
    {
        return string.concat(
            _render_svg_definitions( ),
            _render_svg_frame( position ),
            _render_svg_rows( position ),
            "</svg>"
        );
    }

    function _render_svg_definitions( ) internal pure returns ( string memory )
    {
        return string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' width='350' height='480' viewBox='0 0 350 480'>",
            "<defs>",
            "<linearGradient id='bg' x1='0' y1='0' x2='1' y2='1'>",
            "<stop offset='0' stop-color='#276f61'/><stop offset='.46' stop-color='#13233a'/><stop offset='1' stop-color='#584a34'/>",
            "</linearGradient>",
            "<radialGradient id='glow' cx='18%' cy='6%' r='72%'>",
            "<stop offset='0' stop-color='#37d6a3' stop-opacity='.42'/><stop offset='1' stop-color='#37d6a3' stop-opacity='0'/>",
            "</radialGradient>",
            "<style>",
            ".t{font-family:Arial,sans-serif}.m{font-family:monospace}.w{fill:#fff}",
            ".w9{fill:#fff;fill-opacity:.9}.w6{fill:#fff;fill-opacity:.6}.w5{fill:#fff;fill-opacity:.5}.w4{fill:#fff;fill-opacity:.4}",
            ".g{fill:#37d6a3}.n{fill:#b7c0cf}.gs{fill:#37d6a3;fill-opacity:.6}",
            ".val{font-weight:700}.lbl{font-weight:600;letter-spacing:0}.rule{stroke:#fff;stroke-opacity:.1}",
            "</style>",
            "</defs>"
        );
    }

    function _render_svg_frame( PositionView memory position ) internal pure returns ( string memory )
    {
        return string.concat(
            "<rect width='350' height='480' rx='24' fill='url(#bg)'/>",
            "<rect width='350' height='480' rx='24' fill='url(#glow)'/>",
            "<rect x='.5' y='.5' width='349' height='479' rx='23.5' fill='none' stroke='#fff' stroke-opacity='.1'/>",
            "<text x='24' y='43' class='m w9 val' font-size='15'>", _token_id_hex( position.identity.token_id ), "</text>",
            "<text x='326' y='43' text-anchor='end' class='t' font-size='13' font-weight='700'><tspan class='w9'>Safe</tspan><tspan class='g'>Swap</tspan></text>",
            "<line x1='24' y1='58' x2='326' y2='58' class='rule'/>"
        );
    }

    function _render_svg_rows( PositionView memory position ) internal view returns ( string memory )
    {
        return string.concat(
            _render_hero( position ),
            _render_fee_grid( position ),
            _render_yield_line( position ),
            _render_stats_band( position ),
            _render_market_row( position ),
            "<text x='175' y='468' text-anchor='middle' class='m w5' font-size='9'>as of ", StringHelperLib.format_utc_datetime( block.timestamp ), "</text>"
        );
    }

    function _render_hero( PositionView memory position ) internal pure returns ( string memory )
    {
        string memory position0  =  _display_amount( position.amounts.position0, position.tokens.decimals0 );
        string memory position1  =  _display_amount( position.amounts.position1, position.tokens.decimals1 );

        return string.concat(
            "<text x='175' y='88' text-anchor='middle' class='t w4 lbl' font-size='11'>CURRENT POSITION</text>",
            "<text x='90' y='126' text-anchor='middle' class='t w val' font-size='24'>", position.tokens.symbol0, "</text>",
            "<text x='90' y='155' text-anchor='middle' class='m w6' font-size='19'>", position0, "</text>",
            "<text x='260' y='126' text-anchor='middle' class='t w val' font-size='24'>", position.tokens.symbol1, "</text>",
            "<text x='260' y='155' text-anchor='middle' class='m w6' font-size='19'>", position1, "</text>",
            "<line x1='24' y1='184' x2='326' y2='184' class='rule'/>"
        );
    }

    function _render_market_row( PositionView memory position ) internal pure returns ( string memory )
    {
        string memory marker_color  =  position.config.in_range  ?  "#37d6a3"  :  "#b7c0cf";
        string memory marker_class  =  position.config.in_range  ?  "g"  :  "n";
        string memory price_fill    =  LibString.toString( position.prices.fill );
        string memory price_marker  =  LibString.toString( 201 + position.prices.fill );

        return string.concat(
            _render_market_labels( position, marker_color, marker_class ),
            _render_market_bar( position, marker_color, price_fill, price_marker )
        );
    }

    function _render_market_labels( PositionView memory position, string memory marker_color, string memory marker_class ) internal pure returns ( string memory )
    {
        string memory badge_x     =  position.config.in_range  ?  "40"  :  "33";
        string memory badge_width =  position.config.in_range  ?  "104" :  "118";
        string memory dot_x       =  position.config.in_range  ?  "62"  :  "51";
        string memory text_x      =  position.config.in_range  ?  "98"  :  "99";

        return string.concat(
            "<text x='326' y='404' text-anchor='end' class='t w4 lbl' font-size='9'>", position.tokens.symbol1, " / ", position.tokens.symbol0, "</text>",
            "<text x='244' y='417' text-anchor='middle' class='m ", marker_class, "' font-size='12'>", StringHelperLib.format_price( position.prices.current ), "</text>",
            "<rect x='", badge_x, "' y='402' width='", badge_width, "' height='30' rx='15' fill='#000' fill-opacity='.14'/>",
            "<circle cx='", dot_x, "' cy='417' r='3.5' fill='", marker_color, "'/>",
            "<text x='", text_x, "' y='421' text-anchor='middle' class='t ", marker_class, "' font-size='12' font-weight='600'>", _status_label( position ), "</text>",
            "<text x='193' y='431' text-anchor='end' class='m w5' font-size='10'>", StringHelperLib.format_price( position.prices.lower ), "</text>"
        );
    }

    function _render_market_bar(
        PositionView memory position,
        string memory marker_color,
        string memory price_fill,
        string memory price_marker
    ) internal pure returns ( string memory )
    {
        return string.concat(
            "<rect x='201' y='426.5' width='85' height='3' rx='1.5' fill='#fff' fill-opacity='.08'/>",
            "<rect x='201' y='426.5' width='", price_fill, "' height='3' rx='1.5' fill='#fff' fill-opacity='.16'/>",
            "<circle cx='", price_marker, "' cy='428' r='2.5' fill='", marker_color, "' fill-opacity='.9'/>",
            "<text x='294' y='431' text-anchor='start' class='m w5' font-size='10'>", StringHelperLib.format_price( position.prices.upper ), "</text>"
        );
    }

    function _render_stats_band( PositionView memory position ) internal view returns ( string memory )
    {
        return string.concat(
            "<rect x='0' y='338' width='350' height='42' fill='#fff' fill-opacity='.05'/>",
            "<line x1='0' y1='338' x2='350' y2='338' class='rule'/>",
            "<line x1='117' y1='348' x2='117' y2='370' class='rule' stroke-opacity='.12'/>",
            "<line x1='233' y1='348' x2='233' y2='370' class='rule' stroke-opacity='.12'/>",
            "<text x='58' y='363' text-anchor='middle' class='t' font-size='12'><tspan class='w4 lbl' font-size='10'>FEE</tspan><tspan class='m w9 val' dx='5'>",
            position.config.base_fee_percent, "%</tspan></text>",
            "<text x='175' y='363' text-anchor='middle' class='t' font-size='12'><tspan class='w4 lbl' font-size='10'>REBATE</tspan><tspan class='m w9 val' dx='5'>",
            LibString.toString( uint256(position.config.rebate_percent) ), "%</tspan></text>",
            "<text x='292' y='363' text-anchor='middle' class='t' font-size='12'><tspan class='w4 lbl' font-size='10'>AGE</tspan><tspan class='m w9 val' dx='5'>",
            StringHelperLib.format_age( position.config.opened_at ), "</tspan></text>"
        );
    }

    function _render_fee_grid( PositionView memory position ) internal pure returns ( string memory )
    {
        return string.concat(
            _render_earned_fees( position ),
            _render_claimable_fees( position, "gs" )
        );
    }

    function _render_earned_fees( PositionView memory position ) internal pure returns ( string memory )
    {
        string memory earned0  =  _display_amount( position.amounts.earned0, position.tokens.decimals0 );
        string memory earned1  =  _display_amount( position.amounts.earned1, position.tokens.decimals1 );

        return string.concat(
            "<line x1='175' y1='196' x2='175' y2='278' class='rule' stroke-opacity='.08'/>",
            "<ellipse cx='72' cy='211' rx='6' ry='4' fill='#1f9d77'/>",
            "<ellipse cx='72' cy='209' rx='6' ry='4' fill='#37d6a3'/>",
            "<ellipse cx='70' cy='208' rx='2' ry='1.2' fill='#fff' fill-opacity='.5'/>",
            "<text x='104' y='213' text-anchor='middle' class='t w4 lbl' font-size='11'>EARNED</text>",
            _render_amount_line( 99, 241, earned0, position.tokens.symbol0, "w", "w5" ),
            _render_amount_line( 99, 263, earned1, position.tokens.symbol1, "w", "w5" )
        );
    }

    function _render_claimable_fees( PositionView memory position, string memory marker_subclass ) internal pure returns ( string memory )
    {
        string memory claimable0  =  _display_amount( position.amounts.claimable0, position.tokens.decimals0 );
        string memory claimable1  =  _display_amount( position.amounts.claimable1, position.tokens.decimals1 );

        return string.concat(
            "<path d='M213 202 v7 m-3 -3 l3 3 l3 -3' stroke='#37d6a3' stroke-width='1.6' fill='none' stroke-linecap='round' stroke-linejoin='round'/>",
            "<path d='M209 213 h8' stroke='#37d6a3' stroke-width='1.6' stroke-linecap='round'/>",
            "<text x='256' y='213' text-anchor='middle' class='t w4 lbl' font-size='11'>CLAIMABLE</text>",
            _render_amount_line( 251, 241, claimable0, position.tokens.symbol0, "g", marker_subclass ),
            _render_amount_line( 251, 263, claimable1, position.tokens.symbol1, "g", marker_subclass )
        );
    }

    function _render_amount_line(
        uint256 x,
        uint256 y,
        string memory amount,
        string memory symbol,
        string memory amount_class,
        string memory symbol_class
    ) internal pure returns ( string memory )
    {
        return string.concat(
            "<text x='", LibString.toString( x ), "' y='", LibString.toString( y ), "' text-anchor='middle' class='m ",
            amount_class, " val' font-size='16'>", amount,
            "<tspan class='t ", symbol_class, "' dx='5' font-size='12'>", symbol, "</tspan></text>"
        );
    }

    function _render_yield_line( PositionView memory position ) internal pure returns ( string memory )
    {
        return string.concat(
            "<line x1='24' y1='288' x2='326' y2='288' class='rule'/>",
            "<text x='58' y='320' text-anchor='middle' class='t w4 lbl' font-size='11'>YIELD</text>",
            "<text x='196' y='320' text-anchor='end' class='m w val' font-size='18'>", StringHelperLib.format_bps_as_percent_string( position.yield.lifetime_bps ), "</text>",
            "<text x='202' y='320' class='t w5' font-size='11'>life</text>",
            "<text x='290' y='320' text-anchor='end' class='m w val' font-size='18'>", StringHelperLib.format_bps_as_percent_string( position.yield.annualized_bps ), "</text>",
            "<text x='296' y='320' class='t w5' font-size='11'>ann.</text>"
        );
    }


    // ━━━━  ATTRIBUTES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _render_attributes( PositionView memory position ) internal view returns ( string memory )
    {
        return string.concat(
            "[",
            _render_identity_attributes( position ), ",",
            _render_position_attributes( position ), ",",
            _render_fee_attributes( position ), ",",
            StringHelperLib.attribute( "Status", _status_label( position ) ),
            "]"
        );
    }

    function _render_identity_attributes( PositionView memory position ) internal view returns ( string memory )
    {
        return string.concat(
            StringHelperLib.attribute( "Pair", string.concat( position.tokens.symbol0, "/", position.tokens.symbol1 ) ), ",",
            StringHelperLib.attribute( "Chain Id", LibString.toString( block.chainid ) ), ",",
            StringHelperLib.attribute( "NFT Contract", LibString.toHexString( position.identity.nft_contract ) ), ",",
            StringHelperLib.attribute( "Token Id", _token_id_hex( position.identity.token_id ) ), ",",
            StringHelperLib.attribute( "Tick Spacing", LibString.toString( int256(position.identity.tick_spacing) ) ), ",",
            StringHelperLib.attribute( "Hook", LibString.toHexString( position.identity.hook ) ), ",",
            StringHelperLib.attribute( "Pool Id", LibString.toHexString( uint256(position.identity.pool_id), 32 ) )
        );
    }

    function _render_position_attributes( PositionView memory position ) internal pure returns ( string memory )
    {
        string memory position0       =  _display_symbol_amount( position.amounts.position0, position.tokens.decimals0, position.tokens.symbol0 );
        string memory position1       =  _display_symbol_amount( position.amounts.position1, position.tokens.decimals1, position.tokens.symbol1 );

        return string.concat(
            StringHelperLib.attribute( "Base Fee", string.concat( position.config.base_fee_percent, "%" ) ), ",",
            StringHelperLib.attribute( "LP Rebate", string.concat( LibString.toString( uint256(position.config.rebate_percent) ), "%" ) ), ",",
            StringHelperLib.attribute( "Tick Lower", LibString.toString( int256(position.config.tick_lower) ) ), ",",
            StringHelperLib.attribute( "Tick Upper", LibString.toString( int256(position.config.tick_upper) ) ), ",",
            StringHelperLib.attribute( "Opened At", LibString.toString( uint256(position.config.opened_at) ) ), ",",
            StringHelperLib.attribute( "Liquidity", LibString.toString( uint256(position.config.liquidity) ) ), ",",
            StringHelperLib.attribute( "Current Position", string.concat( position0, " / ", position1 ) )
        );
    }

    function _render_fee_attributes( PositionView memory position ) internal pure returns ( string memory )
    {
        string memory claimable0      =  _display_symbol_amount( position.amounts.claimable0, position.tokens.decimals0, position.tokens.symbol0 );
        string memory claimable1      =  _display_symbol_amount( position.amounts.claimable1, position.tokens.decimals1, position.tokens.symbol1 );
        string memory earned0         =  _display_symbol_amount( position.amounts.earned0, position.tokens.decimals0, position.tokens.symbol0 );
        string memory earned1         =  _display_symbol_amount( position.amounts.earned1, position.tokens.decimals1, position.tokens.symbol1 );

        return string.concat(
            StringHelperLib.attribute( "Claimable Fees", string.concat( claimable0, " / ", claimable1 ) ), ",",
            StringHelperLib.attribute( "Lifetime Fees", string.concat( earned0, " / ", earned1 ) ), ",",
            StringHelperLib.attribute( "Fee Yield Current Basis", StringHelperLib.format_bps_as_percent_string( position.yield.lifetime_bps ) ), ",",
            StringHelperLib.attribute( "Annualized Fee Yield Estimate", StringHelperLib.format_bps_as_percent_string( position.yield.annualized_bps ) )
        );
    }

    function _status_label( PositionView memory position ) internal pure returns ( string memory )
    {
        if(  position.config.initialized == false  )  return "Uninitialized";

        return position.config.in_range  ?  "In Range"  :  "Out of Range";
    }

    function _token_id_hex( uint256 token_id ) internal pure returns ( string memory )
    {
        return LibString.toHexString( token_id, 8 );
    }

    // The card always renders amounts at the cosmetic cap; these wrappers are the single chokepoint so a
    // lossy display cap can never leak into a context that needs canonical precision.
    function _display_amount( uint256 amount, uint8 decimals ) internal pure returns ( string memory )
    {
        return StringHelperLib.format_token_amount( amount, decimals, DISPLAY_AMOUNTS_MAX_DECIMALS );
    }

    function _display_symbol_amount( uint256 amount, uint8 decimals, string memory symbol ) internal pure returns ( string memory )
    {
        return StringHelperLib.format_symbol_amount( amount, decimals, DISPLAY_AMOUNTS_MAX_DECIMALS, symbol );
    }


    // ━━━━  YIELD  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _yield_current_basis(
        uint160 sqrt_price_x96,
        uint256 position0,
        uint256 position1,
        SafeSwapPositionInfo memory info,
        uint256 earned0,
        uint256 earned1
    ) internal view returns ( uint256 lifetime_yield_bps, uint256 annualized_yield_bps )
    {
        if(  sqrt_price_x96 == 0  )  return ( 0, 0 );

        uint256 current_basis_value0  =  position0 + _convert_token1_to_token0_units( sqrt_price_x96, position1 );
        if(  current_basis_value0 == 0  )  return ( 0, 0 );

        uint256 earned_value0  =  earned0 + _convert_token1_to_token0_units( sqrt_price_x96, earned1 );
        lifetime_yield_bps     =  FullMath.mulDiv( earned_value0, 10_000, current_basis_value0 );

        // *NOTE*  -  This is an annualized fee-yield estimate against current position value at the current pool price. It
        //            is not time-weighted and does not imply compounding.
        uint256 age  =  block.timestamp > info.opened_at  ?  block.timestamp - info.opened_at  :  0;    // forge-lint: disable-line(block-timestamp)
        if(  age > 0  )  annualized_yield_bps  =  FullMath.mulDiv( lifetime_yield_bps, 365 days, age );
    }

    function _position_amounts( uint160 sqrt_price_x96, int24 tick_lower, int24 tick_upper, uint128 liquidity ) internal pure returns ( uint256 amount0, uint256 amount1 )
    {
        uint160 sqrt_price_a_x96  =  TickMath.getSqrtPriceAtTick( tick_lower );
        uint160 sqrt_price_b_x96  =  TickMath.getSqrtPriceAtTick( tick_upper );

        if(  sqrt_price_a_x96 > sqrt_price_b_x96  )
        {
            ( sqrt_price_a_x96, sqrt_price_b_x96 )  =  ( sqrt_price_b_x96, sqrt_price_a_x96 );
        }

        if(  sqrt_price_x96 <= sqrt_price_a_x96  )
        {
            amount0  =  SqrtPriceMath.getAmount0Delta( sqrt_price_a_x96, sqrt_price_b_x96, liquidity, false );
        }
        else if(  sqrt_price_x96 < sqrt_price_b_x96  )
        {
            amount0  =  SqrtPriceMath.getAmount0Delta( sqrt_price_x96, sqrt_price_b_x96, liquidity, false );
            amount1  =  SqrtPriceMath.getAmount1Delta( sqrt_price_a_x96, sqrt_price_x96, liquidity, false );
        }
        else
        {
            amount1  =  SqrtPriceMath.getAmount1Delta( sqrt_price_a_x96, sqrt_price_b_x96, liquidity, false );
        }
    }

    function _convert_token1_to_token0_units( uint160 sqrt_price_x96, uint256 amount1 ) internal pure returns ( uint256 )
    {
        if(  amount1 == 0  )  return 0;

        uint256 intermediate  =  FullMath.mulDiv( amount1, FixedPoint96.Q96, sqrt_price_x96 );
        return FullMath.mulDiv( intermediate, FixedPoint96.Q96, sqrt_price_x96 );
    }

    function _format_yield_row( uint256 lifetime_yield_bps, uint256 annualized_yield_bps ) internal pure returns ( string memory )
    {
        if(  lifetime_yield_bps == 0  &&  annualized_yield_bps == 0  )  return "n/a";

        string memory lifetime_yield    =  StringHelperLib.format_bps_as_percent_string( lifetime_yield_bps );
        string memory annualized_yield  =  StringHelperLib.format_bps_as_percent_string( annualized_yield_bps );

        return string.concat( lifetime_yield, " life | ", annualized_yield, " ann." );
    }

    function _claimable_fees(
        PoolId pool_id,
        SafeSwapPositionInfo memory info,
        uint128 liquidity,
        uint256 fee_growth_0_last,
        uint256 fee_growth_1_last
    ) internal view returns ( uint256 claimable0, uint256 claimable1 )
    {
        if(  liquidity == 0  )  return ( 0, 0 );

        ( uint256 fee_growth_0_inside, uint256 fee_growth_1_inside )  =  PoolManager.getFeeGrowthInside( pool_id, info.tick_lower, info.tick_upper );

        unchecked
        {
            claimable0  =  FullMath.mulDiv( fee_growth_0_inside - fee_growth_0_last, liquidity, FixedPoint128.Q128 );
            claimable1  =  FullMath.mulDiv( fee_growth_1_inside - fee_growth_1_last, liquidity, FixedPoint128.Q128 );
        }
    }

}

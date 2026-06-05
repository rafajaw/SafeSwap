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
import { Strings } from "@OpenZeppelin/utils/Strings.sol";
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

    // Everything needed to render a position, gathered once to keep the render helpers off the stack.
    struct PositionView {
        string  symbol0;
        string  symbol1;
        uint8   decimals0;
        uint8   decimals1;
        string  base_fee_percent;
        uint8   rebate_percent;
        int24   tick_lower;
        int24   tick_upper;
        uint128 liquidity;
        uint256 position0;
        uint256 position1;
        uint256 claimable0;
        uint256 claimable1;
        uint256 earned0;
        uint256 earned1;
        uint256 lifetime_yield_bps;
        uint256 annualized_yield_bps;
        uint40  opened_at;
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

    function _load_position( ISafeSwapNft nft, uint256 token_id ) internal view returns ( PositionView memory position )
    {
        SafeSwapPositionInfo memory info  =  nft.get_lp_position( token_id );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key( info.token0, info.token1, LPFeeLibrary.DYNAMIC_FEE_FLAG, info.tick_spacing, info.hook );
        PoolId pool_id           =  pool_key.toId( );

        ( uint160 sqrt_price_x96, int24 current_tick, , )  =  PoolManager.getSlot0( pool_id );
        ( uint128 liquidity, uint256 fee_growth_0_last, uint256 fee_growth_1_last )  =
            PoolManager.getPositionInfo( pool_id, address(nft), info.tick_lower, info.tick_upper, bytes32(token_id) );
        ( uint256 checkpointed_earned0, uint256 checkpointed_earned1 )  =  nft.get_lp_fee_totals( token_id );
        ( uint256 claimable0, uint256 claimable1 )  =  _claimable_fees( pool_id, info, liquidity, fee_growth_0_last, fee_growth_1_last );
        uint256 lifetime_earned0  =  checkpointed_earned0 + claimable0;
        uint256 lifetime_earned1  =  checkpointed_earned1 + claimable1;
        ( uint256 position0, uint256 position1 )  =  _position_amounts( sqrt_price_x96, info.tick_lower, info.tick_upper, liquidity );

        // *NOTE*  -  Lifetime earned is the checkpointed SafeSwap total plus fees accrued since the last V4 checkpoint.
        //            Do not add claimable fees again elsewhere; `claimable0/1` is the live accrued component.
        ( uint256 lifetime_yield_bps, uint256 annualized_yield_bps )  =
            _yield_current_basis( sqrt_price_x96, position0, position1, info, lifetime_earned0, lifetime_earned1 );

        position.symbol0           =  StringHelperLib.token_symbol( info.token0 );
        position.symbol1           =  StringHelperLib.token_symbol( info.token1 );
        position.decimals0         =  StringHelperLib.token_decimals( info.token0 );
        position.decimals1         =  StringHelperLib.token_decimals( info.token1 );
        position.base_fee_percent  =  StringHelperLib.format_bps_as_percent( info.base_fee_bps );
        position.rebate_percent    =  info.rebate_percent;
        position.tick_lower        =  info.tick_lower;
        position.tick_upper        =  info.tick_upper;
        position.liquidity         =  liquidity;
        position.position0         =  position0;
        position.position1         =  position1;
        position.claimable0        =  claimable0;
        position.claimable1        =  claimable1;
        position.earned0           =  lifetime_earned0;
        position.earned1           =  lifetime_earned1;
        position.lifetime_yield_bps    =  lifetime_yield_bps;
        position.annualized_yield_bps  =  annualized_yield_bps;
        position.opened_at         =  info.opened_at;
        position.initialized       =  sqrt_price_x96 != 0;
        position.in_range          =  sqrt_price_x96 != 0  &&  current_tick >= info.tick_lower  &&  current_tick < info.tick_upper;
        position.token_id          =  token_id;
    }


    // ━━━━  SVG  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _render_svg( PositionView memory position ) internal view returns ( string memory )
    {
        return string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' width='300' height='400' viewBox='0 0 300 400'>",
            "<defs>",
            "<linearGradient id='bg' x1='0' y1='0' x2='1' y2='1'>",
            "<stop offset='0' stop-color='#276f61'/><stop offset='.46' stop-color='#13233a'/><stop offset='1' stop-color='#584a34'/>",
            "</linearGradient>",
            "<radialGradient id='glow' cx='18%' cy='6%' r='72%'>",
            "<stop offset='0' stop-color='#37d6a3' stop-opacity='.42'/><stop offset='1' stop-color='#37d6a3' stop-opacity='0'/>",
            "</radialGradient>",
            "<style>",
            ".t{font-family:monospace}.muted{fill:#adb7c8}.white{fill:#eaf2ff}.green{fill:#49e6a1}",
            ".label{fill:#c3c9d4;font-size:12px;font-weight:700;letter-spacing:0}.amt{fill:#eaf2ff;font-size:31px}",
            ".sym{fill:#bac2ce;font-size:15px;font-weight:700}.small{font-size:13px}.chip{fill:#162236;stroke:#26374d;stroke-width:1}",
            ".panel{fill:#17263a;fill-opacity:.62}",
            "</style>",
            "</defs>",
            "<rect width='300' height='400' fill='url(#bg)'/>",
            "<rect width='300' height='400' fill='url(#glow)'/>",
            "<text x='20' y='36' class='t white' font-size='20' font-weight='700'>#", Strings.toString( position.token_id ), "</text>",
            _render_status_pill( position ),
            "<line x1='0' y1='70' x2='300' y2='70' stroke='#c8d7e8' stroke-opacity='.10'/>",
            _render_svg_rows( position ),
            "</svg>"
        );
    }

    function _render_svg_rows( PositionView memory position ) internal view returns ( string memory )
    {
        string memory position0       =  StringHelperLib.format_token_amount( position.position0, position.decimals0 );
        string memory position1       =  StringHelperLib.format_token_amount( position.position1, position.decimals1 );
        string memory claimable0      =  StringHelperLib.format_symbol_amount( position.claimable0, position.decimals0, position.symbol0 );
        string memory claimable1      =  StringHelperLib.format_symbol_amount( position.claimable1, position.decimals1, position.symbol1 );
        string memory earned0         =  StringHelperLib.format_symbol_amount( position.earned0, position.decimals0, position.symbol0 );
        string memory earned1         =  StringHelperLib.format_symbol_amount( position.earned1, position.decimals1, position.symbol1 );
        string memory yield_row       =  _format_yield_row( position.lifetime_yield_bps, position.annualized_yield_bps );
        string memory ticks_row       =  string.concat( "TICKS ", Strings.toStringSigned( position.tick_lower ), " -> ", Strings.toStringSigned( position.tick_upper ) );

        return string.concat(
            "<text x='150' y='108' text-anchor='middle' class='t label'>CURRENT POSITION</text>",
            "<text x='82' y='158' text-anchor='middle' class='t amt'>", position0, "</text>",
            "<text x='82' y='185' text-anchor='middle' class='t sym'>", position.symbol0, "</text>",
            "<text x='218' y='158' text-anchor='middle' class='t amt'>", position1, "</text>",
            "<text x='218' y='185' text-anchor='middle' class='t sym'>", position.symbol1, "</text>",
            "<rect x='0' y='214' width='150' height='78' class='panel'/><rect x='150' y='214' width='150' height='78' class='panel' fill-opacity='.72'/>",
            "<line x1='150' y1='214' x2='150' y2='292' stroke='#c8d7e8' stroke-opacity='.08'/>",
            "<text x='20' y='238' class='t label'>Earned</text>",
            "<text x='20' y='260' class='t white small' font-weight='700'>", earned0, "</text>",
            "<text x='20' y='280' class='t muted small'>", earned1, "</text>",
            "<text x='170' y='238' class='t label'>Claimable</text>",
            "<text x='170' y='260' class='t green small' font-weight='700'>", claimable0, "</text>",
            "<text x='170' y='280' class='t muted small'>", claimable1, "</text>",
            "<text x='20' y='318' class='t muted small'>Yield</text>",
            "<text x='280' y='318' text-anchor='end' class='t white small' font-weight='700'>", yield_row, "</text>",
            "<line x1='20' y1='333' x2='280' y2='333' stroke='#c8d7e8' stroke-opacity='.14'/>",
            _render_chip( 20, "FEE ", string.concat( position.base_fee_percent, "%" ) ),
            _render_chip( 108, "REBATE ", string.concat( Strings.toString( position.rebate_percent ), "%" ) ),
            _render_chip( 200, "AGE ", StringHelperLib.format_age( position.opened_at ) ),
            "<text x='150' y='386' text-anchor='middle' class='t muted' font-size='11' font-weight='700'>", ticks_row, "</text>"
        );
    }

    function _render_status_pill( PositionView memory position ) internal pure returns ( string memory )
    {
        string memory color  =  position.in_range  ?  "#49e6a1"  :  "#ff9f9f";

        return string.concat(
            "<rect x='178' y='18' width='104' height='28' rx='14' fill='#15313f' fill-opacity='.55' stroke='", color, "' stroke-opacity='.45'/>",
            "<circle cx='194' cy='32' r='4.5' fill='", color, "'/>",
            "<text x='204' y='37' class='t' fill='", color, "' font-size='13' font-weight='700'>", _status_label( position ), "</text>"
        );
    }

    function _render_chip( uint256 x, string memory label, string memory value ) internal pure returns ( string memory )
    {
        return string.concat(
            "<rect x='", Strings.toString( x ), "' y='348' width='72' height='28' class='chip'/>",
            "<text x='", Strings.toString( x + 36 ), "' y='367' text-anchor='middle' class='t muted' font-size='11' font-weight='700'>", label, value, "</text>"
        );
    }


    // ━━━━  ATTRIBUTES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _render_attributes( PositionView memory position ) internal pure returns ( string memory )
    {
        string memory position0       =  StringHelperLib.format_symbol_amount( position.position0, position.decimals0, position.symbol0 );
        string memory position1       =  StringHelperLib.format_symbol_amount( position.position1, position.decimals1, position.symbol1 );
        string memory claimable0      =  StringHelperLib.format_symbol_amount( position.claimable0, position.decimals0, position.symbol0 );
        string memory claimable1      =  StringHelperLib.format_symbol_amount( position.claimable1, position.decimals1, position.symbol1 );
        string memory earned0         =  StringHelperLib.format_symbol_amount( position.earned0, position.decimals0, position.symbol0 );
        string memory earned1         =  StringHelperLib.format_symbol_amount( position.earned1, position.decimals1, position.symbol1 );

        return string.concat(
            "[",
            StringHelperLib.attribute( "Pair", string.concat( position.symbol0, "/", position.symbol1 ) ), ",",
            StringHelperLib.attribute( "Base Fee", string.concat( position.base_fee_percent, "%" ) ), ",",
            StringHelperLib.attribute( "LP Rebate", string.concat( Strings.toString( position.rebate_percent ), "%" ) ), ",",
            StringHelperLib.attribute( "Tick Lower", Strings.toStringSigned( position.tick_lower ) ), ",",
            StringHelperLib.attribute( "Tick Upper", Strings.toStringSigned( position.tick_upper ) ), ",",
            StringHelperLib.attribute( "Opened At", Strings.toString( position.opened_at ) ), ",",
            StringHelperLib.attribute( "Liquidity", Strings.toString( position.liquidity ) ), ",",
            StringHelperLib.attribute( "Current Position", string.concat( position0, " / ", position1 ) ), ",",
            StringHelperLib.attribute( "Claimable Fees", string.concat( claimable0, " / ", claimable1 ) ), ",",
            StringHelperLib.attribute( "Lifetime Fees", string.concat( earned0, " / ", earned1 ) ), ",",
            StringHelperLib.attribute( "Fee Yield Current Basis", StringHelperLib.format_bps_as_percent_string( position.lifetime_yield_bps ) ), ",",
            StringHelperLib.attribute( "Annualized Fee Yield Estimate", StringHelperLib.format_bps_as_percent_string( position.annualized_yield_bps ) ), ",",
            StringHelperLib.attribute( "Status", _status_label( position ) ),
            "]"
        );
    }

    function _status_label( PositionView memory position ) internal pure returns ( string memory )
    {
        if(  position.initialized == false  )  return "Uninitialized";

        return position.in_range  ?  "In Range"  :  "Out of Range";
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ISafeSwapPositionDescriptorTests } from "@test/Nft/TestManifest.sol";
import { SafeSwapRealEnv } from "@test/helpers/SafeSwapRealEnv.t.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";

import { SAFESWAP_POSITIONS_NAME, SAFESWAP_POSITIONS_DESCRIPTION } from "@SafeSwapCommon/Definitions.sol";
import { PoolInfo } from "@SafeSwapCommon/Types.sol";
import { CreatePositionParams } from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";
import { BondStatus } from "@BondRoute/Definitions.sol";
import { IBondRouteProtected, IERC20, TokenAmount } from "@BondRouteProtected/BondRouteProtected.sol";
import { IERC721Errors } from "@OpenZeppelin/interfaces/draft-IERC6093.sol";
import { Strings } from "@OpenZeppelin/utils/Strings.sol";
import { Vm } from "forge-std/Vm.sol";


/**
 * @title SafeSwapPositionDescriptorTest
 * @notice Verifies the on-chain renderer end-to-end: a real position is created on a real V4 PoolManager, then `tokenURI`
 *         and `contractURI` are base64-decoded in-test and their JSON / embedded SVG content is asserted directly. Proves
 *         the metadata and art are fully on-chain (no external URLs), well-formed, and carry the position's economics.
 */
contract SafeSwapPositionDescriptorTest is ISafeSwapPositionDescriptorTests, SafeSwapRealEnv {

    string internal constant _JSON_PREFIX  =  "data:application/json;base64,";
    string internal constant _SVG_PREFIX   =  "data:image/svg+xml;base64,";

    address internal constant _USER  =  address(0xA11CE);
    uint160 internal constant _SQRT_PRICE_1_1  =  79228162514264337593543950336;

    TestERC20 internal _token_a;
    TestERC20 internal _token_b;
    uint256   internal _token_id;

    function setUp( ) public
    {
        _setup_real_env( );

        _register_hook( 30, 50 );
        _token_a  =  _new_token( "Token A", "TKNA" );
        _token_b  =  _new_token( "Token B", "TKNB" );

        _fund_and_approve( _USER, _token_a, 1_000_000 ether );
        _fund_and_approve( _USER, _token_b, 1_000_000 ether );

        vm.recordLogs( );
        BondStatus status  =  _create_position( );
        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "position creation should execute." );
        _token_id  =  _captured_minted_token_id( );
    }


    // ━━━━  TOKEN URI  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_token_uri_returns_base64_json_with_name_description_and_attributes( )
    external  view
    {
        string memory json  =  _decoded_json( nft.tokenURI( _token_id ) );

        assertTrue( _contains( json, string.concat( '"name":"SafeSwap Positions #', Strings.toString( _token_id ), " " ) ), "name should carry the collection name and token id." );
        assertTrue( _contains( json, "TKNA" )  &&  _contains( json, "TKNB" ), "name/attributes should carry both token symbols." );
        assertTrue( _contains( json, string.concat( '"description":"', SAFESWAP_POSITIONS_DESCRIPTION, '"' ) ), "description should match the constant." );
        assertTrue( _contains( json, string.concat( '"image":"', _SVG_PREFIX ) ), "image should be an on-chain svg data uri." );

        assertTrue( _contains( json, '"trait_type":"Base Fee","value":"0.30%"' ), "base fee attribute should render bps as a percent." );
        assertTrue( _contains( json, '"trait_type":"LP Rebate","value":"50%"' ), "rebate attribute should render the capture percent." );
        assertTrue( _contains( json, '"trait_type":"Tick Lower","value":"-120"' ), "tick lower attribute should render the signed tick." );
        assertTrue( _contains( json, '"trait_type":"Tick Upper","value":"120"' ), "tick upper attribute should render the signed tick." );
        assertTrue( _contains( json, '"trait_type":"Current Position"' ), "metadata should include current token inventory." );
        assertTrue( _contains( json, '"trait_type":"Status","value":"In Range"' ), "a position spanning the current tick should be in range." );
    }

    function test_token_uri_image_is_a_fully_on_chain_svg( )
    external  view
    {
        string memory json   =  _decoded_json( nft.tokenURI( _token_id ) );
        string memory image  =  _extract_between( json, '"image":"', '"' );
        string memory svg    =  string( _base64_decode( _strip_prefix( image, _SVG_PREFIX ) ) );

        assertTrue( _contains( svg, "<svg" ), "image should decode to an inline svg." );
        assertTrue( _contains( svg, "CURRENT POSITION" ), "svg card should use current token inventory as the hero." );
        assertTrue( _contains( svg, "Earned" ), "svg card should render lifetime earned fees." );
        assertTrue( _contains( svg, "Claimable" ), "svg card should prioritize currently claimable fees." );
        assertTrue( _contains( svg, "FEE 0.30%" ), "svg card should render the base fee chip." );
        assertTrue( _contains( svg, "REBATE 50%" ), "svg card should render the rebate chip." );
        assertTrue( _contains( svg, "TICKS -120 -&gt; 120" )  ||  _contains( svg, "TICKS -120 -> 120" ), "svg card should render the tick range." );
        assertTrue( _contains( svg, "In Range" ), "svg card should render the in-range status." );
        assertTrue( _contains( svg, "TKNA" )  &&  _contains( svg, "TKNB" ), "svg card should render both token symbols." );
    }


    // ━━━━  CONTRACT URI  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_contract_uri_returns_collection_metadata( )
    external  view
    {
        string memory json  =  _decoded_json( nft.contractURI( ) );

        assertTrue( _contains( json, string.concat( '"name":"', SAFESWAP_POSITIONS_NAME, '"' ) ), "collection name should match the constant." );
        assertTrue( _contains( json, string.concat( '"description":"', SAFESWAP_POSITIONS_DESCRIPTION, '"' ) ), "collection description should match the constant." );
    }


    // ━━━━  REVERTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_token_uri_reverts_for_nonexistent_token( )
    external
    {
        vm.expectRevert( abi.encodeWithSelector( IERC721Errors.ERC721NonexistentToken.selector, uint256(999) ) );
        nft.tokenURI( 999 );
    }


    // ━━━━  POSITION SETUP  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _create_position( ) internal returns ( BondStatus status )
    {
        CreatePositionParams memory params  =  CreatePositionParams({
            pool_info: PoolInfo({ base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 }),
            tick_lower: -120,
            tick_upper: 120,
            liquidity: 1 ether,
            sqrt_price_x96: _SQRT_PRICE_1_1,
            minimum_deposited_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 0 }),
            minimum_deposited_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 0 })
        });

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_b)), amount: 100 ether });
        fundings[1]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: 100 ether });

        IERC20 currency0  =  address(_token_a) < address(_token_b)  ?  IERC20(address(_token_a))  :  IERC20(address(_token_b));

        ( status, )  =  _create_and_execute_bond(
            _USER,
            IBondRouteProtected( address(nft) ),
            abi.encodeCall( nft.create_position, ( params ) ),
            TokenAmount({ token: currency0, amount: 10 ether }),
            fundings
        );
    }

    function _captured_minted_token_id( ) internal returns ( uint256 )
    {
        Vm.Log[] memory entries  =  vm.getRecordedLogs( );
        bytes32 transfer_sig     =  keccak256( "Transfer(address,address,uint256)" );

        for(  uint256 i = 0  ;  i < entries.length  ;  i = i + 1  )
        {
            Vm.Log memory entry  =  entries[ i ];

            if(  entry.emitter == address(nft)  &&  entry.topics.length == 4  &&  entry.topics[0] == transfer_sig  &&  entry.topics[1] == bytes32(0)  )
            {
                return uint256( entry.topics[3] );
            }
        }

        revert( "create_position emitted no mint" );
    }


    // ━━━━  DATA URI / BASE64 HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _decoded_json( string memory data_uri ) internal pure returns ( string memory )
    {
        return string( _base64_decode( _strip_prefix( data_uri, _JSON_PREFIX ) ) );
    }

    function _strip_prefix( string memory value, string memory prefix ) internal pure returns ( string memory )
    {
        bytes memory v  =  bytes(value);
        bytes memory p  =  bytes(prefix);
        require( v.length >= p.length, "prefix longer than value" );

        for(  uint256 i = 0  ;  i < p.length  ;  i = i + 1  )  require( v[ i ] == p[ i ], "value missing expected prefix" );

        bytes memory out  =  new bytes( v.length - p.length );
        for(  uint256 i = 0  ;  i < out.length  ;  i = i + 1  )  out[ i ]  =  v[ i + p.length ];

        return string(out);
    }

    function _extract_between( string memory source, string memory start_marker, string memory end_marker )
    internal pure returns ( string memory )
    {
        bytes memory s     =  bytes(source);
        uint256 start      =  _index_of( s, bytes(start_marker), 0 );
        require( start != type(uint256).max, "start marker not found" );

        uint256 content    =  start + bytes(start_marker).length;
        uint256 finish     =  _index_of( s, bytes(end_marker), content );
        require( finish != type(uint256).max, "end marker not found" );

        bytes memory out  =  new bytes( finish - content );
        for(  uint256 i = 0  ;  i < out.length  ;  i = i + 1  )  out[ i ]  =  s[ content + i ];

        return string(out);
    }

    function _contains( string memory haystack, string memory needle ) internal pure returns ( bool )
    {
        return _index_of( bytes(haystack), bytes(needle), 0 ) != type(uint256).max;
    }

    function _index_of( bytes memory haystack, bytes memory needle, uint256 from ) private pure returns ( uint256 )
    {
        if(  needle.length == 0  )  return from;
        if(  needle.length > haystack.length  )  return type(uint256).max;

        for(  uint256 i = from  ;  i <= haystack.length - needle.length  ;  i = i + 1  )
        {
            bool matched  =  true;

            for(  uint256 j = 0  ;  j < needle.length  ;  j = j + 1  )
            {
                if(  haystack[ i + j ] != needle[ j ]  )  {  matched = false;  break;  }
            }

            if(  matched  )  return i;
        }

        return type(uint256).max;
    }

    // Standard-alphabet base64 decoder (RFC 4648) for the data URIs OZ Base64 produces. Test-only.
    function _base64_decode( string memory data ) internal pure returns ( bytes memory )
    {
        bytes memory input  =  bytes(data);
        if(  input.length == 0  )  return "";
        require( input.length % 4 == 0, "bad base64 length" );

        bytes memory alphabet  =  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        bytes memory lookup    =  new bytes(256);
        for(  uint256 i = 0  ;  i < alphabet.length  ;  i = i + 1  )  lookup[ uint8(alphabet[ i ]) ]  =  bytes1(uint8(i));

        uint256 padding  =  0;
        if(  input[ input.length - 1 ] == "="  )  padding  =  padding + 1;
        if(  input[ input.length - 2 ] == "="  )  padding  =  padding + 1;

        bytes memory output  =  new bytes( input.length / 4 * 3 - padding );
        uint256 out_index    =  0;

        for(  uint256 i = 0  ;  i < input.length  ;  i = i + 4 )
        {
            uint256 chunk  =  ( uint256(uint8(lookup[ uint8(input[ i ]) ]))     << 18 )
                              | ( uint256(uint8(lookup[ uint8(input[ i + 1 ]) ])) << 12 )
                              | ( uint256(uint8(lookup[ uint8(input[ i + 2 ]) ])) << 6 )
                              |   uint256(uint8(lookup[ uint8(input[ i + 3 ]) ]));

            if(  out_index < output.length  )  {  output[ out_index ]  =  bytes1(uint8(chunk >> 16));  out_index  =  out_index + 1;  }
            if(  out_index < output.length  )  {  output[ out_index ]  =  bytes1(uint8(chunk >> 8));   out_index  =  out_index + 1;  }
            if(  out_index < output.length  )  {  output[ out_index ]  =  bytes1(uint8(chunk));        out_index  =  out_index + 1;  }
        }

        return output;
    }
}

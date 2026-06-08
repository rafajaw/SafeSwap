// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ISafeSwapNftWorkflowTests } from "@test/Nft/TestManifest.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { SafeSwapRealEnv } from "@test/helpers/SafeSwapRealEnv.t.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";
import { Vm } from "forge-std/Vm.sol";

import { PoolInfo, SafeSwapPositionInfo } from "@SafeSwapCommon/Types.sol";
import {
    AddPositionLiquidityParams,
    CollectFeesParams,
    CreatePositionParams,
    RemovePositionLiquidityParams
} from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";
import { BondStatus } from "@BondRoute/Definitions.sol";
import { IBondRouteProtected, IERC20, TokenAmount } from "@BondRouteProtected/BondRouteProtected.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";


/**
 * @title SafeSwapNftWorkflowTest
 * @notice Full-workflow (Tier 1) tests: every position action is driven through the real BondRoute (create_bond -> wait ->
 *         execute_bond) against a real Uniswap V4 PoolManager and a real registered hook clone. Assertions are on real
 *         on-chain effects — user token balances and the V4 position's liquidity (keyed by salt = tokenId) — not on mock
 *         observability. Edge/revert branches that need injected state live in the focused tier (SafeSwapNft.t.sol).
 */
contract SafeSwapNftWorkflowTest is ISafeSwapNftWorkflowTests, SafeSwapRealEnv {

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant _USER  =  address(0xA11CE);
    address internal constant _OTHER =  address(0xB0B);
    uint160 internal constant _SQRT_PRICE_1_1 =  79228162514264337593543950336;

    TestERC20 internal _token_a;
    TestERC20 internal _token_b;
    address   internal _hook;

    function setUp( ) public
    {
        _setup_real_env( );

        _hook     =  _register_hook( 30, 50 );
        _token_a  =  _new_token( "Token A", "TKNA" );
        _token_b  =  _new_token( "Token B", "TKNB" );

        _fund_and_approve( _USER,  _token_a, 1_000_000 ether );
        _fund_and_approve( _USER,  _token_b, 1_000_000 ether );
        _fund_and_approve( _OTHER, _token_a, 1_000_000 ether );
        _fund_and_approve( _OTHER, _token_b, 1_000_000 ether );
    }


    // ━━━━  CREATE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_create_position_initializes_pool_deposits_liquidity_and_mints( )
    external
    {
        uint256 user_a_before  =  _token_a.balanceOf( _USER );
        uint256 user_b_before  =  _token_b.balanceOf( _USER );

        ( BondStatus status, uint256 token_id )  =  _create( _USER );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "create bond should execute." );
        assertEq( nft.ownerOf( token_id ), _USER, "LP NFT should mint to the bonded user." );
        assertTrue( token_id != 0  &&  token_id < 1 << 64, "LP NFT id should be a non-zero 8-byte derived id." );

        ( uint160 sqrt_price, , , )  =  poolManager.getSlot0( _pool_id() );
        assertEq( sqrt_price, _SQRT_PRICE_1_1, "pool should initialize at the signed price." );

        assertEq( _position_liquidity( token_id ), 1 ether, "V4 position (salt = tokenId) should hold the created liquidity." );

        assertLt( _token_a.balanceOf( _USER ), user_a_before, "token A should be pulled from the user (stake refunded)." );
        assertLt( _token_b.balanceOf( _USER ), user_b_before, "token B should be pulled from the user." );

        SafeSwapPositionInfo memory info  =  nft.get_lp_position( token_id );
        assertEq( info.hook, _hook, "metadata should record the registered hook." );
        assertEq( info.base_fee_bps, 30, "metadata should record the base fee." );
        assertEq( info.rebate_percent, 50, "metadata should record the rebate percent." );
    }

    function test_create_position_derives_distinct_token_ids( )
    external
    {
        ( , uint256 first_token_id )   =  _create( _USER );
        ( , uint256 second_token_id )  =  _create( _USER );

        assertEq( nft.ownerOf( first_token_id ), _USER, "first create should mint to the bonded user." );
        assertEq( nft.ownerOf( second_token_id ), _USER, "second create should mint to the bonded user." );
        assertTrue( first_token_id != second_token_id, "each mint should derive a distinct token id." );
        assertEq( _position_liquidity( second_token_id ), 1 ether, "the second position uses its own tokenId as salt." );
    }


    // ━━━━  ADD  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_add_liquidity_increases_the_v4_position( )
    external
    {
        ( , uint256 token_id )  =  _create( _USER );

        BondStatus status  =  _add( _USER, token_id, 1 ether );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "add bond should execute." );
        assertEq( _position_liquidity( token_id ), 2 ether, "adding liquidity should grow the same V4 position." );
    }


    // ━━━━  REMOVE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_remove_liquidity_returns_tokens_and_reduces_the_position( )
    external
    {
        ( , uint256 token_id )  =  _create( _USER );

        uint256 user_a_before  =  _token_a.balanceOf( _USER );
        uint256 user_b_before  =  _token_b.balanceOf( _USER );

        BondStatus status  =  _remove( _USER, token_id, 0.5 ether );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "remove bond should execute." );
        assertEq( _position_liquidity( token_id ), 0.5 ether, "removing half should halve the V4 position liquidity." );
        assertGt( _token_a.balanceOf( _USER ), user_a_before, "removed token A should be returned to the user." );
        assertGt( _token_b.balanceOf( _USER ), user_b_before, "removed token B should be returned to the user." );
    }


    // ━━━━  COLLECT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_collect_fees_executes_with_no_accrued_fees_and_leaves_liquidity( )
    external
    {
        ( , uint256 token_id )  =  _create( _USER );

        _collect( _USER, token_id );

        assertEq( _position_liquidity( token_id ), 1 ether, "collect must not change position liquidity." );
    }


    // ━━━━  AUTHORIZATION (real revert -> graceful bond settlement)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_remove_by_non_owner_is_protocol_reverted_and_position_is_untouched( )
    external
    {
        ( , uint256 token_id )  =  _create( _USER );

        BondStatus status  =  _remove( _OTHER, token_id, 0.5 ether );

        assertEq( uint256(status), uint256(BondStatus.PROTOCOL_REVERTED), "a non-owner remove must revert inside the protocol." );
        assertEq( _position_liquidity( token_id ), 1 ether, "the rejected remove must leave the position liquidity intact." );
        assertEq( nft.ownerOf( token_id ), _USER, "ownership is unchanged." );
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _create( address user ) internal returns ( BondStatus status, uint256 token_id )
    {
        vm.recordLogs( );

        ( status, )  =  _create_and_execute_bond(
            user,
            IBondRouteProtected( address(nft) ),
            abi.encodeCall( nft.bonded_create_position, ( _create_params() ) ),
            _stake_token0( 10 ether ),
            _two_fundings( 100 ether, 100 ether )
        );

        token_id  =  _captured_minted_token_id( );
    }

    // Token ids are derived (hashed), not sequential: read the actual id back from the ERC721 mint Transfer event.
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

    function _add( address user, uint256 token_id, uint128 liquidity ) internal returns ( BondStatus status )
    {
        AddPositionLiquidityParams memory params  =  AddPositionLiquidityParams({
            token_id:          token_id,
            liquidity:         liquidity,
            maximum_deposit_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 100 ether }),
            minimum_deposit_a: 0,
            maximum_deposit_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 100 ether }),
            minimum_deposit_b: 0
        });

        ( status, )  =  _create_and_execute_bond(
            user,
            IBondRouteProtected( address(nft) ),
            abi.encodeCall( nft.bonded_add_liquidity, ( params ) ),
            _stake_token0( 10 ether ),
            _two_fundings( 100 ether, 100 ether )
        );
    }

    function _remove( address user, uint256 token_id, uint128 liquidity ) internal returns ( BondStatus status )
    {
        RemovePositionLiquidityParams memory params  =  RemovePositionLiquidityParams({
            token_id: token_id,
            liquidity: liquidity,
            minimum_received_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 0 }),
            minimum_received_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 0 })
        });

        ( status, )  =  _create_and_execute_bond(
            user,
            IBondRouteProtected( address(nft) ),
            abi.encodeCall( nft.bonded_remove_liquidity, ( params ) ),
            _stake_token0( 10 ether ),
            new TokenAmount[](0)
        );
    }

    function _collect( address user, uint256 token_id ) internal
    {
        CollectFeesParams memory params  =  CollectFeesParams({
            token_id: token_id,
            minimum_received_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 0 }),
            minimum_received_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 0 })
        });

        vm.prank( user );
        nft.collect_fees( params );
    }

    function _create_params( ) internal view returns ( CreatePositionParams memory )
    {
        return CreatePositionParams({
            pool_info: PoolInfo({ base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 }),
            sqrt_price_lower_x96: TickMath.getSqrtPriceAtTick( -120 ),
            sqrt_price_upper_x96: TickMath.getSqrtPriceAtTick( 120 ),
            liquidity: 1 ether,
            sqrt_price_x96: _SQRT_PRICE_1_1,
            maximum_deposit_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 100 ether }),
            minimum_deposit_a: 0,
            maximum_deposit_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 100 ether }),
            minimum_deposit_b: 0
        });
    }

    function _stake_token0( uint256 amount ) internal view returns ( TokenAmount memory )
    {
        return TokenAmount({ token: _currency0(), amount: amount });
    }

    function _two_fundings( uint256 amount_a, uint256 amount_b ) internal view returns ( TokenAmount[] memory fundings )
    {
        fundings     =  new TokenAmount[](2);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_b)), amount: amount_b });
        fundings[1]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: amount_a });
    }

    function _currency0( ) internal view returns ( IERC20 )
    {
        return address(_token_a) < address(_token_b)  ?  IERC20(address(_token_a))  :  IERC20(address(_token_b));
    }

    function _pool_id( ) internal view returns ( PoolId )
    {
        Currency currency0  =  Currency.wrap( address(_token_a) < address(_token_b) ? address(_token_a) : address(_token_b) );
        Currency currency1  =  Currency.wrap( address(_token_a) < address(_token_b) ? address(_token_b) : address(_token_a) );

        PoolKey memory key  =  PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(_hook)
        });

        return key.toId( );
    }

    function _position_liquidity( uint256 token_id ) internal view returns ( uint128 liquidity )
    {
        ( liquidity, , )  =  poolManager.getPositionInfo( _pool_id(), address(nft), -120, 120, bytes32(token_id) );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IUserSwapTests } from "@test/Router/TestManifest.sol";
import { SafeSwapRealEnv } from "@test/helpers/SafeSwapRealEnv.t.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";

import "@SafeSwapCommon/Definitions.sol";
import { HookAddress } from "@SafeSwapCommon/HookAddress.sol";
import { PoolInfo } from "@SafeSwapCommon/Types.sol";
import { MaximumInputExceeded, SafeSwapCommon, SlippageExceeded } from "@SafeSwapCommon/SafeSwapCommon.sol";
import { CreatePositionParams } from "@SafeSwapNft/ModifyLiquidityLib.sol";
import { SafeSwapHookImpl } from "@SafeSwapHook/SafeSwapHookImpl.sol";
import { SafeSwapRouter } from "@SafeSwapRouter/SafeSwapRouter.sol";
import { SafeSwapSigningDescriptor } from "@SafeSwapCommon/SafeSwapSigningDescriptor.sol";
import { HookConfigNotRegistered } from "@SafeSwapRouter/HookRegistry.sol";
import { ExactInputSwapParams } from "@SafeSwapRouter/ExactInputSwapLib.sol";
import { ExactOutputSwapParams } from "@SafeSwapRouter/ExactOutputSwapLib.sol";
import { BondStatus } from "@BondRoute/Definitions.sol";
import {
    BONDROUTE_ADDRESS,
    BondContext,
    BondConstraints,
    IBondRouteProtected,
    IERC20,
    NATIVE_TOKEN,
    TokenAmount,
    Unauthorized,
    UnsupportedCall
} from "@BondRouteProtected/BondRouteProtected.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@UniswapV4Core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta, toBalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";

using PoolIdLibrary for PoolKey;


contract MockBondRouteForUserRouter {

    receive( ) external payable { }

    function announce_protocol( string calldata, string calldata )
    external payable
    {
    }

    function execute( IBondRouteProtected protocol, bytes calldata call, BondContext memory context )
    external returns ( bytes memory output )
    {
        bool success;
        ( success, output )  =  address(protocol).call( abi.encodeCall( protocol.BondRoute_entry_point, ( call, context ) ) );

        if(  success == false  )
        {
            assembly ("memory-safe")
            {
                revert( add( output, 0x20 ), mload( output ) )
            }
        }
    }

    function transfer_funding( address to, IERC20 token, uint256 amount, BondContext memory context )
    external returns ( uint256 updated_index, uint256 new_available_amount )
    {
        for(  uint256 i = 0  ;  i < context.fundings.length  ;  i = i + 1  )
        {
            if(  context.fundings[ i ].token == token  )
            {
                if(  address(token) == address(NATIVE_TOKEN)  )
                {
                    ( bool success, )  =  to.call{ value: amount }( "" );
                    require( success, "native funding transfer failed" );
                }
                else
                {
                    require( token.transferFrom( context.user, to, amount ), "funding transferFrom failed" );
                }

                updated_index         =  i;
                new_available_amount  =  context.fundings[ i ].amount - amount;
                return ( updated_index, new_available_amount );
            }
        }

        revert( "funding not found" );
    }
}


contract MockSwapPoolManager {

    PoolKey public last_swap_key;
    IPoolManager.SwapParams internal _last_swap_params;
    bytes public last_unlock_data;
    BalanceDelta public next_swap_delta;

    uint256 public sync_call_count;
    Currency public last_sync_currency;
    uint256 public settle_call_count;
    uint256 public settle_value_received;
    uint256 public take_call_count;
    Currency public last_take_currency;
    address public last_take_to;
    uint256 public last_take_amount;

    mapping( address recipient => uint256 amount ) public take_amount_by_recipient;

    receive( ) external payable { }

    function set_next_swap_delta( int128 amount0, int128 amount1 )
    external
    {
        next_swap_delta  =  toBalanceDelta( amount0, amount1 );
    }

    function protocolFeeController( )
    external pure returns ( address )
    {
        return address(0xC0FFEE);
    }

    function supportsInterface( bytes4 interface_id )
    external pure returns ( bool )
    {
        return interface_id == 0x0f632fb3;
    }

    function extsload( bytes32[] calldata )
    external pure returns ( bytes32[] memory values )
    {
        values  =  new bytes32[](0);
    }

    function unlock( bytes calldata data )
    external returns ( bytes memory output )
    {
        last_unlock_data  =  data;
        output            =  IUnlockCallback(msg.sender).unlockCallback( data );
    }

    function swap( PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata )
    external returns ( BalanceDelta delta )
    {
        last_swap_key      =  key;
        _last_swap_params  =  params;
        delta              =  next_swap_delta;
    }

    function sync( Currency currency )
    external
    {
        sync_call_count    =  sync_call_count + 1;
        last_sync_currency =  currency;
    }

    function settle( )
    external payable returns ( uint256 )
    {
        settle_call_count      =  settle_call_count + 1;
        settle_value_received  =  settle_value_received + msg.value;
        return msg.value;
    }

    function take( Currency currency, address to, uint256 amount )
    external
    {
        take_call_count                 =  take_call_count + 1;
        last_take_currency              =  currency;
        last_take_to                    =  to;
        last_take_amount                =  amount;
        take_amount_by_recipient[ to ]  =  take_amount_by_recipient[ to ] + amount;
    }

    function last_swap_zero_for_one( ) external view returns ( bool )
    {
        return _last_swap_params.zeroForOne;
    }

    function last_swap_amount_specified( ) external view returns ( int256 )
    {
        return _last_swap_params.amountSpecified;
    }

    function last_swap_sqrt_price_limit_x96( ) external view returns ( uint160 )
    {
        return _last_swap_params.sqrtPriceLimitX96;
    }

    function last_swap_fee( ) external view returns ( uint24 )
    {
        return last_swap_key.fee;
    }

    function last_swap_hook( ) external view returns ( address )
    {
        return address(last_swap_key.hooks);
    }

    function last_swap_tick_spacing( ) external view returns ( int24 )
    {
        return last_swap_key.tickSpacing;
    }
}


/**
 * @title UserSwapTier2Test
 * @notice Focused router swap tests for pool-key construction, swap parameters, settlement accounting, quoter behavior,
 *         and BondRoute integration. The real end-to-end swap workflow remains covered by `UserSwap.t.sol`.
 */
contract UserSwapTier2Test is IUserSwapTests, SafeSwapRealEnv {

    address internal constant _USER      =  address(0xA11CE);
    address internal constant _TREASURY  =  address(0x7EEA5);

    uint16 internal constant _BASE_FEE_BPS     =  30;
    uint8  internal constant _CAPTURE_PERCENT  =  50;
    int24  internal constant _TICK_SPACING     =  60;
    uint160 internal constant _SQRT_PRICE_1_1  =  79228162514264337593543950336;

    uint256 internal constant _AMOUNT_IN    =  1_000 ether;
    uint256 internal constant _POOL_OUTPUT  =  900 ether;

    SafeSwapRouter internal _mock_router;
    MockSwapPoolManager internal _mock_pool_manager;
    TestERC20 internal _token0;
    TestERC20 internal _token1;
    address internal _mock_hook;

    TestERC20 internal _real_token_a;
    TestERC20 internal _real_token_b;
    address internal _real_hook;


    // ━━━━  EXACT INPUT SWAPS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_swap_exact_input_resolves_hook_from_pool_config( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_input( IERC20(address(_token0)), IERC20(address(_token1)), 0 );

        assertEq( _mock_pool_manager.last_swap_hook( ), _mock_hook, "exact input should use the registered hook." );
    }

    function test_swap_exact_input_reverts_when_hook_config_is_unregistered( )
    external
    {
        _set_up_mock_env( );
        _set_exact_input_delta( IERC20(address(_token0)), IERC20(address(_token1)), _AMOUNT_IN, _POOL_OUTPUT );

        vm.expectRevert( abi.encodeWithSelector( HookConfigNotRegistered.selector, 45, _CAPTURE_PERCENT ) );
        _execute(
            abi.encodeCall(
                _mock_router.bonded_swap_exact_input,
                (_exact_input_params(IERC20(address(_token1)), _unregistered_pool_info( ), 0))
            ),
            _context( IERC20(address(_token0)), _AMOUNT_IN )
        );
    }

    function test_swap_exact_input_builds_dynamic_fee_pool_key( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_input( IERC20(address(_token0)), IERC20(address(_token1)), 0 );

        assertEq( _mock_pool_manager.last_swap_fee( ), LPFeeLibrary.DYNAMIC_FEE_FLAG, "exact input should use a dynamic-fee pool key." );
    }

    function test_swap_exact_input_sets_zero_for_one_from_token_order( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_input( IERC20(address(_token0)), IERC20(address(_token1)), 0 );

        assertTrue( _mock_pool_manager.last_swap_zero_for_one( ), "token0 to token1 should set zeroForOne." );
    }

    function test_swap_exact_input_uses_full_range_sqrt_price_limit( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_input( IERC20(address(_token0)), IERC20(address(_token1)), 0 );

        assertEq(
            _mock_pool_manager.last_swap_sqrt_price_limit_x96( ),
            TickMath.MIN_SQRT_PRICE + 1,
            "zeroForOne exact input should use the minimum full-range price limit."
        );
    }

    function test_swap_exact_input_encodes_unlock_callback_as_exact_input_action( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_input( IERC20(address(_token0)), IERC20(address(_token1)), 0 );

        assertEq( uint8(_mock_pool_manager.last_unlock_data( )[0]), uint8(0), "exact input should encode the ExactInput action." );
    }

    function test_swap_exact_input_quote_uses_declared_funding( )
    external
    {
        _set_up_mock_env( );

        _assert_quote_uses_declared_funding( true );
    }

    function test_swap_exact_input_reverts_when_input_token_equals_output_token( )
    external
    {
        _set_up_mock_env( );

        _expect_quote_revert_same_token( true );
    }

    function test_swap_exact_input_settles_input_and_takes_output( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_input( IERC20(address(_token0)), IERC20(address(_token1)), 0 );

        assertEq( _mock_pool_manager.sync_call_count( ), 1, "input token should be synced once." );
        assertEq( _mock_pool_manager.settle_call_count( ), 1, "input token should be settled once." );
        assertEq( _mock_pool_manager.take_call_count( ), 2, "user output and protocol fee should both be taken." );
    }

    function test_swap_exact_input_takes_protocol_fee_from_pool_output( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_input( IERC20(address(_token0)), IERC20(address(_token1)), 0 );

        ( uint256 protocol_fee, )  =  SafeSwapCommon.calculate_protocol_fee( _POOL_OUTPUT, SafeSwapCommon.compute_base_fee_pips(_BASE_FEE_BPS) );

        assertEq( _mock_pool_manager.take_amount_by_recipient(address(_mock_router)), protocol_fee, "router should receive the protocol fee." );
    }

    function test_swap_exact_input_sends_net_output_to_bond_context_user( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_input( IERC20(address(_token0)), IERC20(address(_token1)), 0 );

        ( , uint256 user_output )  =  SafeSwapCommon.calculate_protocol_fee( _POOL_OUTPUT, SafeSwapCommon.compute_base_fee_pips(_BASE_FEE_BPS) );

        assertEq( _mock_pool_manager.take_amount_by_recipient(_USER), user_output, "user should receive net output." );
    }

    function test_swap_exact_input_reverts_when_net_output_is_below_minimum( )
    external
    {
        _set_up_mock_env( );

        ( , uint256 user_output )  =  SafeSwapCommon.calculate_protocol_fee( _POOL_OUTPUT, SafeSwapCommon.compute_base_fee_pips(_BASE_FEE_BPS) );

        _set_exact_input_delta( IERC20(address(_token0)), IERC20(address(_token1)), _AMOUNT_IN, _POOL_OUTPUT );
        vm.expectRevert( abi.encodeWithSelector( SlippageExceeded.selector, user_output, user_output + 1 ) );
        _execute(
            abi.encodeCall(
                _mock_router.bonded_swap_exact_input,
                (_exact_input_params(IERC20(address(_token1)), user_output + 1))
            ),
            _context( IERC20(address(_token0)), _AMOUNT_IN )
        );
    }

    function test_swap_exact_input_handles_native_input( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_input_native_input( );

        assertEq( _mock_pool_manager.settle_value_received( ), _AMOUNT_IN, "native input should be forwarded through settle value." );
    }

    function test_swap_exact_input_handles_native_output( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_input( IERC20(address(_token0)), NATIVE_TOKEN, 0 );

        assertEq( Currency.unwrap(_mock_pool_manager.last_take_currency( )), address(0), "native output should be taken as address zero currency." );
    }


    // ━━━━  EXACT OUTPUT SWAPS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_swap_exact_output_resolves_hook_from_pool_config( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_output( IERC20(address(_token0)), IERC20(address(_token1)), 100 ether, _AMOUNT_IN );

        assertEq( _mock_pool_manager.last_swap_hook( ), _mock_hook, "exact output should use the registered hook." );
    }

    function test_swap_exact_output_reverts_when_hook_config_is_unregistered( )
    external
    {
        _set_up_mock_env( );
        _set_exact_output_delta( IERC20(address(_token0)), IERC20(address(_token1)), _AMOUNT_IN - 1, 100 ether );

        vm.expectRevert( abi.encodeWithSelector( HookConfigNotRegistered.selector, 45, _CAPTURE_PERCENT ) );
        _execute(
            abi.encodeCall(
                _mock_router.bonded_swap_exact_output,
                (_exact_output_params(IERC20(address(_token1)), _unregistered_pool_info( ), 100 ether))
            ),
            _context( IERC20(address(_token0)), _AMOUNT_IN )
        );
    }

    function test_swap_exact_output_builds_dynamic_fee_pool_key( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_output( IERC20(address(_token0)), IERC20(address(_token1)), 100 ether, _AMOUNT_IN );

        assertEq( _mock_pool_manager.last_swap_fee( ), LPFeeLibrary.DYNAMIC_FEE_FLAG, "exact output should use a dynamic-fee pool key." );
    }

    function test_swap_exact_output_sets_zero_for_one_from_token_order( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_output( IERC20(address(_token0)), IERC20(address(_token1)), 100 ether, _AMOUNT_IN );

        assertTrue( _mock_pool_manager.last_swap_zero_for_one( ), "token0 to token1 should set zeroForOne." );
    }

    function test_swap_exact_output_uses_full_range_sqrt_price_limit( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_output( IERC20(address(_token0)), IERC20(address(_token1)), 100 ether, _AMOUNT_IN );

        assertEq(
            _mock_pool_manager.last_swap_sqrt_price_limit_x96( ),
            TickMath.MIN_SQRT_PRICE + 1,
            "zeroForOne exact output should use the minimum full-range price limit."
        );
    }

    function test_swap_exact_output_encodes_unlock_callback_as_exact_output_action( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_output( IERC20(address(_token0)), IERC20(address(_token1)), 100 ether, _AMOUNT_IN );

        assertEq( uint8(_mock_pool_manager.last_unlock_data( )[0]), uint8(1), "exact output should encode the ExactOutput action." );
    }

    function test_swap_exact_output_quote_uses_declared_funding( )
    external
    {
        _set_up_mock_env( );

        _assert_quote_uses_declared_funding( false );
    }

    function test_swap_exact_output_grosses_up_output_for_protocol_fee( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_output( IERC20(address(_token0)), IERC20(address(_token1)), 100 ether, _AMOUNT_IN );

        assertGt( uint256(_mock_pool_manager.last_swap_amount_specified( )), 100 ether, "pool output should be grossed up for protocol fee." );
    }

    function test_swap_exact_output_sends_exact_net_output_to_user( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_output( IERC20(address(_token0)), IERC20(address(_token1)), 100 ether, _AMOUNT_IN );

        assertEq( _mock_pool_manager.take_amount_by_recipient(_USER), 100 ether, "user should receive exact net output." );
    }

    function test_swap_exact_output_reverts_when_required_input_exceeds_maximum( )
    external
    {
        _set_up_mock_env( );
        _set_exact_output_delta( IERC20(address(_token0)), IERC20(address(_token1)), _AMOUNT_IN + 1, 100 ether );

        vm.expectRevert( abi.encodeWithSelector( MaximumInputExceeded.selector, _AMOUNT_IN + 1, _AMOUNT_IN ) );
        _execute(
            abi.encodeCall(
                _mock_router.bonded_swap_exact_output,
                (_exact_output_params(IERC20(address(_token1)), 100 ether))
            ),
            _context( IERC20(address(_token0)), _AMOUNT_IN )
        );
    }

    function test_swap_exact_output_handles_native_input( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_output_native_input( );

        assertGt( _mock_pool_manager.settle_value_received( ), 0, "native exact-output input should be settled with value." );
    }

    function test_swap_exact_output_handles_native_output( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_output( IERC20(address(_token0)), NATIVE_TOKEN, 100 ether, _AMOUNT_IN );

        assertEq( Currency.unwrap(_mock_pool_manager.last_take_currency( )), address(0), "native output should be taken as address zero currency." );
    }

    function test_swap_exact_output_rounds_protocol_fee_without_underpaying_user( )
    external
    {
        _set_up_mock_env( );

        _execute_exact_output( IERC20(address(_token0)), IERC20(address(_token1)), 1, _AMOUNT_IN );

        assertEq( _mock_pool_manager.take_amount_by_recipient(_USER), 1, "rounding should not underpay the exact user output." );
    }


    // ━━━━  UNLOCK CALLBACK GATE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_unlock_callback_reverts_when_caller_is_not_pool_manager( )
    external
    {
        _set_up_mock_env( );

        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, address(this), address(_mock_pool_manager) ) );
        _mock_router.unlockCallback( "" );
    }


    // ━━━━  QUOTER / POOL ID  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_quote_exact_input_uses_same_base_fee_simulation_as_hook( )
    external
    {
        _set_up_real_quote_env( );

        ( , uint24 quoted_fee, )  =  router.__OFF_CHAIN__quote_swap_exact_input(
            IERC20(address(_real_token_a)),
            IERC20(address(_real_token_b)),
            _pool_info( ),
            _AMOUNT_IN
        );

        uint24 hook_fee  =  _hook_before_swap_fee( -int256(_AMOUNT_IN) );

        assertEq( quoted_fee, hook_fee, "quote should use the same simulator and fee formula as beforeSwap." );
    }

    function test_quote_exact_input_reverts_when_amount_exceeds_int256_max( )
    external
    {
        _set_up_mock_env( );

        vm.expectRevert( );
        _mock_router.__OFF_CHAIN__quote_swap_exact_input(
            IERC20(address(_token0)),
            IERC20(address(_token1)),
            _pool_info( ),
            uint256(type(int256).max) + 1
        );
    }

    function test_quote_exact_input_returns_total_fee_pips_movement_and_net_output( )
    external
    {
        _set_up_real_quote_env( );

        ( uint256 net_output, uint24 total_fee_pips, uint256 movement_bps )  =  router.__OFF_CHAIN__quote_swap_exact_input(
            IERC20(address(_real_token_a)),
            IERC20(address(_real_token_b)),
            _pool_info( ),
            _AMOUNT_IN
        );

        assertGt( net_output, 0, "exact-input quote should return net output." );
        assertGt( total_fee_pips, SafeSwapCommon.compute_base_fee_pips(_BASE_FEE_BPS), "price movement should add a repricing fee." );
        assertGt( movement_bps, 0, "price-moving exact-input quote should report movement." );
    }

    function test_quote_exact_input_fee_matches_executed_fee( )
    external
    {
        _set_up_real_quote_env( );

        ( , uint24 quoted_fee, )  =  router.__OFF_CHAIN__quote_swap_exact_input(
            IERC20(address(_real_token_a)),
            IERC20(address(_real_token_b)),
            _pool_info( ),
            _AMOUNT_IN
        );

        assertEq( quoted_fee, _hook_before_swap_fee(-int256(_AMOUNT_IN)), "quoted fee should match the fee returned to V4." );
    }

    function test_quote_exact_input_net_output_matches_execution_with_two_pass_simulation( )
    external
    {
        _set_up_real_quote_env( );

        ( uint256 quoted_net_output, , )  =  router.__OFF_CHAIN__quote_swap_exact_input(
            IERC20(address(_real_token_a)),
            IERC20(address(_real_token_b)),
            _pool_info( ),
            _AMOUNT_IN
        );

        uint256 user_out_before  =  _real_token_b.balanceOf( _USER );
        BondStatus status        =  _real_swap_exact_input( _AMOUNT_IN, 0 );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "quoted exact-input swap should execute." );
        assertEq( _real_token_b.balanceOf(_USER) - user_out_before, quoted_net_output, "execution should match the two-pass quote." );
    }

    function test_quote_exact_output_grosses_up_requested_net_output( )
    external
    {
        _set_up_real_quote_env( );

        uint256 exact_output  =  500 ether;

        ( uint256 required_input, , uint256 movement_bps )  =  router.__OFF_CHAIN__quote_swap_exact_output(
            IERC20(address(_real_token_a)),
            IERC20(address(_real_token_b)),
            _pool_info( ),
            exact_output
        );

        assertGt( required_input, exact_output, "grossed-up exact-output quote should require more input than net output." );
        assertGt( movement_bps, 0, "price-moving exact-output quote should report movement." );
    }

    function test_quote_exact_output_reverts_when_grossed_output_exceeds_int256_max( )
    external
    {
        _set_up_mock_env( );

        vm.expectRevert( );
        _mock_router.__OFF_CHAIN__quote_swap_exact_output(
            IERC20(address(_token0)),
            IERC20(address(_token1)),
            _pool_info( ),
            type(uint256).max
        );
    }

    function test_quote_exact_output_required_input_matches_execution( )
    external
    {
        _set_up_real_quote_env( );

        uint256 exact_output  =  500 ether;

        ( uint256 required_input, , )  =  router.__OFF_CHAIN__quote_swap_exact_output(
            IERC20(address(_real_token_a)),
            IERC20(address(_real_token_b)),
            _pool_info( ),
            exact_output
        );

        uint256 user_out_before  =  _real_token_b.balanceOf( _USER );
        BondStatus status        =  _real_swap_exact_output( exact_output, required_input );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "quoted exact-output maximum input should execute." );
        assertEq( _real_token_b.balanceOf(_USER) - user_out_before, exact_output, "execution should deliver the quoted exact output." );
    }

    function test_quote_reverts_for_unregistered_hook_config( )
    external
    {
        _set_up_mock_env( );

        vm.expectRevert( abi.encodeWithSelector( HookConfigNotRegistered.selector, 45, _CAPTURE_PERCENT ) );
        _mock_router.__OFF_CHAIN__quote_swap_exact_input(
            IERC20(address(_token0)),
            IERC20(address(_token1)),
            _unregistered_pool_info( ),
            _AMOUNT_IN
        );
    }

    function test_off_chain_get_pool_id_matches_dynamic_fee_pool_key( )
    external
    {
        _set_up_mock_env( );

        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key(
            IERC20(address(_token0)),
            IERC20(address(_token1)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            _TICK_SPACING,
            _mock_hook
        );

        PoolId actual_pool_id  =  _mock_router.__OFF_CHAIN__get_pool_id( IERC20(address(_token0)), IERC20(address(_token1)), _pool_info( ) );

        assertEq(
            PoolId.unwrap( actual_pool_id ),
            PoolId.unwrap( pool_key.toId( ) ),
            "pool id should match the dynamic-fee pool key."
        );
    }

    function test_off_chain_get_pool_id_reverts_for_unregistered_config( )
    external
    {
        _set_up_mock_env( );

        vm.expectRevert( abi.encodeWithSelector( HookConfigNotRegistered.selector, 45, _CAPTURE_PERCENT ) );
        _mock_router.__OFF_CHAIN__get_pool_id( IERC20(address(_token0)), IERC20(address(_token1)), _unregistered_pool_info( ) );
    }

    function test_off_chain_get_pool_state_reports_initialized_pool_price( )
    external
    {
        _set_up_real_quote_env( );

        ( PoolId pool_id, uint160 sqrt_price_x96, int24 tick, bool initialized )  =  router.__OFF_CHAIN__get_pool_state(
            IERC20(address(_real_token_a)),
            IERC20(address(_real_token_b)),
            _pool_info( )
        );

        PoolId expected_pool_id  =  router.__OFF_CHAIN__get_pool_id( IERC20(address(_real_token_a)), IERC20(address(_real_token_b)), _pool_info( ) );

        assertTrue( initialized, "a pool with a created position should report initialized." );
        assertEq( PoolId.unwrap(pool_id), PoolId.unwrap(expected_pool_id), "pool state id should match the pool id view." );
        assertEq( sqrt_price_x96, _SQRT_PRICE_1_1, "an unswapped 1:1 position should report the 1:1 price." );
        assertEq( tick, int24(0), "the 1:1 price should report tick zero." );
    }

    function test_off_chain_get_pool_state_reports_uninitialized_pool( )
    external
    {
        _set_up_real_quote_env( );

        TestERC20 fresh_token_a  =  _new_token( "Fresh Token A", "FTKA" );
        TestERC20 fresh_token_b  =  _new_token( "Fresh Token B", "FTKB" );

        ( , uint160 sqrt_price_x96, , bool initialized )  =  router.__OFF_CHAIN__get_pool_state(
            IERC20(address(fresh_token_a)),
            IERC20(address(fresh_token_b)),
            _pool_info( )
        );

        assertFalse( initialized, "a pair with no created position should report uninitialized." );
        assertEq( sqrt_price_x96, 0, "an uninitialized pool should report a zero price." );
    }


    // ━━━━  BONDROUTE INTEGRATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_bondroute_selectors_are_only_swap_functions( )
    external
    {
        _set_up_mock_env( );

        bytes4[] memory selectors  =  _mock_router.BondRoute_get_protected_selectors( );

        assertEq( selectors.length, 2, "router should expose two protected selectors." );
        assertEq( selectors[0], _mock_router.bonded_swap_exact_input.selector, "selector 0 should be exact input." );
        assertEq( selectors[1], _mock_router.bonded_swap_exact_output.selector, "selector 1 should be exact output." );
    }

    function test_bondroute_quote_reverts_for_unsupported_call( )
    external
    {
        _set_up_mock_env( );

        vm.expectRevert( UnsupportedCall.selector );
        _mock_router.BondRoute_quote_call(
            abi.encodeWithSelector( bytes4(0xdeadbeef) ),
            IERC20(address(_token0)),
            _one_funding( IERC20(address(_token0)), _AMOUNT_IN )
        );
    }

    function test_bondroute_quote_reverts_for_short_call_data( )
    external
    {
        _set_up_mock_env( );

        vm.expectRevert( UnsupportedCall.selector );
        _mock_router.BondRoute_quote_call( hex"123456", IERC20(address(_token0)), _one_funding(IERC20(address(_token0)), _AMOUNT_IN) );
    }

    function test_bondroute_quote_exact_input_uses_declared_funding( )
    external
    {
        _set_up_mock_env( );

        _assert_quote_uses_declared_funding( true );
    }

    function test_bondroute_quote_exact_output_uses_declared_funding( )
    external
    {
        _set_up_mock_env( );

        _assert_quote_uses_declared_funding( false );
    }

    function test_bondroute_quote_uses_swap_stake_percentage( )
    external
    {
        _set_up_mock_env( );

        BondConstraints memory constraints  =  _mock_router.BondRoute_quote_call(
            abi.encodeCall( _mock_router.bonded_swap_exact_input, (_exact_input_params(IERC20(address(_token1)), 0)) ),
            IERC20(address(_token0)),
            _one_funding( IERC20(address(_token0)), _AMOUNT_IN )
        );

        assertEq( constraints.min_stake.amount, _AMOUNT_IN / 100, "swap stake should be 1% of funding." );
    }

    function test_bondroute_signing_info_hashes_pool_info_and_token_amounts_readably( )
    external
    {
        _set_up_mock_env( );

        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  _mock_router.BondRoute_get_signing_info(
            abi.encodeCall( _mock_router.bonded_swap_exact_input, (_exact_input_params(IERC20(address(_token1)), 123)) )
        );

        assertGt( bytes(typed_string).length, 0, "signing info should expose a readable typed string." );
        assertNotEq( struct_hash, bytes32(0), "signing info should hash the exact input params." );
        assertGt( token_amount_offset, 0, "signing info should include the TokenAmount offset." );
    }

    function test_signing_descriptor_returns_exact_input_and_output_message_values( )
    external
    {
        _set_up_mock_env( );
        SafeSwapSigningDescriptor descriptor  =  SafeSwapSigningDescriptor(_mock_router.SigningDescriptor());

        ( string[] memory exact_input_values, address[] memory exact_input_addresses )  =  descriptor.build_router_signing_values(
            abi.encodeCall( _mock_router.bonded_swap_exact_input, (_exact_input_params(IERC20(address(_token1)), 123)) )
        );
        ( string[] memory exact_output_values, address[] memory exact_output_addresses )  =  descriptor.build_router_signing_values(
            abi.encodeCall( _mock_router.bonded_swap_exact_output, (_exact_output_params(IERC20(address(_token1)), 456)) )
        );
        string memory input_symbol   =  TestERC20(address(_default_token_in(IERC20(address(_token1))))).symbol();
        string memory output_symbol  =  _token1.symbol();

        assertEq( exact_input_values[0], string.concat( "= 1,000 ", input_symbol ), "exact-input Pay value mismatch." );
        assertEq( exact_input_values[1], string.concat( ">= 0.000000000000000123 ", output_symbol ), "exact-input Receive value mismatch." );
        assertEq( exact_output_values[0], string.concat( "<= 1,000 ", input_symbol ), "exact-output Pay value mismatch." );
        assertEq( exact_output_values[1], string.concat( "= 0.000000000000000456 ", output_symbol ), "exact-output Receive value mismatch." );
        assertEq( exact_input_values[2], "0.3% base fee | 50% rebate | tick spacing 60", "exact-input Pool value mismatch." );
        assertEq( exact_input_values[3], ">>  Check protocol and token addresses  <<", "exact-input Warning value mismatch." );
        assertEq( exact_input_addresses[0], address(_token1), "exact-input token anchor mismatch." );
        assertEq( exact_output_addresses[0], address(_token1), "exact-output token anchor mismatch." );
    }

    function test_bondroute_signing_info_reverts_for_unsupported_call( )
    external
    {
        _set_up_mock_env( );

        vm.expectRevert( UnsupportedCall.selector );
        _mock_router.BondRoute_get_signing_info( abi.encodeWithSelector(bytes4(0xdeadbeef)) );
    }

    function test_bondroute_signing_info_reverts_for_short_call_data( )
    external
    {
        _set_up_mock_env( );

        vm.expectRevert( UnsupportedCall.selector );
        _mock_router.BondRoute_get_signing_info( hex"123456" );
    }


    // ━━━━  MOCK SETUP / EXECUTION HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _set_up_mock_env( ) internal
    {
        vm.chainId( 31_337 );
        vm.roll( 100 );
        vm.warp( _DEFAULT_CONFIG_TIMESTAMP + 1 days );

        _deploy_chain_config( );
        _etch_mock_bond_route( );

        _mock_pool_manager  =  new MockSwapPoolManager();
        _publish_config_address( POOL_MANAGER_KEY, address(_mock_pool_manager) );
        _publish_config_address( INITIAL_TREASURY_KEY, _TREASURY );
        _publish_native_token_config( );
        _publish_config_address( SAFESWAP_SIGNING_DESCRIPTOR_KEY, address(new SafeSwapSigningDescriptor( )) );

        _mock_router  =  new SafeSwapRouter();

        _mock_hook  =  _hook_address( _BASE_FEE_BPS, _CAPTURE_PERCENT, HookAddress.REQUIRED_PERMISSIONS );
        _publish_config_bytes32( SAFESWAP_HOOK_CODEHASH_KEY, keccak256(_approved_runtime()) );
        vm.etch( _mock_hook, _approved_runtime() );

        vm.prank( _mock_hook );
        _mock_router.register_hook( _BASE_FEE_BPS, _CAPTURE_PERCENT );

        _token0  =  new TestERC20( "Token 0", "TK0", 18 );
        _token1  =  new TestERC20( "Token 1", "TK1", 18 );

        if(  address(_token0) > address(_token1)  )
        {
            ( _token0, _token1 )  =  ( _token1, _token0 );
        }

        _token0.mint( _USER, 1_000_000 ether );
        _token1.mint( _USER, 1_000_000 ether );

        vm.startPrank( _USER );
        _token0.approve( BONDROUTE_ADDRESS, type(uint256).max );
        _token1.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );
    }

    function _execute_exact_input( IERC20 token_in, IERC20 token_out, uint256 minimum_output_amount ) internal
    {
        _execute_exact_input( token_in, token_out, _pool_info( ), minimum_output_amount );
    }

    function _execute_exact_input( IERC20 token_in, IERC20 token_out, PoolInfo memory pool_info, uint256 minimum_output_amount ) internal
    {
        _set_exact_input_delta( token_in, token_out, _AMOUNT_IN, _POOL_OUTPUT );
        _execute(
            abi.encodeCall( _mock_router.bonded_swap_exact_input, (_exact_input_params(token_in, _AMOUNT_IN, token_out, pool_info, minimum_output_amount)) ),
            _context( token_in, _AMOUNT_IN )
        );
    }

    function _execute_exact_input_native_input( ) internal
    {
        _set_exact_input_delta( NATIVE_TOKEN, IERC20(address(_token1)), _AMOUNT_IN, _POOL_OUTPUT );
        _execute(
            abi.encodeCall( _mock_router.bonded_swap_exact_input, (_exact_input_params(NATIVE_TOKEN, _AMOUNT_IN, IERC20(address(_token1)), _pool_info( ), 0)) ),
            _context_native_input( _AMOUNT_IN )
        );
    }

    function _execute_exact_output( IERC20 token_in, IERC20 token_out, uint256 exact_output, uint256 maximum_input ) internal
    {
        _execute_exact_output( token_in, token_out, _pool_info( ), exact_output, maximum_input );
    }

    function _execute_exact_output( IERC20 token_in, IERC20 token_out, PoolInfo memory pool_info, uint256 exact_output, uint256 maximum_input ) internal
    {
        _execute_exact_output_with_required_input_and_tokens( token_in, token_out, pool_info, exact_output, maximum_input, maximum_input - 1 );
    }

    function _execute_exact_output_with_required_input( uint256 required_input, uint256 maximum_input ) internal
    {
        _execute_exact_output_with_required_input_and_tokens(
            IERC20(address(_token0)),
            IERC20(address(_token1)),
            _pool_info( ),
            100 ether,
            maximum_input,
            required_input
        );
    }

    function _execute_exact_output_native_input( ) internal
    {
        uint256 exact_output    =  100 ether;
        uint256 required_input  =  101 ether;

        _set_exact_output_delta( NATIVE_TOKEN, IERC20(address(_token1)), required_input, exact_output );
        _execute(
            abi.encodeCall( _mock_router.bonded_swap_exact_output, (_exact_output_params(NATIVE_TOKEN, _AMOUNT_IN, IERC20(address(_token1)), _pool_info( ), exact_output)) ),
            _context_native_input( _AMOUNT_IN )
        );
    }

    function _execute_exact_output_with_required_input_and_tokens(
        IERC20 token_in,
        IERC20 token_out,
        PoolInfo memory pool_info,
        uint256 exact_output,
        uint256 maximum_input,
        uint256 required_input
    ) internal
    {
        _set_exact_output_delta( token_in, token_out, required_input, exact_output );
        _execute(
            abi.encodeCall( _mock_router.bonded_swap_exact_output, (_exact_output_params(token_in, maximum_input, token_out, pool_info, exact_output)) ),
            _context( token_in, maximum_input )
        );
    }

    function _set_exact_input_delta( IERC20 token_in, IERC20 token_out, uint256 amount_in, uint256 pool_output ) internal
    {
        bool zero_for_one  =  address(token_in) < address(token_out);

        _mock_pool_manager.set_next_swap_delta(
            zero_for_one ? -int128(int256(amount_in)) : int128(int256(pool_output)),
            zero_for_one ? int128(int256(pool_output)) : -int128(int256(amount_in))
        );
    }

    function _set_exact_output_delta( IERC20 token_in, IERC20 token_out, uint256 required_input, uint256 exact_output ) internal
    {
        uint256 grossed_up_pool_output  =  _grossed_up_output( exact_output );
        bool zero_for_one               =  address(token_in) < address(token_out);

        _mock_pool_manager.set_next_swap_delta(
            zero_for_one ? -int128(int256(required_input)) : int128(int256(grossed_up_pool_output)),
            zero_for_one ? int128(int256(grossed_up_pool_output)) : -int128(int256(required_input))
        );
    }

    function _execute( bytes memory call, BondContext memory context ) internal
    {
        MockBondRouteForUserRouter(payable(BONDROUTE_ADDRESS)).execute( IBondRouteProtected(address(_mock_router)), call, context );
    }

    function _context( IERC20 token_in, uint256 amount ) internal view returns ( BondContext memory context )
    {
        context.user                =  _USER;
        context.stake               =  TokenAmount({ token: token_in, amount: amount / 100 });
        context.fundings            =  _one_funding( token_in, amount );
        context.creation_block      =  block.number - MIN_BOND_EXECUTION_DELAY_IN_BLOCKS;
        context.creation_timestamp  =  block.timestamp - MIN_BOND_EXECUTION_DELAY_IN_SECONDS - 1;
    }

    function _context_native_input( uint256 amount ) internal returns ( BondContext memory context )
    {
        vm.deal( BONDROUTE_ADDRESS, amount );

        context.user                =  _USER;
        context.stake               =  TokenAmount({ token: NATIVE_TOKEN, amount: amount / 100 });
        context.fundings            =  _one_funding( NATIVE_TOKEN, amount );
        context.creation_block      =  block.number - MIN_BOND_EXECUTION_DELAY_IN_BLOCKS;
        context.creation_timestamp  =  block.timestamp - MIN_BOND_EXECUTION_DELAY_IN_SECONDS - 1;
    }

    function _assert_quote_uses_declared_funding( bool exact_input ) internal
    {
        TokenAmount[] memory fundings  =  new TokenAmount[](0);
        bytes memory call              =  exact_input
            ? abi.encodeCall( _mock_router.bonded_swap_exact_input, (_exact_input_params(IERC20(address(_token1)), 0)) )
            : abi.encodeCall( _mock_router.bonded_swap_exact_output, (_exact_output_params(IERC20(address(_token1)), 100 ether)) );

        BondConstraints memory constraints  =  _mock_router.BondRoute_quote_call( call, IERC20(address(_token0)), fundings );

        assertEq( constraints.min_fundings.length, 1, "swap quote should require one declared funding." );
        assertEq( address(constraints.min_fundings[0].token), address(_token0), "swap funding token should come from calldata." );
        assertEq( constraints.min_fundings[0].amount, _AMOUNT_IN, "swap funding amount should come from calldata." );
    }

    function _expect_quote_revert_same_token( bool exact_input ) internal
    {
        bytes memory call  =  exact_input
            ? abi.encodeCall( _mock_router.bonded_swap_exact_input, (_exact_input_params(IERC20(address(_token0)), _AMOUNT_IN, IERC20(address(_token0)), _pool_info(), 0)) )
            : abi.encodeCall( _mock_router.bonded_swap_exact_output, (_exact_output_params(IERC20(address(_token0)), _AMOUNT_IN, IERC20(address(_token0)), _pool_info(), 100 ether)) );

        vm.expectRevert( bytes(TOKENS_MUST_BE_DIFFERENT) );
        _mock_router.BondRoute_quote_call( call, IERC20(address(_token0)), _one_funding(IERC20(address(_token0)), _AMOUNT_IN) );
    }

    function _etch_mock_bond_route( ) internal
    {
        MockBondRouteForUserRouter mock  =  new MockBondRouteForUserRouter();
        vm.etch( BONDROUTE_ADDRESS, address(mock).code );
    }

    function _approved_runtime( ) internal pure returns ( bytes memory )
    {
        return hex"600160005260206000f3";
    }


    // ━━━━  REAL QUOTE HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _set_up_real_quote_env( ) internal
    {
        _setup_real_env( );

        _real_hook     =  _register_hook( _BASE_FEE_BPS, _CAPTURE_PERCENT );
        _real_token_a  =  _new_token( "Real Token A", "RTKA" );
        _real_token_b  =  _new_token( "Real Token B", "RTKB" );

        _fund_and_approve( _USER, _real_token_a, 10_000_000 ether );
        _fund_and_approve( _USER, _real_token_b, 10_000_000 ether );

        _create_real_deep_position( );
    }

    function _create_real_deep_position( ) internal
    {
        CreatePositionParams memory params  =  CreatePositionParams({
            pool_info: _pool_info( ),
            sqrt_price_lower_x96: TickMath.getSqrtPriceAtTick( -6000 ),
            sqrt_price_upper_x96: TickMath.getSqrtPriceAtTick( 6000 ),
            liquidity: 100_000 ether,
            sqrt_price_x96: _SQRT_PRICE_1_1,
            maximum_deposit_a: TokenAmount({ token: IERC20(address(_real_token_a)), amount: 1_000_000 ether }),
            minimum_deposit_a: 0,
            maximum_deposit_b: TokenAmount({ token: IERC20(address(_real_token_b)), amount: 1_000_000 ether }),
            minimum_deposit_b: 0
        });

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_real_token_b)), amount: 1_000_000 ether });
        fundings[1]  =  TokenAmount({ token: IERC20(address(_real_token_a)), amount: 1_000_000 ether });

        IERC20 token0  =  address(_real_token_a) < address(_real_token_b)  ?  IERC20(address(_real_token_a))  :  IERC20(address(_real_token_b));

        _create_and_execute_bond(
            _USER,
            IBondRouteProtected( address(nft) ),
            abi.encodeCall( nft.bonded_create_position, ( params ) ),
            TokenAmount({ token: token0, amount: 50_000 ether }),
            fundings
        );
    }

    function _real_swap_exact_input( uint256 amount_in, uint256 minimum_output_amount ) internal returns ( BondStatus status )
    {
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_in: IERC20(address(_real_token_a)),
            input_amount: amount_in,
            token_out: IERC20(address(_real_token_b)),
            minimum_output_amount: minimum_output_amount,
            pool_info: _pool_info( )
        });

        ( status, )  =  _create_and_execute_bond(
            _USER,
            IBondRouteProtected( address(router) ),
            abi.encodeCall( router.bonded_swap_exact_input, ( params ) ),
            _real_swap_stake( amount_in ),
            _real_one_funding( amount_in )
        );
    }

    function _real_swap_exact_output( uint256 exact_output_amount, uint256 maximum_input ) internal returns ( BondStatus status )
    {
        ExactOutputSwapParams memory params  =  ExactOutputSwapParams({
            token_in: IERC20(address(_real_token_a)),
            maximum_input_amount: maximum_input,
            token_out: IERC20(address(_real_token_b)),
            exact_output_amount: exact_output_amount,
            pool_info: _pool_info( )
        });

        ( status, )  =  _create_and_execute_bond(
            _USER,
            IBondRouteProtected( address(router) ),
            abi.encodeCall( router.bonded_swap_exact_output, ( params ) ),
            _real_swap_stake( maximum_input ),
            _real_one_funding( maximum_input )
        );
    }

    function _hook_before_swap_fee( int256 amount_specified ) internal returns ( uint24 fee_without_flag )
    {
        PoolKey memory pool_key  =  SafeSwapCommon.build_pool_key(
            IERC20(address(_real_token_a)),
            IERC20(address(_real_token_b)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            _TICK_SPACING,
            _real_hook
        );

        IPoolManager.SwapParams memory swap_params  =  IPoolManager.SwapParams({
            zeroForOne: address(_real_token_a) < address(_real_token_b),
            amountSpecified: amount_specified,
            sqrtPriceLimitX96: address(_real_token_a) < address(_real_token_b) ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.prank( address(poolManager) );
        ( , , uint24 fee )  =  SafeSwapHookImpl(_real_hook).beforeSwap( address(router), pool_key, swap_params, "" );

        fee_without_flag  =  fee & LPFeeLibrary.REMOVE_OVERRIDE_MASK;
    }

    function _real_swap_stake( uint256 amount_in ) internal view returns ( TokenAmount memory )
    {
        uint256 stake_amount  =  amount_in / 100;
        if(  stake_amount == 0  )  stake_amount  =  1;

        return TokenAmount({ token: IERC20(address(_real_token_a)), amount: stake_amount });
    }

    function _real_one_funding( uint256 amount_in ) internal view returns ( TokenAmount[] memory fundings )
    {
        fundings     =  new TokenAmount[](1);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_real_token_a)), amount: amount_in });
    }


    // ━━━━  SHARED HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // Full builders — the signed `Pay` (token_in + amount) must match the bond funding at execution.
    function _exact_input_params( IERC20 token_in, uint256 input_amount, IERC20 token_out, PoolInfo memory pool_info, uint256 minimum_output_amount )
    internal pure returns ( ExactInputSwapParams memory )
    {
        return ExactInputSwapParams({ token_in: token_in, input_amount: input_amount, token_out: token_out, minimum_output_amount: minimum_output_amount, pool_info: pool_info });
    }

    function _exact_output_params( IERC20 token_in, uint256 maximum_input_amount, IERC20 token_out, PoolInfo memory pool_info, uint256 exact_output_amount )
    internal pure returns ( ExactOutputSwapParams memory )
    {
        return ExactOutputSwapParams({ token_in: token_in, maximum_input_amount: maximum_input_amount, token_out: token_out, exact_output_amount: exact_output_amount, pool_info: pool_info });
    }

    // Convenience overloads for quote / signing / revert tests that never reach the funding check: the input defaults to the
    // other pool token and `_AMOUNT_IN`, which matches the `_context(...)` funding the mock-execution tests build.
    function _exact_input_params( IERC20 token_out, uint256 minimum_output_amount ) internal view returns ( ExactInputSwapParams memory )
    {
        return _exact_input_params( _default_token_in( token_out ), _AMOUNT_IN, token_out, _pool_info( ), minimum_output_amount );
    }

    function _exact_input_params( IERC20 token_out, PoolInfo memory pool_info, uint256 minimum_output_amount )
    internal view returns ( ExactInputSwapParams memory )
    {
        return _exact_input_params( _default_token_in( token_out ), _AMOUNT_IN, token_out, pool_info, minimum_output_amount );
    }

    function _exact_output_params( IERC20 token_out, uint256 exact_output_amount ) internal view returns ( ExactOutputSwapParams memory )
    {
        return _exact_output_params( _default_token_in( token_out ), _AMOUNT_IN, token_out, _pool_info( ), exact_output_amount );
    }

    function _exact_output_params( IERC20 token_out, PoolInfo memory pool_info, uint256 exact_output_amount )
    internal view returns ( ExactOutputSwapParams memory )
    {
        return _exact_output_params( _default_token_in( token_out ), _AMOUNT_IN, token_out, pool_info, exact_output_amount );
    }

    function _default_token_in( IERC20 token_out ) internal view returns ( IERC20 )
    {
        return address(token_out) == address(_token1)  ?  IERC20(address(_token0))  :  IERC20(address(_token1));
    }

    function _one_funding( IERC20 token, uint256 amount ) internal pure returns ( TokenAmount[] memory fundings )
    {
        fundings     =  new TokenAmount[](1);
        fundings[0]  =  TokenAmount({ token: token, amount: amount });
    }

    function _pool_info( ) internal pure returns ( PoolInfo memory )
    {
        return PoolInfo({ base_fee_bps: _BASE_FEE_BPS, rebate_percent: _CAPTURE_PERCENT, tick_spacing: _TICK_SPACING });
    }

    function _unregistered_pool_info( ) internal pure returns ( PoolInfo memory )
    {
        return PoolInfo({ base_fee_bps: 45, rebate_percent: _CAPTURE_PERCENT, tick_spacing: _TICK_SPACING });
    }

    function _grossed_up_output( uint256 exact_output ) internal pure returns ( uint256 )
    {
        uint256 base_fee_pips       =  SafeSwapCommon.compute_base_fee_pips( _BASE_FEE_BPS );
        uint256 effective_fee_rate  =  base_fee_pips < MIN_PROTOCOL_FEE_RATE  ?  MIN_PROTOCOL_FEE_RATE  :  base_fee_pips;

        return exact_output * PROTOCOL_FEE_DIVISOR / ( PROTOCOL_FEE_DIVISOR - effective_fee_rate );
    }
}

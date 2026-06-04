// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ISafeSwapRouterTests } from "@test/Router/TestManifest.sol";
import { SafeSwapRealEnv } from "@test/helpers/SafeSwapRealEnv.t.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";

import "@SafeSwapCommon/Definitions.sol";
import { PoolInfo } from "@SafeSwapCommon/Types.sol";
import { SafeSwapRouter } from "@SafeSwapRouter/SafeSwapRouter.sol";
import { Invalid, TransferFailed } from "@SafeSwapRouter/Treasury.sol";
import { CreatePositionParams } from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";
import { ExactInputSwapParams } from "@SafeSwapRouter/libraries/ExactInputSwapLib.sol";
import { BondStatus } from "@BondRoute/Definitions.sol";
import { BONDROUTE_ADDRESS, IBondRouteProtected, IERC20, NATIVE_TOKEN, TokenAmount, Unauthorized } from "@BondRouteProtected/BondRouteProtected.sol";


contract RouterMockPoolManager {

    address internal constant _PROTOCOL_FEE_CONTROLLER  =  address(0xC0FFEE);
    bool internal _supports_erc6909  =  true;

    function set_supports_erc6909( bool value )
    external
    {
        _supports_erc6909  =  value;
    }

    function protocolFeeController( )
    external  pure returns ( address )
    {
        return _PROTOCOL_FEE_CONTROLLER;
    }

    function extsload( bytes32[] calldata )
    external  pure returns ( bytes32[] memory values )
    {
        values  =  new bytes32[](0);
    }

    function supportsInterface( bytes4 interface_id )
    external  view returns ( bool )
    {
        return interface_id == 0x0f632fb3  &&  _supports_erc6909;
    }
}


contract FailingTransferToken {

    mapping( address => uint256 ) public balanceOf;

    function mint( address account, uint256 amount )
    external
    {
        balanceOf[ account ]  =  balanceOf[ account ] + amount;
    }

    function transfer( address, uint256 )
    external  pure returns ( bool )
    {
        return false;
    }
}


contract RejectNativeRecipient {
    receive( ) external payable { revert( "native rejected" ); }
}


contract SafeSwapRouterTest is ISafeSwapRouterTests, SafeSwapRealEnv {

    address internal constant _USER       =  address(0xA11CE);
    address internal constant _TREASURY   =  address(0x7EEA5);
    address internal constant _RECIPIENT  =  address(0xBEEF);
    address internal constant _OTHER      =  address(0xBAD);

    uint16 internal constant _BASE_FEE_BPS     =  30;
    uint8  internal constant _CAPTURE_PERCENT  =  50;
    int24  internal constant _TICK_SPACING     =  60;
    uint160 internal constant _SQRT_PRICE_1_1  =  79228162514264337593543950336;

    RouterMockPoolManager internal _mock_pool_manager;


    // ━━━━  DEPLOYMENT AND NATIVE RECEIVER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_constructor_reads_pool_manager_and_treasury_from_chain_config( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        assertEq( deployed_router.get_treasury(), _TREASURY, "constructor should read the initial treasury from ChainConfig." );
    }

    function test_constructor_reverts_when_pool_manager_is_invalid( )
    external
    {
        _set_up_router_constructor_config( address(0xBEEF), _TREASURY );

        vm.expectRevert( bytes("SafeSwap: Invalid pool_manager") );
        new SafeSwapRouter();
    }

    function test_constructor_reverts_when_initial_treasury_is_zero( )
    external
    {
        _set_up_router_constructor_config( address(_mock_pool_manager), address(0) );

        vm.expectRevert( bytes("SafeSwap: Invalid initial_treasury") );
        new SafeSwapRouter();
    }

    function test_receive_accepts_native_token_from_bondroute( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        vm.deal( BONDROUTE_ADDRESS, 1 ether );
        vm.prank( BONDROUTE_ADDRESS );
        ( bool success, )  =  payable(address(deployed_router)).call{ value: 1 ether }( "" );

        assertTrue( success, "router should accept native token from BondRoute." );
        assertEq( address(deployed_router).balance, 1 ether, "router should receive the native token." );
    }

    function test_receive_accepts_native_token_from_pool_manager( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        vm.deal( address(_mock_pool_manager), 1 ether );
        vm.prank( address(_mock_pool_manager) );
        ( bool success, )  =  payable(address(deployed_router)).call{ value: 1 ether }( "" );

        assertTrue( success, "router should accept native token from PoolManager." );
        assertEq( address(deployed_router).balance, 1 ether, "router should receive the native token." );
    }

    function test_receive_reverts_for_unknown_sender( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        vm.deal( _OTHER, 1 ether );
        vm.prank( _OTHER );
        ( bool success, bytes memory data )  =  payable(address(deployed_router)).call{ value: 1 ether }( "" );

        assertFalse( success, "router should reject native token from an unknown sender." );
        assertEq( data, abi.encodeWithSignature( "Error(string)", "Direct transfers not allowed" ), "revert reason should identify direct transfers." );
    }


    // ━━━━  TREASURY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_protocol_fee_recipient_is_router( )
    external
    {
        _setup_real_env( );

        address hook  =  _register_hook( _BASE_FEE_BPS, _CAPTURE_PERCENT );
        hook;

        TestERC20 token_a  =  _new_token( "Token A", "TKNA" );
        TestERC20 token_b  =  _new_token( "Token B", "TKNB" );

        _fund_and_approve( _USER, token_a, 10_000_000 ether );
        _fund_and_approve( _USER, token_b, 10_000_000 ether );
        _create_position( token_a, token_b );

        IERC20 token_out  =  address(token_a) < address(token_b)  ?  IERC20(address(token_b))  :  IERC20(address(token_a));
        IERC20 token_in   =  address(token_a) < address(token_b)  ?  IERC20(address(token_a))  :  IERC20(address(token_b));

        uint256 router_fee_before  =  token_out.balanceOf( address(router) );

        _swap_exact_input({ token_in: token_in, token_out: token_out, amount_in: 1_000 ether });

        assertGt( token_out.balanceOf( address(router) ), router_fee_before, "protocol fee should accrue to the router." );
    }

    function test_get_treasury_returns_current_treasury( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        assertEq( deployed_router.get_treasury(), _TREASURY, "get_treasury should return the current treasury." );
    }

    function test_treasury_can_withdraw_erc20_protocol_fees( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();
        TestERC20 token                 =  new TestERC20( "Fee Token", "FEE", 18 );
        token.mint( address(deployed_router), 100 ether );

        vm.prank( _TREASURY );
        uint256 withdrawn  =  deployed_router.withdraw_protocol_fees( IERC20(address(token)), _RECIPIENT );

        assertEq( withdrawn, 100 ether - 1, "withdrawal should leave one wei in the router." );
        assertEq( token.balanceOf( _RECIPIENT ), 100 ether - 1, "recipient should receive withdrawn ERC20 fees." );
        assertEq( token.balanceOf( address(deployed_router) ), 1, "router should retain one wei." );
    }

    function test_treasury_can_withdraw_native_protocol_fees( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();
        _fund_router_native( deployed_router, 10 ether );

        uint256 recipient_before  =  _RECIPIENT.balance;

        vm.prank( _TREASURY );
        uint256 withdrawn  =  deployed_router.withdraw_protocol_fees( NATIVE_TOKEN, _RECIPIENT );

        assertEq( withdrawn, 10 ether - 1, "native withdrawal should leave one wei in the router." );
        assertEq( _RECIPIENT.balance - recipient_before, 10 ether - 1, "recipient should receive withdrawn native fees." );
        assertEq( address(deployed_router).balance, 1, "router should retain one wei." );
    }

    function test_withdraw_protocol_fees_keeps_one_wei_in_contract( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();
        TestERC20 token                 =  new TestERC20( "Fee Token", "FEE", 18 );
        token.mint( address(deployed_router), 2 );

        vm.prank( _TREASURY );
        uint256 withdrawn  =  deployed_router.withdraw_protocol_fees( IERC20(address(token)), _RECIPIENT );

        assertEq( withdrawn, 1, "withdrawal should return balance minus one wei." );
        assertEq( token.balanceOf( address(deployed_router) ), 1, "router should keep one wei." );
    }

    function test_withdraw_protocol_fees_returns_zero_when_balance_is_zero( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();
        TestERC20 token                 =  new TestERC20( "Fee Token", "FEE", 18 );

        vm.prank( _TREASURY );
        uint256 withdrawn  =  deployed_router.withdraw_protocol_fees( IERC20(address(token)), _RECIPIENT );

        assertEq( withdrawn, 0, "zero balance should return zero withdrawal." );
    }

    function test_withdraw_protocol_fees_returns_zero_when_balance_is_one_wei( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();
        TestERC20 token                 =  new TestERC20( "Fee Token", "FEE", 18 );
        token.mint( address(deployed_router), 1 );

        vm.prank( _TREASURY );
        uint256 withdrawn  =  deployed_router.withdraw_protocol_fees( IERC20(address(token)), _RECIPIENT );

        assertEq( withdrawn, 0, "one wei balance should be retained and return zero withdrawal." );
        assertEq( token.balanceOf( address(deployed_router) ), 1, "router should retain the one wei balance." );
    }

    function test_withdraw_protocol_fees_reverts_when_recipient_is_zero( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        vm.expectRevert( abi.encodeWithSelector( Invalid.selector, "recipient", 0 ) );
        vm.prank( _TREASURY );
        deployed_router.withdraw_protocol_fees( NATIVE_TOKEN, address(0) );
    }

    function test_withdraw_protocol_fees_reverts_when_erc20_transfer_fails( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();
        FailingTransferToken token      =  new FailingTransferToken();
        token.mint( address(deployed_router), 10 ether );

        vm.expectRevert( abi.encodeWithSelector( TransferFailed.selector, address(token), _RECIPIENT, 10 ether - 1 ) );
        vm.prank( _TREASURY );
        deployed_router.withdraw_protocol_fees( IERC20(address(token)), _RECIPIENT );
    }

    function test_withdraw_protocol_fees_reverts_when_native_transfer_fails( )
    external
    {
        SafeSwapRouter deployed_router    =  _deploy_router_with_mock_pool_manager();
        RejectNativeRecipient recipient   =  new RejectNativeRecipient();
        _fund_router_native( deployed_router, 10 ether );

        vm.expectRevert( abi.encodeWithSelector( TransferFailed.selector, address(NATIVE_TOKEN), address(recipient), 10 ether - 1 ) );
        vm.prank( _TREASURY );
        deployed_router.withdraw_protocol_fees( NATIVE_TOKEN, address(recipient) );
    }

    function test_non_treasury_cannot_withdraw_protocol_fees( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, _OTHER, _TREASURY ) );
        vm.prank( _OTHER );
        deployed_router.withdraw_protocol_fees( NATIVE_TOKEN, _RECIPIENT );
    }

    function test_transfer_treasury_reverts_when_caller_is_not_current_treasury( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, _OTHER, _TREASURY ) );
        vm.prank( _OTHER );
        deployed_router.transfer_treasury( _RECIPIENT );
    }

    function test_transfer_treasury_reverts_when_new_treasury_is_current_treasury( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        vm.expectRevert( abi.encodeWithSelector( Invalid.selector, "new_treasury", uint256(uint160(_TREASURY)) ) );
        vm.prank( _TREASURY );
        deployed_router.transfer_treasury( _TREASURY );
    }

    function test_transfer_treasury_can_cancel_pending_transfer_with_zero_address( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        vm.prank( _TREASURY );
        deployed_router.transfer_treasury( _RECIPIENT );

        vm.prank( _TREASURY );
        deployed_router.transfer_treasury( address(0) );

        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, _RECIPIENT, address(0) ) );
        vm.prank( _RECIPIENT );
        deployed_router.accept_treasury( );
    }

    function test_accept_treasury_reverts_when_caller_is_not_pending_treasury( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        vm.prank( _TREASURY );
        deployed_router.transfer_treasury( _RECIPIENT );

        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, _OTHER, _RECIPIENT ) );
        vm.prank( _OTHER );
        deployed_router.accept_treasury( );
    }

    function test_treasury_transfer_updates_authority( )
    external
    {
        SafeSwapRouter deployed_router  =  _deploy_router_with_mock_pool_manager();

        vm.prank( _TREASURY );
        deployed_router.transfer_treasury( _RECIPIENT );

        vm.prank( _RECIPIENT );
        deployed_router.accept_treasury( );

        assertEq( deployed_router.get_treasury(), _RECIPIENT, "accepted nominee should become the treasury." );
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _deploy_router_with_mock_pool_manager( ) internal returns ( SafeSwapRouter deployed_router )
    {
        _set_up_router_constructor_config( address(0), _TREASURY );

        deployed_router  =  new SafeSwapRouter();
    }

    function _set_up_router_constructor_config( address pool_manager, address treasury ) internal
    {
        vm.chainId( 31_337 );
        vm.warp( _DEFAULT_CONFIG_TIMESTAMP + 1 days );

        _deploy_chain_config( );
        _set_up_bond_route( );

        if(  pool_manager == address(0)  )
        {
            _mock_pool_manager  =  new RouterMockPoolManager();
            pool_manager        =  address(_mock_pool_manager);
        }
        else
        {
            _mock_pool_manager  =  RouterMockPoolManager(pool_manager);
        }

        _publish_config_address( POOL_MANAGER_KEY, pool_manager );
        _publish_config_address( INITIAL_TREASURY_KEY, treasury );
    }

    function _fund_router_native( SafeSwapRouter deployed_router, uint256 amount ) internal
    {
        vm.deal( address(_mock_pool_manager), amount );
        vm.prank( address(_mock_pool_manager) );
        ( bool success, )  =  payable(address(deployed_router)).call{ value: amount }( "" );

        assertTrue( success, "test setup should fund the router from PoolManager." );
    }

    function _create_position( TestERC20 token_a, TestERC20 token_b ) internal
    {
        CreatePositionParams memory params  =  CreatePositionParams({
            pool_info: _pool_info(),
            tick_lower: -6000,
            tick_upper: 6000,
            liquidity: 100_000 ether,
            sqrt_price_x96: _SQRT_PRICE_1_1,
            minimum_deposited_a: TokenAmount({ token: IERC20(address(token_a)), amount: 0 }),
            minimum_deposited_b: TokenAmount({ token: IERC20(address(token_b)), amount: 0 })
        });

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[0]  =  TokenAmount({ token: IERC20(address(token_b)), amount: 1_000_000 ether });
        fundings[1]  =  TokenAmount({ token: IERC20(address(token_a)), amount: 1_000_000 ether });

        IERC20 token0  =  address(token_a) < address(token_b)  ?  IERC20(address(token_a))  :  IERC20(address(token_b));

        ( BondStatus status, )  =  _create_and_execute_bond(
            _USER,
            IBondRouteProtected( address(nft) ),
            abi.encodeCall( nft.create_position, ( params ) ),
            TokenAmount({ token: token0, amount: 50_000 ether }),
            fundings
        );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "position creation should execute." );
    }

    function _swap_exact_input( IERC20 token_in, IERC20 token_out, uint256 amount_in ) internal
    {
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token_out,
            minimum_output_amount: 0,
            pool_info: _pool_info()
        });

        TokenAmount[] memory fundings  =  new TokenAmount[](1);
        fundings[0]  =  TokenAmount({ token: token_in, amount: amount_in });

        ( BondStatus status, )  =  _create_and_execute_bond(
            _USER,
            IBondRouteProtected( address(router) ),
            abi.encodeCall( router.swap_exact_input, ( params ) ),
            _swap_stake( token_in, amount_in ),
            fundings
        );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "swap should execute." );
    }

    function _pool_info( ) internal pure returns ( PoolInfo memory )
    {
        return PoolInfo({ base_fee_bps: _BASE_FEE_BPS, rebate_percent: _CAPTURE_PERCENT, tick_spacing: _TICK_SPACING });
    }

    function _swap_stake( IERC20 token, uint256 amount_in ) internal pure returns ( TokenAmount memory )
    {
        uint256 stake_amount  =  amount_in / 100;
        if(  stake_amount == 0  )  stake_amount  =  1;

        return TokenAmount({ token: token, amount: stake_amount });
    }
}

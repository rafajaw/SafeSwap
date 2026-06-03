// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./TestBase.t.sol";

import { BondRoute as CanonicalBondRoute } from "@BondRoute/BondRoute.sol";
import { SameBlockExecution } from "@BondRoute/Core.sol";
import { ExecutionData } from "@BondRoute/Core.sol";
import { BondStatus, INVALID_PROTOCOL_OR_CALL } from "@BondRoute/Definitions.sol";
import { HashLib } from "@BondRoute/HashLib.sol";
import { CommitmentMismatch } from "@BondRoute/User.sol";
import {
    IBondRouteProtected as CanonicalBondRouteProtected,
    IERC20 as CanonicalIERC20,
    TokenAmount as CanonicalTokenAmount
} from "@BondRouteProtected/BondRouteProtected.sol";


contract CanonicalBondRouteIntegrationTest is SafeSwapTestBase {

    CanonicalBondRoute internal canonical_bond_route;

    function setUp( ) public override
    {
        super.setUp( );

        deployCodeTo( "BondRoute.sol:BondRoute", abi.encode( treasury ), BONDROUTE_ADDRESS );
        canonical_bond_route  =  CanonicalBondRoute(payable(BONDROUTE_ADDRESS));

        vm.startPrank( user );
        token0.approve( BONDROUTE_ADDRESS, type(uint256).max );
        token1.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );
    }


    // ━━━━  COMMITMENT HASH GUARDRAILS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_canonical_bondroute_commitment_hash_has_caffe_prefix_and_sentinel_layout( ) external
    {
        ExecutionData memory execution_data  =  _create_exact_input_execution_data( 100 ether, 11 );

        bytes32 commitment_hash  =  canonical_bond_route.__OFF_CHAIN__calc_commitment_hash( user, execution_data );
        uint256 encoded          =  uint256(commitment_hash);

        assertEq( encoded >> 232, 0xCAFFE0, "Commitment hash should carry the BondRoute prefix." );
        assertEq( ( encoded >> 184 ) & 0xFFFFFFFFFFFF, 0, "Reserved bytes after prefix should be zero." );
        assertEq( HashLib.calc_commitment_hash( user, BONDROUTE_ADDRESS, execution_data ), commitment_hash, "Helper should match HashLib." );
    }

    function test_canonical_bondroute_create_bond_reverts_for_wrong_stake_amount( ) external
    {
        ExecutionData memory execution_data  =  _create_exact_input_execution_data( 100 ether, 12 );
        bytes32 commitment_hash              =  canonical_bond_route.__OFF_CHAIN__calc_commitment_hash( user, execution_data );

        CanonicalTokenAmount memory wrong_stake  =  CanonicalTokenAmount({
            token: execution_data.stake.token,
            amount: execution_data.stake.amount + 1
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CommitmentMismatch.selector,
                commitment_hash,
                block.chainid,
                address(wrong_stake.token),
                wrong_stake.amount
            )
        );
        vm.prank( user );
        canonical_bond_route.create_bond( commitment_hash, wrong_stake );
    }

    function test_canonical_bondroute_create_bond_reverts_for_wrong_stake_token( ) external
    {
        ExecutionData memory execution_data  =  _create_exact_input_execution_data( 100 ether, 13 );
        bytes32 commitment_hash              =  canonical_bond_route.__OFF_CHAIN__calc_commitment_hash( user, execution_data );

        CanonicalTokenAmount memory wrong_stake  =  CanonicalTokenAmount({
            token: CanonicalIERC20(address(token1)),
            amount: execution_data.stake.amount
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CommitmentMismatch.selector,
                commitment_hash,
                block.chainid,
                address(wrong_stake.token),
                wrong_stake.amount
            )
        );
        vm.prank( user );
        canonical_bond_route.create_bond( commitment_hash, wrong_stake );
    }

    function test_canonical_bondroute_create_bond_reverts_for_wrong_chain( ) external
    {
        ExecutionData memory execution_data  =  _create_exact_input_execution_data( 100 ether, 14 );
        bytes32 commitment_hash              =  canonical_bond_route.__OFF_CHAIN__calc_commitment_hash( user, execution_data );

        uint256 wrong_chain_id  =  block.chainid + 1;
        vm.chainId( wrong_chain_id );

        vm.expectRevert(
            abi.encodeWithSelector(
                CommitmentMismatch.selector,
                commitment_hash,
                wrong_chain_id,
                address(execution_data.stake.token),
                execution_data.stake.amount
            )
        );
        vm.prank( user );
        canonical_bond_route.create_bond( commitment_hash, execution_data.stake );
    }


    // ━━━━  EXECUTION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


    function test_canonical_bondroute_executes_exact_input_swap( ) external
    {
        ExecutionData memory execution_data  =  _create_exact_input_execution_data( 100 ether, 1 );
        _create_canonical_bond( execution_data );
        _advance_to_valid_execution_time( );

        vm.prank( user );
        ( BondStatus status, bytes memory output )  =  canonical_bond_route.execute_bond( execution_data );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "Bond should execute." );
        assertEq( output.length, 0, "SafeSwap exact-input swap returns no data." );
    }

    function test_canonical_bondroute_exact_input_swap_pulls_erc20_funding_from_user( ) external
    {
        uint256 amount_in            =  100 ether;
        uint256 user_token0_before   =  token0.balanceOf( user );

        ExecutionData memory execution_data  =  _create_exact_input_execution_data( amount_in, 2 );
        _create_canonical_bond( execution_data );
        _advance_to_valid_execution_time( );

        vm.prank( user );
        ( BondStatus status, )  =  canonical_bond_route.execute_bond( execution_data );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "Bond should execute." );
        assertEq( user_token0_before - token0.balanceOf( user ), amount_in, "User should net-pay only swap funding; stake is returned." );
    }

    function test_canonical_bondroute_exact_input_swap_uses_native_funding_from_msg_value( ) external
    {
        uint256 amount_in         =  100 ether;
        uint256 user_token1_before  =  token1.balanceOf( user );

        vm.deal( user, 1_000 ether );
        uint256 user_eth_before   =  user.balance;

        ExecutionData memory execution_data  =  _create_native_exact_input_execution_data( amount_in, 7 );
        _create_canonical_bond( execution_data );
        _advance_to_valid_execution_time( );

        vm.prank( user );
        ( BondStatus status, )  =  canonical_bond_route.execute_bond{ value: amount_in }( execution_data );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "Bond should execute." );
        assertEq( user_eth_before - user.balance, amount_in, "User should net-pay only native swap funding; stake is returned." );
        assertGt( token1.balanceOf( user ), user_token1_before, "User should receive ERC20 output from native input swap." );
    }

    function test_canonical_bondroute_create_position_pulls_two_erc20_fundings_from_user( ) external
    {
        uint256 amount0              =  100 ether;
        uint256 amount1              =  120 ether;
        uint256 user_token0_before   =  token0.balanceOf( user );
        uint256 user_token1_before   =  token1.balanceOf( user );

        ExecutionData memory execution_data  =  _create_erc20_create_position_execution_data( amount0, amount1, 8 );
        _create_canonical_bond( execution_data );
        _advance_to_valid_execution_time( );

        vm.prank( user );
        ( BondStatus status, )  =  canonical_bond_route.execute_bond( execution_data );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "Bond should execute." );
        assertEq( user_token0_before - token0.balanceOf( user ), amount0, "User should net-pay token0 funding; stake is returned." );
        assertEq( user_token1_before - token1.balanceOf( user ), amount1, "User should pay token1 funding." );
    }

    function test_canonical_bondroute_create_position_uses_native_and_erc20_fundings( ) external
    {
        uint256 amount_eth           =  100 ether;
        uint256 amount_erc20         =  120 ether;
        uint256 user_token1_before   =  token1.balanceOf( user );

        vm.deal( user, 1_000 ether );
        uint256 user_eth_before  =  user.balance;

        ExecutionData memory execution_data  =  _create_native_create_position_execution_data( amount_eth, amount_erc20, 9 );
        _create_canonical_bond( execution_data );
        _advance_to_valid_execution_time( );

        vm.prank( user );
        ( BondStatus status, )  =  canonical_bond_route.execute_bond{ value: amount_eth }( execution_data );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "Bond should execute." );
        assertEq( user_eth_before - user.balance, amount_eth, "User should net-pay only native liquidity funding; stake is returned." );
        assertEq( user_token1_before - token1.balanceOf( user ), amount_erc20, "User should pay ERC20 liquidity funding." );
    }


    // ━━━━  TIMING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_canonical_bondroute_reverts_same_block_execution( ) external
    {
        ExecutionData memory execution_data  =  _create_exact_input_execution_data( 100 ether, 3 );
        _create_canonical_bond( execution_data );

        vm.expectRevert( SameBlockExecution.selector );
        vm.prank( user );
        canonical_bond_route.execute_bond( execution_data );
    }

    function test_canonical_bondroute_reverts_before_safeswap_seconds_delay( ) external
    {
        ExecutionData memory execution_data  =  _create_exact_input_execution_data( 100 ether, 4 );
        _create_canonical_bond( execution_data );

        vm.roll( block.number + MIN_BOND_EXECUTION_DELAY_IN_BLOCKS );
        vm.warp( block.timestamp + MIN_BOND_EXECUTION_DELAY_IN_SECONDS - 1 );

        vm.expectRevert(
            abi.encodeWithSelector(
                PossiblyBondFarming.selector,
                EXECUTION_TOO_SOON_SECONDS,
                bytes32(MIN_BOND_EXECUTION_DELAY_IN_SECONDS + 1)
            )
        );
        vm.prank( user );
        canonical_bond_route.execute_bond( execution_data );
    }

    function test_canonical_bondroute_retries_after_safeswap_seconds_delay( ) external
    {
        ExecutionData memory execution_data  =  _create_exact_input_execution_data( 100 ether, 5 );
        uint256 creation_timestamp           =  block.timestamp;

        _create_canonical_bond( execution_data );

        vm.roll( block.number + MIN_BOND_EXECUTION_DELAY_IN_BLOCKS );
        vm.warp( creation_timestamp + MIN_BOND_EXECUTION_DELAY_IN_SECONDS - 1 );

        vm.expectRevert(
            abi.encodeWithSelector(
                PossiblyBondFarming.selector,
                EXECUTION_TOO_SOON_SECONDS,
                bytes32(MIN_BOND_EXECUTION_DELAY_IN_SECONDS + 1)
            )
        );
        vm.prank( user );
        canonical_bond_route.execute_bond( execution_data );

        vm.warp( creation_timestamp + MIN_BOND_EXECUTION_DELAY_IN_SECONDS + 1 );

        vm.prank( user );
        ( BondStatus status, )  =  canonical_bond_route.execute_bond( execution_data );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "Bond should remain retryable and execute after seconds delay." );
    }


    // ━━━━  GRACEFUL SETTLEMENT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_canonical_bondroute_settles_unknown_selector_as_invalid_bond( ) external
    {
        ExecutionData memory execution_data  =  _create_unknown_selector_execution_data( 6 );
        bytes32 commitment_hash              =  HashLib.calc_commitment_hash( user, BONDROUTE_ADDRESS, execution_data );

        vm.prank( user );
        canonical_bond_route.create_bond( commitment_hash, execution_data.stake );
        _advance_to_valid_execution_time( );

        vm.prank( user );
        ( BondStatus status, bytes memory output )  =  canonical_bond_route.execute_bond( execution_data );

        assertEq( uint256(status), uint256(BondStatus.INVALID_BOND), "Unknown selector should settle as invalid bond." );
        assertEq( string(output), INVALID_PROTOCOL_OR_CALL, "Invalid-bond reason should identify unsupported protocol/call." );
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _create_exact_input_execution_data( uint256 amount_in, uint256 salt )
    internal returns ( ExecutionData memory execution_data )
    {
        pool_manager.set_mock_swap_amounts( -int128(uint128(amount_in)), 95 ether );

        CanonicalTokenAmount[] memory fundings  =  new CanonicalTokenAmount[](1);
        fundings[ 0 ]  =  CanonicalTokenAmount({ token: CanonicalIERC20(address(token0)), amount: amount_in });

        ExactInputSwapParams memory params  =  _create_exact_input_params( 90 ether );

        execution_data  =  ExecutionData({
            fundings: fundings,
            stake: CanonicalTokenAmount({ token: CanonicalIERC20(address(token0)), amount: amount_in / 100 }),
            salt: salt,
            protocol: CanonicalBondRouteProtected(address(hook)),
            call: _encode_exact_input_calldata( params )
        });
    }

    function _create_native_exact_input_execution_data( uint256 amount_in, uint256 salt )
    internal returns ( ExecutionData memory execution_data )
    {
        pool_manager.set_mock_swap_amounts( -int128(uint128(amount_in)), 95 ether );

        CanonicalTokenAmount[] memory fundings  =  new CanonicalTokenAmount[](1);
        fundings[ 0 ]  =  CanonicalTokenAmount({ token: CanonicalIERC20(address(0)), amount: amount_in });

        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token1,
            minimum_output_amount: 90 ether,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        execution_data  =  ExecutionData({
            fundings: fundings,
            stake: CanonicalTokenAmount({ token: CanonicalIERC20(address(0)), amount: amount_in / 100 }),
            salt: salt,
            protocol: CanonicalBondRouteProtected(address(hook)),
            call: _encode_exact_input_calldata( params )
        });
    }

    function _create_erc20_create_position_execution_data( uint256 amount0, uint256 amount1, uint256 salt )
    internal returns ( ExecutionData memory execution_data )
    {
        pool_manager.set_mock_liquidity_amounts( -int128(uint128(amount0)), -int128(uint128(amount1)) );

        CanonicalTokenAmount[] memory fundings  =  new CanonicalTokenAmount[](2);
        fundings[ 0 ]  =  CanonicalTokenAmount({ token: CanonicalIERC20(address(token0)), amount: amount0 });
        fundings[ 1 ]  =  CanonicalTokenAmount({ token: CanonicalIERC20(address(token1)), amount: amount1 });

        CreatePositionParams memory params  =  _create_create_position_params( );

        execution_data  =  ExecutionData({
            fundings: fundings,
            stake: CanonicalTokenAmount({ token: CanonicalIERC20(address(token0)), amount: ( amount0 + amount1 ) / 100 }),
            salt: salt,
            protocol: CanonicalBondRouteProtected(address(hook)),
            call: _encode_create_position_calldata( params )
        });
    }

    function _create_native_create_position_execution_data( uint256 amount_eth, uint256 amount_erc20, uint256 salt )
    internal returns ( ExecutionData memory execution_data )
    {
        pool_manager.set_mock_liquidity_amounts( -int128(uint128(amount_eth)), -int128(uint128(amount_erc20)) );

        CanonicalTokenAmount[] memory fundings  =  new CanonicalTokenAmount[](2);
        fundings[ 0 ]  =  CanonicalTokenAmount({ token: CanonicalIERC20(address(0)), amount: amount_eth });
        fundings[ 1 ]  =  CanonicalTokenAmount({ token: CanonicalIERC20(address(token1)), amount: amount_erc20 });

        // token0 sorts to the native currency (address(0) < token1), so minimum_deposited_a references native.
        CreatePositionParams memory params  =  CreatePositionParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            liquidity: 100 ether,
            sqrt_price_x96: SQRT_PRICE_1_1,
            minimum_deposited_a: TokenAmount({ token: IERC20(address(0)), amount: 0 }),
            minimum_deposited_b: TokenAmount({ token: token1, amount: 0 })
        });

        execution_data  =  ExecutionData({
            fundings: fundings,
            stake: CanonicalTokenAmount({ token: CanonicalIERC20(address(0)), amount: ( amount_eth + amount_erc20 ) / 100 }),
            salt: salt,
            protocol: CanonicalBondRouteProtected(address(hook)),
            call: _encode_create_position_calldata( params )
        });
    }

    function _create_unknown_selector_execution_data( uint256 salt )
    internal view returns ( ExecutionData memory execution_data )
    {
        CanonicalTokenAmount[] memory fundings  =  new CanonicalTokenAmount[](0);

        execution_data  =  ExecutionData({
            fundings: fundings,
            stake: CanonicalTokenAmount({ token: CanonicalIERC20(address(token0)), amount: 1 ether }),
            salt: salt,
            protocol: CanonicalBondRouteProtected(address(hook)),
            call: abi.encodeWithSelector( bytes4(0xdeadbeef) )
        });
    }

    function _create_canonical_bond( ExecutionData memory execution_data ) internal returns ( bytes32 commitment_hash )
    {
        commitment_hash  =  canonical_bond_route.__OFF_CHAIN__calc_commitment_hash( user, execution_data );

        vm.prank( user );
        canonical_bond_route.create_bond{ value: address(execution_data.stake.token) == address(0) ? execution_data.stake.amount : 0 }(
            commitment_hash,
            execution_data.stake
        );
    }

    function _advance_to_valid_execution_time( ) internal
    {
        vm.roll( block.number + MIN_BOND_EXECUTION_DELAY_IN_BLOCKS );
        vm.warp( block.timestamp + MIN_BOND_EXECUTION_DELAY_IN_SECONDS + 1 );
    }
}

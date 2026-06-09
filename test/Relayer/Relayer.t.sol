// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";

import { IRelayerTests } from "@test/Relayer/TestManifest.sol";
import { SafeSwapRealEnv } from "@test/helpers/SafeSwapRealEnv.t.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";

import {
    Relayer,
    SafeSwapGaslessBond,
    IBondRouteProtectedSigning,
    OnlyDelegatedExecution,
    UnexpectedNativeValue,
    WrongHelper,
    UnauthorizedRelayer,
    InvalidGaslessSignature,
    CreateDeadlineExpired,
    UnsupportedProtocol,
    CommitmentMismatch,
    StakeMismatch,
    GaslessTypeHashMismatch,
    ActionStructHashMismatch,
    InvalidProtocolTypedStringPrefix
} from "@SafeSwapRelayer/Relayer.sol";

import { PoolInfo } from "@SafeSwapCommon/Types.sol";
import { ExactInputSwapParams } from "@SafeSwapRouter/libraries/ExactInputSwapLib.sol";
import { CreatePositionParams } from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";

import "@SafeSwapCommon/Definitions.sol";
import { ExecutionData } from "@BondRoute/Core.sol";
import { BondStatus } from "@BondRoute/Definitions.sol";
import { IBondRouteProtected, IERC20, TokenAmount } from "@BondRouteProtected/BondRouteProtected.sol";


/**
 * @notice Exposes the delegate's internal type-string splice so it can be unit-tested directly (the on-chain re-derivation
 *         is otherwise only reachable through a misbehaving in-allowlist protocol, which the real router/NFT never are).
 */
contract RelayerHarness is Relayer {

    constructor( address safe_swap_router, address safe_swap_nft ) Relayer( safe_swap_router, safe_swap_nft ) { }

    function exposed_calculate_gasless_type_hash( string memory protocol_typed_string ) external pure returns ( bytes32 )
    {
        return _calculate_gasless_type_hash( protocol_typed_string );
    }
}


/**
 * @title RelayerGaslessTest
 * @notice End-to-end tests for the EIP-7702 gasless delegate against the REAL SafeSwap router, NFT, hook, V4 pool, and the
 *         BondRoute singleton. The delegate's code is etched onto a user EOA (7702 simulation) and the relayer drives the
 *         two-phase flow — `create_bond_from_user_stake` then, past the reveal delay, `execute_bond_from_user` — exactly as
 *         a sponsored type-0x04 transaction would. The user authorizes everything with one off-chain `SafeSwapGaslessBond`
 *         signature; the happy path proves the off-chain digest matches the on-chain one and that funds flow to the user
 *         while the relayer is paid its signed fee. The revert suite covers every guard and validation error.
 * @dev Implements IRelayerTests from TestManifest.sol.
 */
contract RelayerGaslessTest is IRelayerTests, SafeSwapRealEnv {

    uint256 internal constant _EOA_PK   =  0xA11CE;
    address internal constant _RELAYER  =  address(0xBEEF);
    address internal constant _LP       =  address(0x11107);

    uint16  internal constant _BASE_FEE_BPS    =  30;
    uint8   internal constant _CAPTURE_PERCENT =  50;
    int24   internal constant _TICK_SPACING    =  60;
    uint160 internal constant _SQRT_PRICE_1_1  =  79228162514264337593543950336;

    bytes32 internal constant _EIP712_DOMAIN_TYPE_HASH  =  keccak256( "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)" );
    bytes32 internal constant _TOKEN_AMOUNT_TYPE_HASH   =  keccak256( "TokenAmount(address token,uint256 amount)" );
    string  internal constant _BONDROUTE_PREFIX         =  "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,";

    Relayer        internal _relayer_impl;
    RelayerHarness internal _harness;
    address        internal _eoa;

    TestERC20 internal _token_a;
    TestERC20 internal _token_b;

    uint256 private _salt;


    // ━━━━  SETUP  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function setUp( ) public
    {
        _setup_real_env( );
        _register_hook( _BASE_FEE_BPS, _CAPTURE_PERCENT );

        _token_a  =  _new_token( "Token A", "TKNA" );
        _token_b  =  _new_token( "Token B", "TKNB" );

        _eoa  =  vm.addr( _EOA_PK );

        // The user's own funds: stake + fundings + relayer fee are all pulled from the EOA, never from the relayer.
        _token_a.mint( _eoa, 10_000 ether );

        // Seed a deep pool so swaps quote and settle.
        _fund_and_approve( _LP, _token_a, 10_000_000 ether );
        _fund_and_approve( _LP, _token_b, 10_000_000 ether );
        _create_deep_position( );

        // Deploy the delegate, then etch its runtime (immutables baked in) onto the EOA to emulate the 7702 delegation.
        _relayer_impl  =  new Relayer( address(router), address(nft) );
        _harness       =  new RelayerHarness( address(router), address(nft) );
        vm.etch( _eoa, address(_relayer_impl).code );
    }


    // ━━━━  HAPPY PATH  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_gasless_create_and_execute_pays_user_and_relayer( ) external
    {
        uint256 start_block  =  block.number;
        uint256 start_ts     =  block.timestamp;

        uint256 amount_in   =  1_000 ether;
        TokenAmount memory fee  =  TokenAmount({ token: IERC20(address(_token_a)), amount: 5 ether });

        ExecutionData memory execution_data  =  _build_swap_execution_data( amount_in, 0 );
        ( SafeSwapGaslessBond memory intent, bytes32 gasless_type_hash, bytes32 action_struct_hash, bytes memory signature )
            =  _sign_gasless( execution_data, fee, start_ts + 1 hours );

        uint256 user_out_before    =  _token_b.balanceOf( _eoa );
        uint256 relayer_fee_before =  _token_a.balanceOf( _RELAYER );

        // Phase 1 — commit (relayer-submitted, runs as the EOA).
        vm.prank( _RELAYER );
        Relayer( payable(_eoa) ).create_bond_from_user_stake( intent, gasless_type_hash, action_struct_hash, signature );

        assertEq( _token_a.balanceOf( _RELAYER ) - relayer_fee_before, fee.amount, "relayer must be paid its signed fee at create." );

        // Phase 2 — reveal + execute past the delay.
        vm.roll( start_block + MIN_BOND_EXECUTION_DELAY_IN_BLOCKS + 1 );
        vm.warp( start_ts + MIN_BOND_EXECUTION_DELAY_IN_SECONDS + 1 );

        vm.prank( _RELAYER );
        ( uint8 status, )  =  Relayer( payable(_eoa) ).execute_bond_from_user( intent, gasless_type_hash, action_struct_hash, signature, execution_data );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "the gasless bond should execute." );
        assertGt( _token_b.balanceOf( _eoa ) - user_out_before, 0, "the swap output must flow to the user's EOA." );
    }


    // ━━━━  CONTEXT GUARDS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_create_reverts_on_direct_call( ) external
    {
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, bytes memory sig )  =  _dummy_intent( );

        // Called on the deployed artifact, address(this) == THIS_RELAYER_CONTRACT, so it must reject.
        vm.expectRevert( abi.encodeWithSelector( OnlyDelegatedExecution.selector, address(_relayer_impl) ) );
        _relayer_impl.create_bond_from_user_stake( intent, gth, ash, sig );
    }

    function test_execute_reverts_on_direct_call( ) external
    {
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, bytes memory sig )  =  _dummy_intent( );
        ExecutionData memory execution_data  =  _build_swap_execution_data( 1_000 ether, 0 );

        vm.expectRevert( abi.encodeWithSelector( OnlyDelegatedExecution.selector, address(_relayer_impl) ) );
        _relayer_impl.execute_bond_from_user( intent, gth, ash, sig, execution_data );
    }

    function test_create_reverts_on_native_value( ) external
    {
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, bytes memory sig )  =  _dummy_intent( );

        vm.deal( address(this), 1 ether );
        vm.expectRevert( abi.encodeWithSelector( UnexpectedNativeValue.selector, uint256(1) ) );
        Relayer( payable(_eoa) ).create_bond_from_user_stake{ value: 1 }( intent, gth, ash, sig );
    }

    function test_execute_reverts_on_native_value( ) external
    {
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, bytes memory sig )  =  _dummy_intent( );
        ExecutionData memory execution_data  =  _build_swap_execution_data( 1_000 ether, 0 );

        vm.deal( address(this), 1 ether );
        vm.expectRevert( abi.encodeWithSelector( UnexpectedNativeValue.selector, uint256(1) ) );
        Relayer( payable(_eoa) ).execute_bond_from_user{ value: 1 }( intent, gth, ash, sig, execution_data );
    }


    // ━━━━  AUTHORIZATION GUARDS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_reverts_on_wrong_helper( ) external
    {
        ExecutionData memory execution_data  =  _build_swap_execution_data( 1_000 ether, 0 );
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, bytes memory sig )
            =  _sign_gasless( execution_data, _no_fee( ), block.timestamp + 1 hours );

        intent.helper  =  address(0xDEAD);    // tamper after signing; the helper check fires before signature recovery.

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( WrongHelper.selector, address(0xDEAD), address(_relayer_impl) ) );
        Relayer( payable(_eoa) ).create_bond_from_user_stake( intent, gth, ash, sig );
    }

    function test_reverts_on_unauthorized_relayer( ) external
    {
        ExecutionData memory execution_data  =  _build_swap_execution_data( 1_000 ether, 0 );
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, bytes memory sig )
            =  _sign_gasless( execution_data, _no_fee( ), block.timestamp + 1 hours );

        // Submitted by anyone other than the signed relayer.
        vm.prank( address(0xC0FFEE) );
        vm.expectRevert( abi.encodeWithSelector( UnauthorizedRelayer.selector, address(0xC0FFEE), _RELAYER ) );
        Relayer( payable(_eoa) ).create_bond_from_user_stake( intent, gth, ash, sig );
    }

    function test_reverts_on_invalid_signature( ) external
    {
        ExecutionData memory execution_data  =  _build_swap_execution_data( 1_000 ether, 0 );
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, )
            =  _sign_gasless( execution_data, _no_fee( ), block.timestamp + 1 hours );

        // A signature from the wrong key recovers to someone other than the EOA.
        bytes memory bad_signature  =  _sign_digest( 0xB0B, _gasless_digest( intent, gth, ash ) );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( InvalidGaslessSignature.selector, vm.addr( 0xB0B ), _eoa ) );
        Relayer( payable(_eoa) ).create_bond_from_user_stake( intent, gth, ash, bad_signature );
    }

    function test_create_reverts_after_deadline( ) external
    {
        ExecutionData memory execution_data  =  _build_swap_execution_data( 1_000 ether, 0 );
        uint256 deadline  =  block.timestamp - 1;
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, bytes memory sig )
            =  _sign_gasless( execution_data, _no_fee( ), deadline );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( CreateDeadlineExpired.selector, deadline, block.timestamp ) );
        Relayer( payable(_eoa) ).create_bond_from_user_stake( intent, gth, ash, sig );
    }


    // ━━━━  EXECUTION-DATA BINDING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_execute_reverts_on_unsupported_protocol( ) external
    {
        // A self-consistent signed intent paired with execution data targeting a protocol outside the allowlist.
        ExecutionData memory execution_data  =  _build_swap_execution_data( 1_000 ether, 0 );
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, bytes memory sig )
            =  _sign_gasless( execution_data, _no_fee( ), block.timestamp + 1 hours );

        execution_data.protocol  =  IBondRouteProtected( address(0xBAD) );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( UnsupportedProtocol.selector, address(0xBAD), address(router), address(nft) ) );
        Relayer( payable(_eoa) ).execute_bond_from_user( intent, gth, ash, sig, execution_data );
    }

    function test_execute_reverts_on_commitment_mismatch( ) external
    {
        ExecutionData memory execution_data  =  _build_swap_execution_data( 1_000 ether, 0 );
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, )
            =  _sign_gasless( execution_data, _no_fee( ), block.timestamp + 1 hours );

        bytes32 wrong_commitment  =  bytes32( uint256(1) );
        intent.commitment_hash    =  wrong_commitment;
        bytes memory sig          =  _sign_digest( _EOA_PK, _gasless_digest( intent, gth, ash ) );

        bytes32 actual  =  bond_route.__OFF_CHAIN__calc_commitment_hash( _eoa, execution_data );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( CommitmentMismatch.selector, wrong_commitment, actual ) );
        Relayer( payable(_eoa) ).execute_bond_from_user( intent, gth, ash, sig, execution_data );
    }

    function test_execute_reverts_on_stake_mismatch( ) external
    {
        ExecutionData memory execution_data  =  _build_swap_execution_data( 1_000 ether, 0 );
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, )
            =  _sign_gasless( execution_data, _no_fee( ), block.timestamp + 1 hours );

        // Keep the commitment correct but sign a stake that disagrees with the revealed execution data.
        TokenAmount memory wrong_stake  =  TokenAmount({ token: IERC20(address(_token_b)), amount: 1 ether });
        intent.stake      =  wrong_stake;
        bytes memory sig  =  _sign_digest( _EOA_PK, _gasless_digest( intent, gth, ash ) );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector(
            StakeMismatch.selector,
            address(wrong_stake.token), wrong_stake.amount,
            address(execution_data.stake.token), execution_data.stake.amount
        ) );
        Relayer( payable(_eoa) ).execute_bond_from_user( intent, gth, ash, sig, execution_data );
    }

    function test_execute_reverts_on_gasless_type_hash_mismatch( ) external
    {
        ExecutionData memory execution_data  =  _build_swap_execution_data( 1_000 ether, 0 );
        ( SafeSwapGaslessBond memory intent, bytes32 real_gth, bytes32 ash, )
            =  _sign_gasless( execution_data, _no_fee( ), block.timestamp + 1 hours );

        bytes32 wrong_gth  =  bytes32( uint256(real_gth) ^ 1 );
        bytes memory sig   =  _sign_digest( _EOA_PK, _gasless_digest( intent, wrong_gth, ash ) );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( GaslessTypeHashMismatch.selector, real_gth, wrong_gth ) );
        Relayer( payable(_eoa) ).execute_bond_from_user( intent, wrong_gth, ash, sig, execution_data );
    }

    function test_execute_reverts_on_action_struct_hash_mismatch( ) external
    {
        ExecutionData memory execution_data  =  _build_swap_execution_data( 1_000 ether, 0 );
        ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 real_ash, )
            =  _sign_gasless( execution_data, _no_fee( ), block.timestamp + 1 hours );

        bytes32 wrong_ash  =  bytes32( uint256(real_ash) ^ 1 );
        bytes memory sig   =  _sign_digest( _EOA_PK, _gasless_digest( intent, gth, wrong_ash ) );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( ActionStructHashMismatch.selector, real_ash, wrong_ash ) );
        Relayer( payable(_eoa) ).execute_bond_from_user( intent, gth, wrong_ash, sig, execution_data );
    }


    // ━━━━  TYPE-STRING SPLICE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_splice_builds_expected_gasless_type_hash( ) external view
    {
        string memory protocol_string  =  string.concat( _BONDROUTE_PREFIX, "Foo bar)Foo(uint256 x)TokenAmount(address token,uint256 amount)" );

        bytes32 got       =  _harness.exposed_calculate_gasless_type_hash( protocol_string );
        bytes32 expected  =  keccak256( bytes(
            "SafeSwapGaslessBond(address helper,address relayer,TokenAmount relayer_fee,TokenAmount stake,uint256 create_deadline,bytes32 commitment_hash,Foo bar)Foo(uint256 x)TokenAmount(address token,uint256 amount)"
        ) );

        assertEq( got, expected, "the splice must re-parent the action tail under the SafeSwapGaslessBond prefix." );
    }

    function test_splice_reverts_on_bad_prefix( ) external
    {
        string memory bad  =  "WrongRoot(uint256 x)";

        vm.expectRevert( abi.encodeWithSelector(
            InvalidProtocolTypedStringPrefix.selector,
            keccak256( bytes(_BONDROUTE_PREFIX) ),
            keccak256( bytes(bad) )
        ) );
        _harness.exposed_calculate_gasless_type_hash( bad );
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// @dev Build a real exact-input swap `ExecutionData` owned by, funded by, and staked by the user's EOA.
    function _build_swap_execution_data( uint256 amount_in, uint256 minimum_output_amount ) internal returns ( ExecutionData memory execution_data )
    {
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_in:              IERC20(address(_token_a)),
            input_amount:          amount_in,
            token_out:             IERC20(address(_token_b)),
            minimum_output_amount: minimum_output_amount,
            pool_info:             _pool_info( )
        });

        TokenAmount[] memory fundings  =  new TokenAmount[](1);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: amount_in });

        execution_data  =  ExecutionData({
            fundings: fundings,
            stake:    TokenAmount({ token: IERC20(address(_token_a)), amount: amount_in / 100 }),
            salt:     _salt++,
            protocol: IBondRouteProtected( address(router) ),
            call:     abi.encodeCall( router.bonded_swap_exact_input, ( params ) )
        });
    }

    /// @dev Assemble and sign a fully consistent `SafeSwapGaslessBond` intent for `execution_data` (the real signing path).
    function _sign_gasless(
        ExecutionData memory execution_data,
        TokenAmount memory relayer_fee,
        uint256 create_deadline
    ) internal view returns ( SafeSwapGaslessBond memory intent, bytes32 gasless_type_hash, bytes32 action_struct_hash, bytes memory signature )
    {
        ( string memory typed_string, bytes32 struct_hash, )  =  IBondRouteProtectedSigning( address(execution_data.protocol) ).BondRoute_get_signing_info( execution_data.call );

        action_struct_hash  =  struct_hash;
        gasless_type_hash   =  _harness.exposed_calculate_gasless_type_hash( typed_string );

        intent  =  SafeSwapGaslessBond({
            helper:          address(_relayer_impl),
            relayer:         _RELAYER,
            relayer_fee:     relayer_fee,
            stake:           execution_data.stake,
            create_deadline: create_deadline,
            commitment_hash: bond_route.__OFF_CHAIN__calc_commitment_hash( _eoa, execution_data )
        });

        signature  =  _sign_digest( _EOA_PK, _gasless_digest( intent, gasless_type_hash, action_struct_hash ) );
    }

    /// @dev The EIP-712 digest the EOA signs — domain `verifyingContract` is the EOA itself, as the delegate rebuilds it.
    function _gasless_digest( SafeSwapGaslessBond memory intent, bytes32 gasless_type_hash, bytes32 action_struct_hash ) internal view returns ( bytes32 )
    {
        bytes32 domain_separator  =  keccak256( abi.encode(
            _EIP712_DOMAIN_TYPE_HASH,
            keccak256( bytes("SafeSwap Gasless") ),
            keccak256( bytes("1") ),
            block.chainid,
            _eoa
        ) );

        bytes32 struct_hash  =  keccak256( abi.encode(
            gasless_type_hash,
            intent.helper,
            intent.relayer,
            _hash_token_amount( intent.relayer_fee ),
            _hash_token_amount( intent.stake ),
            intent.create_deadline,
            intent.commitment_hash,
            action_struct_hash
        ) );

        return keccak256( abi.encodePacked( hex"1901", domain_separator, struct_hash ) );
    }

    function _hash_token_amount( TokenAmount memory token_amount ) internal pure returns ( bytes32 )
    {
        return keccak256( abi.encode( _TOKEN_AMOUNT_TYPE_HASH, address(token_amount.token), token_amount.amount ) );
    }

    function _sign_digest( uint256 private_key, bytes32 digest ) internal pure returns ( bytes memory )
    {
        ( uint8 v, bytes32 r, bytes32 s )  =  vm.sign( private_key, digest );
        return abi.encodePacked( r, s, v );
    }

    function _dummy_intent( ) internal view returns ( SafeSwapGaslessBond memory intent, bytes32 gth, bytes32 ash, bytes memory sig )
    {
        intent  =  SafeSwapGaslessBond({
            helper:          address(_relayer_impl),
            relayer:         _RELAYER,
            relayer_fee:     _no_fee( ),
            stake:           TokenAmount({ token: IERC20(address(_token_a)), amount: 0 }),
            create_deadline: block.timestamp + 1 hours,
            commitment_hash: bytes32(0)
        });
        gth  =  bytes32(0);
        ash  =  bytes32(0);
        sig  =  new bytes(65);
    }

    function _no_fee( ) internal view returns ( TokenAmount memory )
    {
        return TokenAmount({ token: IERC20(address(_token_a)), amount: 0 });
    }

    function _pool_info( ) internal pure returns ( PoolInfo memory )
    {
        return PoolInfo({ base_fee_bps: _BASE_FEE_BPS, rebate_percent: _CAPTURE_PERCENT, tick_spacing: _TICK_SPACING });
    }

    function _create_deep_position( ) internal
    {
        CreatePositionParams memory params  =  CreatePositionParams({
            pool_info:            _pool_info( ),
            sqrt_price_lower_x96: TickMath.getSqrtPriceAtTick( -6000 ),
            sqrt_price_upper_x96: TickMath.getSqrtPriceAtTick( 6000 ),
            liquidity:            100_000 ether,
            sqrt_price_x96:       _SQRT_PRICE_1_1,
            maximum_deposit_a:    TokenAmount({ token: IERC20(address(_token_a)), amount: 1_000_000 ether }),
            minimum_deposit_a:    0,
            maximum_deposit_b:    TokenAmount({ token: IERC20(address(_token_b)), amount: 1_000_000 ether }),
            minimum_deposit_b:    0
        });

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_b)), amount: 1_000_000 ether });
        fundings[1]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: 1_000_000 ether });

        IERC20 token0  =  address(_token_a) < address(_token_b)  ?  IERC20(address(_token_a))  :  IERC20(address(_token_b));

        _create_and_execute_bond(
            _LP,
            IBondRouteProtected( address(nft) ),
            abi.encodeCall( nft.bonded_create_position, ( params ) ),
            TokenAmount({ token: token0, amount: 50_000 ether }),
            fundings
        );
    }
}

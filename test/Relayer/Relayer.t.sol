// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";

import { IRelayerTests } from "@test/Relayer/TestManifest.sol";
import { SafeSwapRealEnv } from "@test/helpers/SafeSwapRealEnv.t.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";

import {
    SafeSwap7702Delegate,
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
} from "@SafeSwapRelayer/SafeSwap7702Delegate.sol";

import { PoolInfo } from "@SafeSwapCommon/Types.sol";
import { ExactInputSwapParams } from "@SafeSwapRouter/libraries/ExactInputSwapLib.sol";
import { CreatePositionParams } from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";

import "@SafeSwapCommon/Definitions.sol";
import { ExecutionData } from "@BondRoute/Core.sol";
import { BondStatus } from "@BondRoute/Definitions.sol";
import { BONDROUTE_ADDRESS, IBondRouteProtected, IERC20, NATIVE_TOKEN, TokenAmount } from "@BondRouteProtected/BondRouteProtected.sol";


/// @dev The four pieces the relayer submits, grouped so tests carry one local (and avoid via-IR stack-too-deep).
struct Signed {
    SafeSwapGaslessBond intent;
    bytes32             gasless_type_hash;
    bytes32             action_struct_hash;
    bytes               signature;
}


/**
 * @notice Exposes the delegate's internal type-string splice so it can be unit-tested directly (the on-chain re-derivation
 *         is otherwise only reachable through a misbehaving in-allowlist protocol, which the real router/NFT never are).
 */
contract SafeSwap7702DelegateHarness is SafeSwap7702Delegate {

    function exposed_calculate_gasless_type_hash( string memory protocol_typed_string ) external pure returns ( bytes32 )
    {
        return _calculate_gasless_type_hash( protocol_typed_string );
    }
}


/**
 * @title RelayerGaslessTest
 * @notice End-to-end tests for the EIP-7702 gasless delegate against the REAL SafeSwap router, NFT, hook, V4 pools, and the
 *         BondRoute singleton. The delegate's code is etched onto a user EOA (7702 simulation) and the relayer drives the
 *         two-phase flow — `create_bond_from_user_stake` then, past the reveal delay, `execute_bond_from_user` — exactly as a
 *         sponsored type-0x04 transaction would. The user authorizes everything with one off-chain `SafeSwapGaslessBond`
 *         signature and stakes / funds / pays the relayer from their own EOA balance. Covers the happy path, the relayer-fee
 *         accounting, the native paths (fee / stake / funding), every guard and validation revert, and the type-string splice.
 * @dev Implements IRelayerTests from TestManifest.sol.
 */
contract RelayerGaslessTest is IRelayerTests, SafeSwapRealEnv {

    uint256 internal constant _EOA_PK    =  0xA11CE;
    address internal constant _RELAYER   =  address(0xBEEF);
    address internal constant _STRANGER  =  address(0xC0FFEE);
    address internal constant _LP        =  address(0x11107);

    uint16  internal constant _BASE_FEE_BPS    =  30;
    uint8   internal constant _CAPTURE_PERCENT =  50;
    int24   internal constant _TICK_SPACING    =  60;
    uint160 internal constant _SQRT_PRICE_1_1  =  79228162514264337593543950336;

    bytes32 internal constant _EIP712_DOMAIN_TYPE_HASH  =  keccak256( "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)" );
    bytes32 internal constant _TOKEN_AMOUNT_TYPE_HASH   =  keccak256( "TokenAmount(address token,uint256 amount)" );
    string  internal constant _BONDROUTE_PREFIX         =  "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,";

    SafeSwap7702Delegate        internal _delegate;
    SafeSwap7702DelegateHarness internal _harness;
    address                     internal _eoa;

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
        _token_b.mint( _eoa, 10_000 ether );

        // Seed a deep token_a/token_b pool so swaps quote and settle.
        _fund_and_approve( _LP, _token_a, 10_000_000 ether );
        _fund_and_approve( _LP, _token_b, 10_000_000 ether );
        _create_deep_position( IERC20(address(_token_a)), IERC20(address(_token_b)) );

        // The delegate resolves the router / NFT from ChainConfig (0-arg ctor); etch its runtime (immutables baked in) onto
        // the EOA to emulate the 7702 delegation.
        _delegate  =  new SafeSwap7702Delegate( );
        _harness   =  new SafeSwap7702DelegateHarness( );
        vm.etch( _eoa, address(_delegate).code );
    }


    // ━━━━  HAPPY PATH  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_gasless_create_and_execute_pays_user_and_relayer( ) external
    {
        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );
        Signed memory s          =  _sign( ed, _fee( IERC20(address(_token_a)), 5 ether ) );

        uint256 user_out_before  =  _token_b.balanceOf( _eoa );

        uint8 status  =  _commit_wait_execute( s, ed );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "the gasless bond should execute." );
        assertGt( _token_b.balanceOf( _eoa ) - user_out_before, 0, "the swap output must flow to the user's EOA." );
    }


    // ━━━━  RELAYER FEE ACCOUNTING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_relayer_fee_paid_once_after_create( ) external
    {
        TokenAmount memory fee  =  _fee( IERC20(address(_token_a)), 5 ether );

        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );
        Signed memory s          =  _sign( ed, fee );

        uint256 fee_before  =  _token_a.balanceOf( _RELAYER );
        _commit_wait_execute( s, ed );

        // Across both phases the relayer's only receipt is the fee, paid once at commit (execute pays nothing more).
        assertEq( _token_a.balanceOf( _RELAYER ) - fee_before, fee.amount, "relayer must be paid exactly its fee, exactly once." );
    }

    function test_relayer_fee_not_paid_when_create_reverts( ) external
    {
        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );
        Signed memory s          =  _sign( ed, _fee( IERC20(address(_token_a)), 5 ether ) );

        _create( s );
        uint256 fee_after_first  =  _token_a.balanceOf( _RELAYER );

        // A second commit of the same bond reverts inside BondRoute (BondAlreadyExists); the whole tx — including the fee
        // payment that precedes `create_bond` — must roll back atomically, so the relayer is not paid twice.
        vm.prank( _RELAYER );
        vm.expectRevert( );
        _delegate_at_eoa( ).create_bond_from_user_stake( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature );

        assertEq( _token_a.balanceOf( _RELAYER ), fee_after_first, "a reverted commit must not pay the relayer fee." );
    }

    function test_native_relayer_fee_paid( ) external
    {
        vm.deal( _eoa, 1 ether );
        TokenAmount memory fee  =  _fee( NATIVE_TOKEN, 0.1 ether );

        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );
        Signed memory s          =  _sign( ed, fee );

        uint256 fee_before  =  _RELAYER.balance;
        _create( s );

        assertEq( _RELAYER.balance - fee_before, fee.amount, "a native relayer fee must be paid from the EOA's own balance." );
    }


    // ━━━━  NATIVE STAKE / FUNDING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_native_stake_from_eoa_balance( ) external
    {
        // Commit-phase focus: the delegate forwards a NATIVE stake from the EOA's own balance into BondRoute via
        // `create_bond{ value: ... }`. (Only the commit is exercised here; the native funding/execute path is `#14`.)
        vm.deal( _eoa, 1 ether );

        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _fee( NATIVE_TOKEN, 0.5 ether ) );
        Signed memory s          =  _sign( ed, _no_fee( ) );

        uint256 bondroute_native_before  =  BONDROUTE_ADDRESS.balance;
        _create( s );

        assertEq( BONDROUTE_ADDRESS.balance - bondroute_native_before, 0.5 ether, "native stake must be posted from the delegated EOA's balance." );
    }

    function test_native_funding_execute_works( ) external
    {
        // A native-INPUT swap on a native/token_b pool: the delegate pays the native funding from the EOA's own balance via
        // `{ value: ... }` at execute, with the relayer attaching nothing — the capability the old `execute_bond_as` lacked.
        _create_deep_position( NATIVE_TOKEN, IERC20(address(_token_b)) );
        vm.deal( _eoa, 1_100 ether );

        // The swap requires the stake token to match its input token, so a native-input swap stakes native too — both the
        // stake and the funding are then paid from the EOA's own native balance.
        ExecutionData memory ed  =  _swap( NATIVE_TOKEN, IERC20(address(_token_b)), 1_000 ether, TokenAmount({ token: NATIVE_TOKEN, amount: 10 ether }) );
        Signed memory s          =  _sign( ed, _no_fee( ) );

        uint256 user_out_before  =  _token_b.balanceOf( _eoa );
        uint8 status             =  _commit_wait_execute( s, ed );

        assertEq( uint256(status), uint256(BondStatus.EXECUTED), "a native-input gasless swap should execute." );
        assertGt( _token_b.balanceOf( _eoa ) - user_out_before, 0, "the native-input swap output must flow to the user's EOA." );
    }


    // ━━━━  CONTEXT GUARDS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_create_reverts_on_direct_call( ) external
    {
        Signed memory s  =  _dummy( );

        // Called on the deployed artifact, address(this) == THIS_DELEGATE, so it must reject.
        vm.expectRevert( abi.encodeWithSelector( OnlyDelegatedExecution.selector, address(_delegate) ) );
        _delegate.create_bond_from_user_stake( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature );
    }

    function test_execute_reverts_on_direct_call( ) external
    {
        Signed memory s          =  _dummy( );
        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );

        vm.expectRevert( abi.encodeWithSelector( OnlyDelegatedExecution.selector, address(_delegate) ) );
        _delegate.execute_bond_from_user( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature, ed );
    }

    function test_create_reverts_on_native_value( ) external
    {
        Signed memory s  =  _dummy( );

        vm.deal( address(this), 1 ether );
        vm.expectRevert( abi.encodeWithSelector( UnexpectedNativeValue.selector, uint256(1) ) );
        _delegate_at_eoa( ).create_bond_from_user_stake{ value: 1 }( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature );
    }

    function test_execute_reverts_on_native_value( ) external
    {
        Signed memory s          =  _dummy( );
        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );

        vm.deal( address(this), 1 ether );
        vm.expectRevert( abi.encodeWithSelector( UnexpectedNativeValue.selector, uint256(1) ) );
        _delegate_at_eoa( ).execute_bond_from_user{ value: 1 }( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature, ed );
    }


    // ━━━━  AUTHORIZATION GUARDS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_reverts_on_wrong_helper( ) external
    {
        Signed memory s  =  _signed_default( );

        s.intent.helper  =  address(0xDEAD);    // tamper after signing; the helper check fires before signature recovery.

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( WrongHelper.selector, address(0xDEAD), address(_delegate) ) );
        _delegate_at_eoa( ).create_bond_from_user_stake( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature );
    }

    function test_reverts_on_unauthorized_relayer( ) external
    {
        Signed memory s  =  _signed_default( );

        vm.prank( _STRANGER );
        vm.expectRevert( abi.encodeWithSelector( UnauthorizedRelayer.selector, _STRANGER, _RELAYER ) );
        _delegate_at_eoa( ).create_bond_from_user_stake( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature );
    }

    function test_reverts_on_invalid_signature( ) external
    {
        Signed memory s  =  _signed_default( );

        // A signature from the wrong key recovers to someone other than the EOA.
        s.signature  =  _sign_digest( 0xB0B, _digest( s ) );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( InvalidGaslessSignature.selector, vm.addr( 0xB0B ), _eoa ) );
        _delegate_at_eoa( ).create_bond_from_user_stake( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature );
    }

    function test_create_reverts_after_deadline( ) external
    {
        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );
        Signed memory s          =  _sign_with_deadline( ed, _no_fee( ), block.timestamp - 1 );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( CreateDeadlineExpired.selector, s.intent.create_deadline, block.timestamp ) );
        _delegate_at_eoa( ).create_bond_from_user_stake( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature );
    }


    // ━━━━  EXECUTION-DATA BINDING  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_execute_reverts_on_unsupported_protocol( ) external
    {
        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );
        Signed memory s          =  _sign( ed, _no_fee( ) );

        ed.protocol  =  IBondRouteProtected( address(0xBAD) );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( UnsupportedProtocol.selector, address(0xBAD), address(router), address(nft) ) );
        _delegate_at_eoa( ).execute_bond_from_user( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature, ed );
    }

    function test_execute_reverts_on_commitment_mismatch( ) external
    {
        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );
        Signed memory s          =  _sign( ed, _no_fee( ) );

        bytes32 actual  =  s.intent.commitment_hash;
        s.intent.commitment_hash  =  bytes32( uint256(1) );
        _resign( s );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( CommitmentMismatch.selector, bytes32( uint256(1) ), actual ) );
        _delegate_at_eoa( ).execute_bond_from_user( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature, ed );
    }

    function test_execute_reverts_on_stake_mismatch( ) external
    {
        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );
        Signed memory s          =  _sign( ed, _no_fee( ) );

        // Keep the commitment correct but sign a stake that disagrees with the revealed execution data.
        TokenAmount memory wrong  =  TokenAmount({ token: IERC20(address(_token_b)), amount: 1 ether });
        s.intent.stake  =  wrong;
        _resign( s );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector(
            StakeMismatch.selector,
            address(wrong.token), wrong.amount,
            address(ed.stake.token), ed.stake.amount
        ) );
        _delegate_at_eoa( ).execute_bond_from_user( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature, ed );
    }

    function test_execute_reverts_on_gasless_type_hash_mismatch( ) external
    {
        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );
        Signed memory s          =  _sign( ed, _no_fee( ) );

        bytes32 real_gth  =  s.gasless_type_hash;
        s.gasless_type_hash  =  bytes32( uint256(real_gth) ^ 1 );
        _resign( s );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( GaslessTypeHashMismatch.selector, real_gth, s.gasless_type_hash ) );
        _delegate_at_eoa( ).execute_bond_from_user( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature, ed );
    }

    function test_execute_reverts_on_action_struct_hash_mismatch( ) external
    {
        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );
        Signed memory s          =  _sign( ed, _no_fee( ) );

        bytes32 real_ash  =  s.action_struct_hash;
        s.action_struct_hash  =  bytes32( uint256(real_ash) ^ 1 );
        _resign( s );

        vm.prank( _RELAYER );
        vm.expectRevert( abi.encodeWithSelector( ActionStructHashMismatch.selector, real_ash, s.action_struct_hash ) );
        _delegate_at_eoa( ).execute_bond_from_user( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature, ed );
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

    function test_splice_reverts_on_malformed_token_amount( ) external
    {
        // A protocol string whose leading TokenAmount definition has been tampered fails the exact-prefix check, so a
        // malformed TokenAmount can never be re-parented into a signed type.
        string memory malformed  =  "ExecuteBondAs(EvilAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,Foo bar)Foo(uint256 x)";

        vm.expectRevert( abi.encodeWithSelector(
            InvalidProtocolTypedStringPrefix.selector,
            keccak256( bytes(_BONDROUTE_PREFIX) ),
            keccak256( bytes(malformed) )
        ) );
        _harness.exposed_calculate_gasless_type_hash( malformed );
    }


    // ━━━━  CALL HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// @dev The delegate's entrypoints invoked AS the user's EOA (the etched 7702 code).
    function _delegate_at_eoa( ) internal view returns ( SafeSwap7702Delegate )
    {
        return SafeSwap7702Delegate( payable(_eoa) );
    }

    function _create( Signed memory s ) internal
    {
        vm.prank( _RELAYER );
        _delegate_at_eoa( ).create_bond_from_user_stake( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature );
    }

    function _execute( Signed memory s, ExecutionData memory ed ) internal returns ( uint8 status )
    {
        vm.prank( _RELAYER );
        ( status, )  =  _delegate_at_eoa( ).execute_bond_from_user( s.intent, s.gasless_type_hash, s.action_struct_hash, s.signature, ed );
    }

    /// @dev Commit, advance past the reveal delay, and execute — the full sponsored lifecycle.
    function _commit_wait_execute( Signed memory s, ExecutionData memory ed ) internal returns ( uint8 status )
    {
        uint256 start_block  =  block.number;
        uint256 start_ts     =  block.timestamp;

        _create( s );

        vm.roll( start_block + MIN_BOND_EXECUTION_DELAY_IN_BLOCKS + 1 );
        vm.warp( start_ts + MIN_BOND_EXECUTION_DELAY_IN_SECONDS + 1 );

        status  =  _execute( s, ed );
    }


    // ━━━━  SIGNING HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _sign( ExecutionData memory ed, TokenAmount memory fee ) internal view returns ( Signed memory )
    {
        return _sign_with_deadline( ed, fee, block.timestamp + 1 hours );
    }

    /// @dev Assemble and sign a fully consistent `SafeSwapGaslessBond` intent for `ed` (the real signing path).
    function _sign_with_deadline( ExecutionData memory ed, TokenAmount memory fee, uint256 create_deadline ) internal view returns ( Signed memory s )
    {
        ( string memory typed_string, bytes32 struct_hash, )  =  IBondRouteProtectedSigning( address(ed.protocol) ).BondRoute_get_signing_info( ed.call );

        s.action_struct_hash  =  struct_hash;
        s.gasless_type_hash   =  _harness.exposed_calculate_gasless_type_hash( typed_string );
        s.intent  =  SafeSwapGaslessBond({
            helper:          address(_delegate),
            relayer:         _RELAYER,
            relayer_fee:     fee,
            stake:           ed.stake,
            create_deadline: create_deadline,
            commitment_hash: bond_route.__OFF_CHAIN__calc_commitment_hash( _eoa, ed )
        });
        s.signature  =  _sign_digest( _EOA_PK, _digest( s ) );
    }

    function _signed_default( ) internal returns ( Signed memory )
    {
        ExecutionData memory ed  =  _swap( IERC20(address(_token_a)), IERC20(address(_token_b)), 1_000 ether, _token_a_stake( 1_000 ether ) );
        return _sign( ed, _no_fee( ) );
    }

    /// @dev Re-sign after mutating a field, so the signature stays valid for the (now-tampered) intent/hashes.
    function _resign( Signed memory s ) internal view
    {
        s.signature  =  _sign_digest( _EOA_PK, _digest( s ) );
    }

    /// @dev The EIP-712 digest the EOA signs — domain `verifyingContract` is the EOA itself, as the delegate rebuilds it.
    function _digest( Signed memory s ) internal view returns ( bytes32 )
    {
        bytes32 domain_separator  =  keccak256( abi.encode(
            _EIP712_DOMAIN_TYPE_HASH,
            keccak256( bytes("SafeSwap Gasless") ),
            keccak256( bytes("1") ),
            block.chainid,
            _eoa
        ) );

        bytes32 struct_hash  =  keccak256( abi.encode(
            s.gasless_type_hash,
            s.intent.helper,
            s.intent.relayer,
            _hash_token_amount( s.intent.relayer_fee ),
            _hash_token_amount( s.intent.stake ),
            s.intent.create_deadline,
            s.intent.commitment_hash,
            s.action_struct_hash
        ) );

        return keccak256( abi.encodePacked( hex"1901", domain_separator, struct_hash ) );
    }

    function _hash_token_amount( TokenAmount memory token_amount ) internal pure returns ( bytes32 )
    {
        return keccak256( abi.encode( _TOKEN_AMOUNT_TYPE_HASH, address(token_amount.token), token_amount.amount ) );
    }

    function _sign_digest( uint256 private_key, bytes32 digest ) internal pure returns ( bytes memory )
    {
        ( uint8 v, bytes32 r, bytes32 sig_s )  =  vm.sign( private_key, digest );
        return abi.encodePacked( r, sig_s, v );
    }

    /// @dev A throwaway intent for guards that fire before signature validation (direct-call, native-value).
    function _dummy( ) internal view returns ( Signed memory s )
    {
        s.intent  =  SafeSwapGaslessBond({
            helper:          address(_delegate),
            relayer:         _RELAYER,
            relayer_fee:     _no_fee( ),
            stake:           TokenAmount({ token: IERC20(address(_token_a)), amount: 0 }),
            create_deadline: block.timestamp + 1 hours,
            commitment_hash: bytes32(0)
        });
        s.signature  =  new bytes(65);
    }


    // ━━━━  FIXTURE HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// @dev Build a real exact-input swap `ExecutionData` owned by, funded by, and staked by the user's EOA.
    function _swap( IERC20 token_in, IERC20 token_out, uint256 amount_in, TokenAmount memory stake ) internal returns ( ExecutionData memory ed )
    {
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_in:              token_in,
            input_amount:          amount_in,
            token_out:             token_out,
            minimum_output_amount: 0,
            pool_info:             _pool_info( )
        });

        TokenAmount[] memory fundings  =  new TokenAmount[](1);
        fundings[0]  =  TokenAmount({ token: token_in, amount: amount_in });

        ed  =  ExecutionData({
            fundings: fundings,
            stake:    stake,
            salt:     _salt++,
            protocol: IBondRouteProtected( address(router) ),
            call:     abi.encodeCall( router.bonded_swap_exact_input, ( params ) )
        });
    }

    function _token_a_stake( uint256 amount_in ) internal view returns ( TokenAmount memory )
    {
        return TokenAmount({ token: IERC20(address(_token_a)), amount: amount_in / 100 });
    }

    function _token_b_stake( uint256 amount_in ) internal view returns ( TokenAmount memory )
    {
        return TokenAmount({ token: IERC20(address(_token_b)), amount: amount_in / 100 });
    }

    function _fee( IERC20 token, uint256 amount ) internal pure returns ( TokenAmount memory )
    {
        return TokenAmount({ token: token, amount: amount });
    }

    function _no_fee( ) internal view returns ( TokenAmount memory )
    {
        return TokenAmount({ token: IERC20(address(_token_a)), amount: 0 });
    }

    function _pool_info( ) internal pure returns ( PoolInfo memory )
    {
        return PoolInfo({ base_fee_bps: _BASE_FEE_BPS, rebate_percent: _CAPTURE_PERCENT, tick_spacing: _TICK_SPACING });
    }

    /// @dev Seed a deep position for the `token0 / token1` pool (funds the LP with native value for a native deposit leg).
    function _create_deep_position( IERC20 token0, IERC20 token1 ) internal
    {
        if(  address(token0) == address(NATIVE_TOKEN)  )  vm.deal( _LP, 1_100_000 ether );

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[0]  =  TokenAmount({ token: token0, amount: 1_000_000 ether });
        fundings[1]  =  TokenAmount({ token: token1, amount: 1_000_000 ether });

        _create_and_execute_bond(
            _LP,
            IBondRouteProtected( address(nft) ),
            abi.encodeCall( nft.bonded_create_position, ( _deep_position_params( token0, token1 ) ) ),
            TokenAmount({ token: token1, amount: 50_000 ether }),
            fundings
        );
    }

    function _deep_position_params( IERC20 token0, IERC20 token1 ) internal pure returns ( CreatePositionParams memory )
    {
        return CreatePositionParams({
            pool_info:            _pool_info( ),
            sqrt_price_lower_x96: TickMath.getSqrtPriceAtTick( -6000 ),
            sqrt_price_upper_x96: TickMath.getSqrtPriceAtTick( 6000 ),
            liquidity:            100_000 ether,
            sqrt_price_x96:       _SQRT_PRICE_1_1,
            maximum_deposit_a:    TokenAmount({ token: token0, amount: 1_000_000 ether }),
            minimum_deposit_a:    0,
            maximum_deposit_b:    TokenAmount({ token: token1, amount: 1_000_000 ether }),
            minimum_deposit_b:    0
        });
    }
}

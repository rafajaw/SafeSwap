// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ChainConfigTestHelper } from "@test/helpers/ChainConfigTestHelper.t.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";
import { SafeSwapTestHelper } from "@test/helpers/SafeSwapTestHelper.t.sol";
import {
    MockBondRouteForNft,
    MockSafeSwapNftPoolManager,
    MockSafeSwapNftRouter
} from "@test/mocks/SafeSwapNftMocks.t.sol";
import { TestERC20 } from "@test/helpers/TestERC20.t.sol";
import { Vm } from "forge-std/Vm.sol";
import "@SafeSwapCommon/Definitions.sol";
import { HookAddress } from "@SafeSwapCommon/HookAddress.sol";
import { OneSidedDepositMismatch } from "@SafeSwapCommon/SafeSwapCommon.sol";
import { SafeSwapNft, PoolInitializationPriceMismatch, PositionUnauthorized } from "@SafeSwapNft/SafeSwapNft.sol";
import { SafeSwapPositionDescriptor } from "@SafeSwapNft/SafeSwapPositionDescriptor.sol";
import { SafeSwapSigningDescriptor } from "@SafeSwapCommon/SafeSwapSigningDescriptor.sol";
import {
    AddPositionLiquidityParams,
    CollectFeesParams,
    CreatePositionParams,
    InvalidLiquidityModification,
    ModifyLiquidityParams,
    RemovePositionLiquidityParams
} from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";
import { PoolInfo, SafeSwapPositionInfo } from "@SafeSwapCommon/Types.sol";
import {
    BondConstraints,
    BondContext,
    BONDROUTE_ADDRESS,
    IERC20,
    NATIVE_TOKEN,
    TokenAmount,
    Unauthorized,
    UnsupportedCall
} from "@BondRouteProtected/BondRouteProtected.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";
import { Position } from "@UniswapV4Core/libraries/Position.sol";
import { FixedPoint128 } from "@UniswapV4Core/libraries/FixedPoint128.sol";


contract SafeSwapNftTest is ChainConfigTestHelper, SafeSwapTestHelper {
    using PoolIdLibrary for PoolKey;

    address internal constant _USER                 =  address(0xA11CE);
    address internal constant _ADDRESS_WITHOUT_CODE =  address(0xBEEF);
    uint160 internal constant _SQRT_PRICE_1_1       =  79228162514264337593543950336;

    MockSafeSwapNftPoolManager internal _pool_manager;
    MockSafeSwapNftRouter internal _router;
    TestERC20 internal _token_a;
    TestERC20 internal _token_b;
    SafeSwapNft internal _nft;
    address internal _hook;
    uint256 internal _minted_token_id;    // id of the most recent _execute_create_position mint (token ids are derived, not sequential)

    function setUp( )
    public
    {
        vm.chainId( 31_337 );
        vm.roll( 100 );
        vm.warp( _DEFAULT_CONFIG_TIMESTAMP + 1 days );

        _deploy_chain_config( );

        MockBondRouteForNft bond_route_mock  =  new MockBondRouteForNft();
        vm.etch( BONDROUTE_ADDRESS, address(bond_route_mock).code );

        _hook          =  _hook_address( 30, 50, HookAddress.REQUIRED_PERMISSIONS );
        _pool_manager  =  new MockSafeSwapNftPoolManager();
        _router        =  new MockSafeSwapNftRouter( _hook );
        _token_a       =  new TestERC20( "Token A", "TKNA", 18 );
        _token_b       =  new TestERC20( "Token B", "TKNB", 18 );

        // *FIDELITY*  -  Fundings live in the bond owner's wallet (real BondRoute pulls them via transferFrom), so mint to
        //                each address used as a BondContext.user in a funding-pulling path and approve BondRoute. Both _USER
        //                and this test contract act as bond owners (owner vs approved-operator add-liquidity paths).
        _mint_and_approve( _USER );
        _mint_and_approve( address(this) );

        _publish_config_address( POOL_MANAGER_KEY, address(_pool_manager) );
        _publish_config_address( SAFESWAP_ROUTER_KEY, address(_router) );
        _publish_config_address( SAFESWAP_POSITION_DESCRIPTOR_KEY, address(new SafeSwapPositionDescriptor()) );
        _publish_config_address( SAFESWAP_SIGNING_DESCRIPTOR_KEY, address(new SafeSwapSigningDescriptor( )) );

        _nft  =  new SafeSwapNft();
    }

    function _mint_and_approve( address account ) internal
    {
        _token_a.mint( account, 1_000_000 ether );
        _token_b.mint( account, 1_000_000 ether );

        vm.startPrank( account );
        _token_a.approve( BONDROUTE_ADDRESS, type(uint256).max );
        _token_b.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );
    }

    function test_constructor_reads_canonical_router_from_chain_config( )
    external  view
    {
        assertEq( _nft.SafeSwapRouter( ), address(_router), "constructor should read canonical router from ChainConfig." );
    }

    function test_constructor_reverts_when_router_has_no_code( )
    external
    {
        _publish_config_address( SAFESWAP_ROUTER_KEY, _ADDRESS_WITHOUT_CODE );

        vm.expectRevert( bytes("SafeSwapNft: Invalid router") );
        new SafeSwapNft();
    }

    function test_constructor_reverts_when_descriptor_has_no_code( )
    external
    {
        _publish_config_address( SAFESWAP_POSITION_DESCRIPTOR_KEY, _ADDRESS_WITHOUT_CODE );

        vm.expectRevert( bytes("SafeSwapNft: Invalid descriptor") );
        new SafeSwapNft();
    }

    function test_constructor_reverts_when_signing_descriptor_has_no_code( )
    external
    {
        _publish_config_address( SAFESWAP_SIGNING_DESCRIPTOR_KEY, _ADDRESS_WITHOUT_CODE );

        vm.expectRevert( bytes("SafeSwapNft: Invalid signing_descriptor") );
        new SafeSwapNft();
    }

    function test_constructor_uses_shared_pool_manager_from_chain_config( )
    external
    {
        PoolKey memory key  =  _pool_key();
        _seed_slot0( key, _SQRT_PRICE_1_1 );

        ( uint160 sqrt_price_x96, , , )  =  _nft_pool_slot0( key );

        assertEq( sqrt_price_x96, _SQRT_PRICE_1_1, "NFT should read slot0 through the PoolManager published by ChainConfig." );
    }

    function test_first_token_id_is_derived_not_sequential( )
    external
    {
        uint256 token_id  =  _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        assertEq( _nft.ownerOf( token_id ), _USER, "first minted LP token should be owned by the bonded user." );
        assertTrue( token_id != 1, "token id should be derived (hashed), not the sequential counter." );
        assertTrue( token_id != 0, "derived token id is never zero." );
        assertLt( token_id, 1 << 64, "derived token id keeps only the low 8 bytes." );
    }

    function test_inherits_bondroute_native_receive_for_native_fundings( )
    external
    {
        vm.deal( BONDROUTE_ADDRESS, 1 ether );

        vm.prank( BONDROUTE_ADDRESS );
        ( bool success, )  =  address(_nft).call{ value: 1 wei }( "" );

        assertTrue( success, "NFT should accept native transfers from BondRoute." );
    }

    function test_receive_reverts_on_unknown_direct_native_transfer( )
    external
    {
        vm.deal( address(this), 1 ether );

        ( bool success, bytes memory revert_data )  =  address(_nft).call{ value: 1 wei }( "" );

        assertFalse( success, "NFT should reject native transfers not sent by BondRoute." );
        assertEq( revert_data, abi.encodeWithSignature( "Error(string)", "BondRouteProtected: unknown native transfer" ), "Unexpected receive revert reason." );
    }

    function test_bondroute_selectors_are_only_position_lifecycle_functions( )
    external  view
    {
        bytes4[] memory selectors  =  _nft.BondRoute_get_protected_selectors( );

        assertEq( selectors.length, 4, "NFT should expose four protected lifecycle selectors." );
        assertEq( selectors[ 0 ], _nft.create_position.selector, "selector 0 should be create_position." );
        assertEq( selectors[ 1 ], _nft.add_liquidity.selector, "selector 1 should be add_liquidity." );
        assertEq( selectors[ 2 ], _nft.remove_liquidity.selector, "selector 2 should be remove_liquidity." );
        assertEq( selectors[ 3 ], _nft.collect_fees.selector, "selector 3 should be collect_fees." );
    }

    function test_bondroute_quote_reverts_for_unsupported_call( )
    external
    {
        TokenAmount[] memory fundings  =  new TokenAmount[](0);

        vm.expectRevert( UnsupportedCall.selector );
        _nft.BondRoute_quote_call( abi.encodeWithSelector( bytes4(0xDEADBEEF) ), IERC20(address(_token_a)), fundings );
    }

    function test_bondroute_quote_reverts_for_short_call_data( )
    external
    {
        TokenAmount[] memory fundings  =  new TokenAmount[](0);

        vm.expectRevert( UnsupportedCall.selector );
        _nft.BondRoute_quote_call( hex"010203", IERC20(address(_token_a)), fundings );
    }

    function test_bondroute_quote_create_requires_two_fundings( )
    external
    {
        TokenAmount[] memory fundings  =  new TokenAmount[](1);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: 100 ether });

        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, 0, int128(1 ether), 1 ) );
        _nft.BondRoute_quote_call( abi.encodeCall( _nft.create_position, (_create_params()) ), IERC20(address(_token_a)), fundings );
    }

    function test_bondroute_quote_create_computes_normalized_liquidity_stake( )
    external  view
    {
        TokenAmount[] memory fundings  =  _two_fundings( 100 ether, 100 ether );

        BondConstraints memory constraints  =  _nft.BondRoute_quote_call(
            abi.encodeCall( _nft.create_position, (_create_params()) ),
            IERC20(address(_token_a)),
            fundings
        );

        assertEq( address(constraints.min_stake.token), address(_token_a), "stake should use the preferred stake token when it is token0." );
        assertEq( constraints.min_stake.amount, 2 ether, "stake should be 1% of the normalized two-sided deposit value." );
        assertEq( constraints.min_fundings.length, 2, "create quote should preserve the two required fundings." );
    }

    function test_bondroute_quote_add_requires_two_fundings( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        TokenAmount[] memory fundings  =  new TokenAmount[](1);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: 100 ether });

        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, _minted_token_id, int128(1 ether), 1 ) );
        _nft.BondRoute_quote_call( abi.encodeCall( _nft.add_liquidity, (_add_params(_minted_token_id, 1 ether)) ), IERC20(address(_token_a)), fundings );
    }

    function test_bondroute_quote_add_computes_normalized_liquidity_stake_from_current_pool_price( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        BondConstraints memory constraints  =  _nft.BondRoute_quote_call(
            abi.encodeCall( _nft.add_liquidity, (_add_params(_minted_token_id, 1 ether)) ),
            IERC20(address(_token_a)),
            _two_fundings( 100 ether, 100 ether )
        );

        assertEq( address(constraints.min_stake.token), address(_token_a), "add quote should preserve preferred stake token." );
        assertEq( constraints.min_stake.amount, 2 ether, "add quote should use current pool price for normalized stake." );
        assertEq( constraints.min_fundings.length, 2, "add quote should preserve the required fundings." );
    }

    function test_bondroute_quote_remove_requires_no_fundings( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, _minted_token_id, -int128(1 ether), 2 ) );
        _nft.BondRoute_quote_call(
            abi.encodeCall( _nft.remove_liquidity, (_remove_params(_minted_token_id, 1 ether)) ),
            IERC20(address(_token_a)),
            _two_fundings( 100 ether, 100 ether )
        );
    }

    function test_bondroute_quote_remove_computes_stake_from_removed_liquidity_value( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        BondConstraints memory constraints  =  _nft.BondRoute_quote_call(
            abi.encodeCall( _nft.remove_liquidity, (_remove_params(_minted_token_id, 1 ether)) ),
            IERC20(address(_token_a)),
            new TokenAmount[](0)
        );

        assertEq( address(constraints.min_stake.token), address(_token_a), "remove quote should preserve preferred stake token." );
        assertGt( constraints.min_stake.amount, 0, "remove quote should stake against the removed liquidity value." );
        assertEq( constraints.min_fundings.length, 0, "remove quote should require no fundings." );
    }

    function test_bondroute_quote_collect_requires_no_fundings( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, _minted_token_id, int128(0), 2 ) );
        _nft.BondRoute_quote_call(
            abi.encodeCall( _nft.collect_fees, (_collect_params(_minted_token_id)) ),
            IERC20(address(_token_a)),
            _two_fundings( 100 ether, 100 ether )
        );
    }

    function test_bondroute_quote_collect_computes_stake_from_one_unit_liquidity_value( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        BondConstraints memory constraints  =  _nft.BondRoute_quote_call(
            abi.encodeCall( _nft.collect_fees, (_collect_params(_minted_token_id)) ),
            IERC20(address(_token_a)),
            new TokenAmount[](0)
        );

        assertEq( address(constraints.min_stake.token), address(_token_a), "collect quote should preserve preferred stake token." );
        assertEq( constraints.min_stake.amount, 1, "collect quote should stake at least one wei for one unit of liquidity." );
        assertEq( constraints.min_fundings.length, 0, "collect quote should require no fundings." );
    }

    function test_bondroute_signing_info_hashes_position_params_readably( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  _nft.BondRoute_get_signing_info(
            abi.encodeCall( _nft.add_liquidity, (_add_params(_minted_token_id, 1 ether)) )
        );

        assertGt( bytes(typed_string).length, 0, "signing info should expose a readable EIP-712 type string." );
        assertTrue( _contains( typed_string, "AddLiquidity(string Position,string Deposit,string Minimum,string Liquidity,string Pool,string Warning,address " ), "add signing info should use REFERENCE_2 role fields." );
        assertNotEq( struct_hash, bytes32(0), "signing info should hash the position params." );
        assertGt( token_amount_offset, 0, "signing info should include a TokenAmount offset." );
        _assert_token_amount_offset( typed_string, token_amount_offset );
    }

    function test_bondroute_signing_info_returns_create_position_offset( )
    external  view
    {
        ( string memory typed_string, bytes32 struct_hash, uint256 token_amount_offset )  =  _nft.BondRoute_get_signing_info(
            abi.encodeCall( _nft.create_position, (_create_params()) )
        );

        assertGt( bytes(typed_string).length, 0, "create signing info should return a readable EIP-712 type string." );
        assertTrue( _contains( typed_string, "CreatePosition(string Deposit,string Minimum,string Liquidity,string Range,string Price,string Pool,string Warning,address " ), "create signing info should use REFERENCE_2 role fields." );
        assertNotEq( struct_hash, bytes32(0), "create signing info should hash the signed params." );
        assertEq( token_amount_offset, 265, "create signing info should return the TokenAmount type offset." );
        _assert_token_amount_offset( typed_string, token_amount_offset );
    }

    function test_bondroute_signing_info_returns_add_liquidity_offset( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        ( string memory typed_string, , uint256 token_amount_offset )  =  _nft.BondRoute_get_signing_info(
            abi.encodeCall( _nft.add_liquidity, (_add_params(_minted_token_id, 1 ether)) )
        );

        assertEq( token_amount_offset, 249, "add-liquidity signing info should return the TokenAmount type offset." );
        _assert_token_amount_offset( typed_string, token_amount_offset );
    }

    function test_bondroute_signing_info_returns_remove_liquidity_offset( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        ( string memory typed_string, , uint256 token_amount_offset )  =  _nft.BondRoute_get_signing_info(
            abi.encodeCall( _nft.remove_liquidity, (_remove_params(_minted_token_id, 1 ether)) )
        );

        assertEq( token_amount_offset, 238, "remove-liquidity signing info should return the TokenAmount type offset." );
        _assert_token_amount_offset( typed_string, token_amount_offset );
    }

    function test_bondroute_signing_info_returns_collect_fees_offset( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        ( string memory typed_string, , uint256 token_amount_offset )  =  _nft.BondRoute_get_signing_info(
            abi.encodeCall( _nft.collect_fees, (_collect_params(_minted_token_id)) )
        );

        assertEq( token_amount_offset, 214, "collect-fees signing info should return the TokenAmount type offset." );
        _assert_token_amount_offset( typed_string, token_amount_offset );
    }

    function test_bondroute_signing_info_reverts_for_unsupported_call( )
    external
    {
        vm.expectRevert( UnsupportedCall.selector );
        _nft.BondRoute_get_signing_info( abi.encodeWithSelector( bytes4(0xDEADBEEF) ) );
    }

    function test_bondroute_signing_info_reverts_for_short_call_data( )
    external
    {
        vm.expectRevert( UnsupportedCall.selector );
        _nft.BondRoute_get_signing_info( hex"010203" );
    }

    function test_create_position_resolves_hook_from_router_registry( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        SafeSwapPositionInfo memory position_info  =  _nft.get_lp_position( _minted_token_id );

        assertEq( position_info.hook, _hook, "created position should store the hook resolved from the router registry." );
    }

    function test_create_position_builds_dynamic_fee_pool_key( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        assertEq( _pool_manager.last_initialize_fee( ), LPFeeLibrary.DYNAMIC_FEE_FLAG, "created SafeSwap pool should use v4 dynamic fee flag." );
    }

    function test_create_position_initializes_uninitialized_pool_at_signed_price( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        assertTrue( _pool_manager.initialize_called(), "create_position should initialize an uninitialized pool." );
        assertEq( _pool_manager.last_initialize_sqrt_price_x96(), _SQRT_PRICE_1_1, "pool should initialize at the BondRoute-signed price." );
    }

    function test_create_position_reverts_when_initialized_pool_price_differs_from_signed_price( )
    external
    {
        PoolKey memory key  =  _pool_key();
        _seed_slot0( key, _SQRT_PRICE_1_1 + 1 );

        vm.expectRevert();
        _execute_entry_point(
            abi.encodeCall( _nft.create_position, (_create_params()) ),
            _context( _two_fundings( 100 ether, 100 ether ) )
        );
    }

    function test_create_position_mints_token_id_to_bond_context_user( )
    external
    {
        uint256 token_id  =  _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        assertEq( _nft.ownerOf( token_id ), _USER, "created LP token should be minted to the BondRoute context user." );
    }

    function test_create_position_derives_distinct_token_id_per_mint( )
    external
    {
        uint256 first_id   =  _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );
        uint256 second_id  =  _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        assertTrue( first_id != second_id, "each mint should derive a distinct token id." );
        assertEq( _nft.ownerOf( first_id ), _USER, "first position should be owned by the user." );
        assertEq( _nft.ownerOf( second_id ), _USER, "second position should be owned by the user." );
    }

    function test_create_position_uses_token_id_as_v4_position_salt( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        assertEq( _pool_manager.last_modify_liquidity_salt( ), bytes32(_minted_token_id), "first NFT id should be used as v4 position salt." );
    }

    function test_create_position_stores_immutable_metadata( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        SafeSwapPositionInfo memory position_info  =  _nft.get_lp_position( _minted_token_id );

        assertEq( position_info.base_fee_bps, 30, "metadata should store base fee." );
        assertEq( position_info.rebate_percent, 50, "metadata should store rebate percent." );
        assertEq( position_info.tick_spacing, 60, "metadata should store tick spacing." );
        assertEq( position_info.tick_lower, -120, "metadata should store lower tick." );
        assertEq( position_info.tick_upper, 120, "metadata should store upper tick." );
    }

    function test_add_liquidity_requires_owner_or_approved_operator( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.expectRevert( abi.encodeWithSelector( PositionUnauthorized.selector, _minted_token_id, address(this), _USER ) );
        _execute_add_liquidity_as( address(this), _add_params( _minted_token_id,1 ether ), _two_fundings( 100 ether, 100 ether ) );
    }

    function test_add_liquidity_allows_approved_token_address( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.prank( _USER );
        _nft.approve( address(this), _minted_token_id );

        _execute_add_liquidity_as( address(this), _add_params( _minted_token_id,1 ether ), _two_fundings( 100 ether, 100 ether ) );

        assertTrue( _pool_manager.modify_liquidity_called(), "approved token address should be allowed to add liquidity." );
    }

    function test_add_liquidity_allows_approved_operator( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.prank( _USER );
        _nft.setApprovalForAll( address(this), true );

        _execute_add_liquidity_as( address(this), _add_params( _minted_token_id,1 ether ), _two_fundings( 100 ether, 100 ether ) );

        assertTrue( _pool_manager.modify_liquidity_called(), "approved operator should be allowed to add liquidity." );
    }

    function test_add_liquidity_uses_stored_position_metadata( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );
        _execute_add_liquidity_as( _USER, _add_params( _minted_token_id,1 ether ), _two_fundings( 100 ether, 100 ether ) );

        assertEq( _pool_manager.last_modify_liquidity_hook( ), _hook, "add liquidity should use the stored hook." );
        assertEq( _pool_manager.last_modify_liquidity_tick_spacing( ), 60, "add liquidity should use the stored tick spacing." );
    }

    function test_add_liquidity_uses_existing_token_id_as_v4_salt( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );
        _execute_add_liquidity_as( _USER, _add_params( _minted_token_id,1 ether ), _two_fundings( 100 ether, 100 ether ) );

        assertEq( _pool_manager.last_modify_liquidity_salt( ), bytes32(_minted_token_id), "add liquidity should use the existing token id as v4 salt." );
    }

    function test_add_liquidity_reverts_when_liquidity_is_zero( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, _minted_token_id, int128(0), 0 ) );
        _execute_add_liquidity_as( _USER, _add_params( _minted_token_id,0 ), _two_fundings( 100 ether, 100 ether ) );
    }

    function test_add_liquidity_reverts_when_liquidity_exceeds_int128_max( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.expectRevert();
        _execute_add_liquidity_as( _USER, _add_params( _minted_token_id,uint128(type(int128).max) + 1 ), _two_fundings( 100 ether, 100 ether ) );
    }

    function test_add_liquidity_reverts_when_funding_count_is_not_two( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        TokenAmount[] memory fundings  =  new TokenAmount[](1);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: 100 ether });

        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, _minted_token_id, int128(1 ether), 1 ) );
        _execute_add_liquidity_as( _USER, _add_params( _minted_token_id,1 ether ), fundings );
    }

    function test_add_liquidity_reverts_when_minimum_token_addresses_do_not_match_position_tokens( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        AddPositionLiquidityParams memory params  =  _add_params( _minted_token_id,1 ether );
        params.minimum_deposited_a.token  =  NATIVE_TOKEN;

        vm.expectRevert();
        _execute_add_liquidity_as( _USER, params, _two_fundings( 100 ether, 100 ether ) );
    }

    function test_add_liquidity_handles_one_sided_deposits_only_when_other_minimum_is_zero( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );
        _pool_manager.set_next_modify_liquidity_delta( -10 ether, 0 );

        AddPositionLiquidityParams memory params  =  _add_params( _minted_token_id,1 ether );
        params.minimum_deposited_a.amount  =  10 ether;
        params.minimum_deposited_b.amount  =  0;

        _execute_add_liquidity_as( _USER, params, _two_fundings( 100 ether, 100 ether ) );

        assertEq( _pool_manager.sync_call_count( ), 1, "one-sided ERC20 add should sync one token." );
        assertEq( _pool_manager.settle_call_count( ), 1, "one-sided ERC20 add should settle one token." );
        assertEq( _pool_manager.settle_value_received( ), 0, "one-sided ERC20 add should not settle native value." );
    }

    function test_add_liquidity_reverts_when_one_sided_deposit_omits_required_token_minimum( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );
        _pool_manager.set_next_modify_liquidity_delta( -10 ether, 0 );

        AddPositionLiquidityParams memory params  =  _add_params( _minted_token_id,1 ether );
        params.minimum_deposited_a.amount  =  10 ether;
        params.minimum_deposited_b.amount  =  1;

        vm.expectRevert( abi.encodeWithSelector( OneSidedDepositMismatch.selector, address(_token_b), uint256(1) ) );
        _execute_add_liquidity_as( _USER, params, _two_fundings( 100 ether, 100 ether ) );
    }

    function test_remove_liquidity_requires_owner_or_approved_operator( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.expectRevert( abi.encodeWithSelector( PositionUnauthorized.selector, _minted_token_id, address(this), _USER ) );
        _execute_remove_liquidity_as( address(this), _remove_params( _minted_token_id,1 ether ), new TokenAmount[](0) );
    }

    function test_remove_liquidity_allows_approved_token_address( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.prank( _USER );
        _nft.approve( address(this), _minted_token_id );

        _execute_remove_liquidity_as( address(this), _remove_params( _minted_token_id,1 ether ), new TokenAmount[](0) );

        assertEq( _pool_manager.last_modify_liquidity_delta( ), -int256(1 ether), "approved token address should remove liquidity." );
    }

    function test_remove_liquidity_sends_tokens_directly_to_bond_context_user( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );
        _pool_manager.set_next_modify_liquidity_delta( 5 ether, 7 ether );

        _execute_remove_liquidity_as( _USER, _remove_params( _minted_token_id,1 ether ), new TokenAmount[](0) );

        assertEq( _pool_manager.take_call_count( ), 2, "remove liquidity should take both pool tokens." );
        assertEq( _pool_manager.last_take_to( ), _USER, "removed liquidity should be sent to the BondRoute context user." );
    }

    function test_remove_liquidity_reverts_when_liquidity_is_zero( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, _minted_token_id, int128(0), 0 ) );
        _execute_remove_liquidity_as( _USER, _remove_params( _minted_token_id,0 ), new TokenAmount[](0) );
    }

    function test_remove_liquidity_reverts_when_funding_count_is_not_zero( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, _minted_token_id, -int128(1 ether), 2 ) );
        _execute_remove_liquidity_as( _USER, _remove_params( _minted_token_id,1 ether ), _two_fundings( 100 ether, 100 ether ) );
    }

    function test_collect_fees_requires_owner_or_approved_operator( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.expectRevert( abi.encodeWithSelector( PositionUnauthorized.selector, _minted_token_id, address(this), _USER ) );
        _execute_collect_fees_as( address(this), _collect_params( _minted_token_id ), new TokenAmount[](0) );
    }

    function test_collect_fees_uses_zero_liquidity_delta( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        _execute_collect_fees_as( _USER, _collect_params( _minted_token_id ), new TokenAmount[](0) );

        assertEq( _pool_manager.last_modify_liquidity_delta( ), 0, "collect fees should use zero liquidity delta." );
    }

    function test_collect_fees_sends_tokens_directly_to_bond_context_user( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );
        _pool_manager.set_next_modify_liquidity_delta( 1 ether, 2 ether );

        _execute_collect_fees_as( _USER, _collect_params( _minted_token_id ), new TokenAmount[](0) );

        assertEq( _pool_manager.take_call_count( ), 2, "collect fees should take both pool tokens." );
        assertEq( _pool_manager.last_take_to( ), _USER, "collected fees should be sent to the BondRoute context user." );
    }

    function test_collect_fees_records_earned_fee_totals( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        PoolId pool_id  =  _pool_key().toId( );
        _seed_position_info( pool_id, _minted_token_id,-120, 120, 2, 10 * FixedPoint128.Q128, 20 * FixedPoint128.Q128 );
        _seed_fee_growth_globals( pool_id, 15 * FixedPoint128.Q128, 27 * FixedPoint128.Q128 );

        _execute_collect_fees_as( _USER, _collect_params( _minted_token_id ), new TokenAmount[](0) );

        ( uint256 token0_fees, uint256 token1_fees )  =  _nft.get_lp_fee_totals( _minted_token_id );

        assertEq( token0_fees, 10, "collect should record token0 fees from fee growth." );
        assertEq( token1_fees, 14, "collect should record token1 fees from fee growth." );
    }

    function test_remove_liquidity_records_earned_fees_without_counting_principal( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        PoolId pool_id  =  _pool_key().toId( );
        _seed_position_info( pool_id, _minted_token_id,-120, 120, 2, 10 * FixedPoint128.Q128, 20 * FixedPoint128.Q128 );
        _seed_fee_growth_globals( pool_id, 15 * FixedPoint128.Q128, 27 * FixedPoint128.Q128 );
        _pool_manager.set_next_modify_liquidity_delta( 1_000 ether, 2_000 ether );

        _execute_remove_liquidity_as( _USER, _remove_params( _minted_token_id,1 ), new TokenAmount[](0) );

        ( uint256 token0_fees, uint256 token1_fees )  =  _nft.get_lp_fee_totals( _minted_token_id );

        assertEq( token0_fees, 10, "remove should record only token0 fees accrued before the touch." );
        assertEq( token1_fees, 14, "remove should record only token1 fees accrued before the touch." );
    }

    function test_collect_fees_reverts_when_funding_count_is_not_zero( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        vm.expectRevert( abi.encodeWithSelector( InvalidLiquidityModification.selector, _minted_token_id, int128(0), 2 ) );
        _execute_collect_fees_as( _USER, _collect_params( _minted_token_id ), _two_fundings( 100 ether, 100 ether ) );
    }

    function test_get_lp_position_returns_stored_metadata_for_existing_token( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );

        SafeSwapPositionInfo memory position_info  =  _nft.get_lp_position( _minted_token_id );

        assertEq( address(position_info.token0), Currency.unwrap(_pool_key().currency0), "position view should return stored token0." );
        assertEq( address(position_info.token1), Currency.unwrap(_pool_key().currency1), "position view should return stored token1." );
        assertEq( position_info.hook, _hook, "position view should return stored hook." );
    }

    function test_get_lp_position_reverts_for_missing_token( )
    external
    {
        vm.expectRevert();
        _nft.get_lp_position( _minted_token_id );
    }

    function test_off_chain_position_info_reads_v4_position_owned_by_nft( )
    external
    {
        PoolKey memory key  =  _pool_key();
        _seed_position_info( key.toId(), 1, -120, 120, 123 ether, 456, 789 );

        ( uint128 liquidity, uint256 fee_growth_0, uint256 fee_growth_1 )  =  _nft.__OFF_CHAIN__get_position_info(
            key.toId(),
            1,
            -120,
            120
        );

        assertEq( liquidity, 123 ether, "off-chain position view should read V4 position liquidity." );
        assertEq( fee_growth_0, 456, "off-chain position view should read token0 fee growth." );
        assertEq( fee_growth_1, 789, "off-chain position view should read token1 fee growth." );
    }

    function test_unlock_callback_reverts_when_caller_is_not_pool_manager( )
    external
    {
        vm.expectRevert( abi.encodeWithSelector( Unauthorized.selector, address(this), address(_pool_manager) ) );
        _nft.unlockCallback( "" );
    }

    function test_unlock_callback_executes_prepared_liquidity_modification( )
    external
    {
        _execute_create_position( _create_params(), _two_fundings( 100 ether, 100 ether ) );
        _pool_manager.set_next_modify_liquidity_delta( -10 ether, -10 ether );

        ModifyLiquidityParams memory params  =  ModifyLiquidityParams({
            token_id: _minted_token_id,
            pool_info: PoolInfo({ base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 }),
            tick_lower: -120,
            tick_upper: 120,
            liquidity_delta: int128(1 ether),
            minimum_amount_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 0 }),
            minimum_amount_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 0 })
        });
        SafeSwapPositionInfo memory position_info  =  _nft.get_lp_position( _minted_token_id );

        vm.prank( address(_pool_manager) );
        _nft.unlockCallback( abi.encode( _context(_two_fundings(100 ether, 100 ether)), params, position_info ) );

        assertTrue( _pool_manager.modify_liquidity_called(), "unlock callback should execute the prepared liquidity change." );
    }

    function _execute_create_position( CreatePositionParams memory params, TokenAmount[] memory fundings ) internal returns ( uint256 token_id )
    {
        BondContext memory context  =  _context( fundings );
        bytes memory call_data      =  abi.encodeCall( _nft.create_position, (params) );

        vm.recordLogs( );
        _execute_entry_point( call_data, context );

        token_id          =  _capture_minted_token_id( );
        _minted_token_id  =  token_id;
    }

    // Token ids are derived (hashed), not sequential, so read the actual id back from the ERC721 mint Transfer event
    // (from == address(0), tokenId indexed in topic[3]); ERC20 Transfers are skipped via the 4-topic / emitter filter.
    function _capture_minted_token_id( ) internal returns ( uint256 )
    {
        Vm.Log[] memory entries  =  vm.getRecordedLogs( );
        bytes32 transfer_sig     =  keccak256( "Transfer(address,address,uint256)" );

        for(  uint256 i = 0  ;  i < entries.length  ;  i = i + 1  )
        {
            Vm.Log memory entry  =  entries[ i ];

            if(  entry.emitter == address(_nft)  &&  entry.topics.length == 4  &&  entry.topics[0] == transfer_sig  &&  entry.topics[1] == bytes32(0)  )
            {
                return uint256( entry.topics[3] );
            }
        }

        revert( "create_position emitted no mint" );
    }

    function _execute_add_liquidity_as( address user, AddPositionLiquidityParams memory params, TokenAmount[] memory fundings ) internal
    {
        BondContext memory context  =  _context_for_user( user, fundings );
        bytes memory call_data      =  abi.encodeCall( _nft.add_liquidity, (params) );

        _execute_entry_point( call_data, context );
    }

    function _execute_remove_liquidity_as( address user, RemovePositionLiquidityParams memory params, TokenAmount[] memory fundings ) internal
    {
        BondContext memory context  =  _context_for_user( user, fundings );
        bytes memory call_data      =  abi.encodeCall( _nft.remove_liquidity, (params) );

        _execute_entry_point( call_data, context );
    }

    function _execute_collect_fees_as( address user, CollectFeesParams memory params, TokenAmount[] memory fundings ) internal
    {
        BondContext memory context  =  _context_for_user( user, fundings );
        bytes memory call_data      =  abi.encodeCall( _nft.collect_fees, (params) );

        _execute_entry_point( call_data, context );
    }

    function _execute_entry_point( bytes memory call_data, BondContext memory context ) internal
    {
        bytes memory entry_call  =  abi.encodeCall( _nft.BondRoute_entry_point, (call_data, context) );

        vm.prank( BONDROUTE_ADDRESS );
        ( bool success, bytes memory output )  =  address(_nft).call( entry_call );

        if(  success == false  )
        {
            assembly ("memory-safe")
            {
                revert( add( output, 0x20 ), mload( output ) )
            }
        }
    }

    function _context( TokenAmount[] memory fundings ) internal view returns ( BondContext memory )
    {
        return _context_for_user( _USER, fundings );
    }

    function _context_for_user( address user, TokenAmount[] memory fundings ) internal view returns ( BondContext memory )
    {
        return BondContext({
            user:               user,
            stake:              TokenAmount({ token: IERC20(address(_token_a)), amount: 100 ether }),
            fundings:           fundings,
            creation_block:     block.number - 10,
            creation_timestamp: block.timestamp - 10
        });
    }

    function _add_params( uint256 token_id, uint128 liquidity ) internal view returns ( AddPositionLiquidityParams memory )
    {
        return AddPositionLiquidityParams({
            token_id: token_id,
            liquidity: liquidity,
            minimum_deposited_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 0 }),
            minimum_deposited_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 0 })
        });
    }

    function _remove_params( uint256 token_id, uint128 liquidity ) internal view returns ( RemovePositionLiquidityParams memory )
    {
        return RemovePositionLiquidityParams({
            token_id: token_id,
            liquidity: liquidity,
            minimum_received_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 0 }),
            minimum_received_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 0 })
        });
    }

    function _collect_params( uint256 token_id ) internal view returns ( CollectFeesParams memory )
    {
        return CollectFeesParams({
            token_id: token_id,
            minimum_received_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 0 }),
            minimum_received_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 0 })
        });
    }

    function _create_params( ) internal view returns ( CreatePositionParams memory )
    {
        return CreatePositionParams({
            pool_info: PoolInfo({ base_fee_bps: 30, rebate_percent: 50, tick_spacing: 60 }),
            sqrt_price_lower_x96: TickMath.getSqrtPriceAtTick( -120 ),
            sqrt_price_upper_x96: TickMath.getSqrtPriceAtTick( 120 ),
            liquidity: 1 ether,
            sqrt_price_x96: _SQRT_PRICE_1_1,
            minimum_deposited_a: TokenAmount({ token: IERC20(address(_token_a)), amount: 0 }),
            minimum_deposited_b: TokenAmount({ token: IERC20(address(_token_b)), amount: 0 })
        });
    }

    function _two_fundings( uint256 amount_a, uint256 amount_b ) internal view returns ( TokenAmount[] memory fundings )
    {
        fundings     =  new TokenAmount[](2);
        fundings[0]  =  TokenAmount({ token: IERC20(address(_token_b)), amount: amount_b });
        fundings[1]  =  TokenAmount({ token: IERC20(address(_token_a)), amount: amount_a });
    }

    function _pool_key( ) internal view returns ( PoolKey memory )
    {
        IERC20 token0  =  address(_token_a) < address(_token_b)  ?  IERC20(address(_token_a))  :  IERC20(address(_token_b));
        IERC20 token1  =  address(_token_a) < address(_token_b)  ?  IERC20(address(_token_b))  :  IERC20(address(_token_a));

        return PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(_hook)
        });
    }

    function _seed_slot0( PoolKey memory key, uint160 sqrt_price_x96 ) internal
    {
        bytes32 state_slot  =  _pool_state_slot( key.toId( ) );
        _pool_manager.set_slot( state_slot, bytes32(uint256(sqrt_price_x96)) );
    }

    function _seed_position_info(
        PoolId pool_id,
        uint256 token_id,
        int24 tick_lower,
        int24 tick_upper,
        uint128 liquidity,
        uint256 fee_growth_inside_0_last_x128,
        uint256 fee_growth_inside_1_last_x128
    ) internal
    {
        bytes32 position_key  =  Position.calculatePositionKey( address(_nft), tick_lower, tick_upper, bytes32(token_id) );
        bytes32 position_slot =  _position_info_slot( pool_id, position_key );

        _pool_manager.set_slot( position_slot, bytes32(uint256(liquidity)) );
        _pool_manager.set_slot( bytes32(uint256(position_slot) + 1), bytes32(fee_growth_inside_0_last_x128) );
        _pool_manager.set_slot( bytes32(uint256(position_slot) + 2), bytes32(fee_growth_inside_1_last_x128) );
    }

    function _seed_fee_growth_globals( PoolId pool_id, uint256 fee_growth_global_0_x128, uint256 fee_growth_global_1_x128 ) internal
    {
        bytes32 state_slot  =  _pool_state_slot( pool_id );

        _pool_manager.set_slot( bytes32(uint256(state_slot) + 1), bytes32(fee_growth_global_0_x128) );
        _pool_manager.set_slot( bytes32(uint256(state_slot) + 2), bytes32(fee_growth_global_1_x128) );
    }

    function _nft_pool_slot0( PoolKey memory key ) internal view returns ( uint160 sqrt_price_x96, int24 tick, uint24 protocol_fee, uint24 lp_fee )
    {
        bytes32 state_slot  =  _pool_state_slot( key.toId( ) );
        bytes32 data        =  _pool_manager.extsload( state_slot );

        sqrt_price_x96  =  uint160(uint256(data));
        tick            =  0;
        protocol_fee    =  0;
        lp_fee          =  0;
    }

    function _pool_state_slot( PoolId pool_id ) internal pure returns ( bytes32 state_slot )
    {
        assembly ("memory-safe")
        {
            mstore( 0x00, pool_id )
            mstore( 0x20, 6 )
            state_slot  :=  keccak256( 0x00, 0x40 )
        }
    }

    function _position_info_slot( PoolId pool_id, bytes32 position_key ) internal pure returns ( bytes32 position_slot )
    {
        bytes32 state_slot            =  _pool_state_slot( pool_id );
        bytes32 position_mapping_slot =  bytes32(uint256(state_slot) + 6);

        position_slot  =  keccak256( abi.encodePacked( position_key, position_mapping_slot ) );
    }

    function _assert_token_amount_offset( string memory typed_string, uint256 token_amount_offset ) internal pure
    {
        bytes memory raw  =  bytes(typed_string);

        assertEq( raw[ token_amount_offset - 1 ], bytes1(")"), "the byte before the offset should close the action struct definition." );
        assertEq( _slice( raw, token_amount_offset, 12 ), "TokenAmount(", "offset should point at the TokenAmount definition." );
    }

    function _contains( string memory value, string memory needle ) internal pure returns ( bool )
    {
        bytes memory v  =  bytes(value);
        bytes memory n  =  bytes(needle);
        if(  n.length == 0  ||  v.length < n.length  )  return false;

        for(  uint256 i = 0  ;  i <= v.length - n.length  ;  i = i + 1  )
        {
            bool matched  =  true;
            for(  uint256 j = 0  ;  j < n.length  ;  j = j + 1  )
            {
                if(  v[ i + j ] != n[ j ]  )  {  matched  =  false;  break;  }
            }
            if(  matched  )  return true;
        }
        return false;
    }

    function _slice( bytes memory data, uint256 offset, uint256 length ) internal pure returns ( string memory )
    {
        bytes memory out  =  new bytes( length );
        for(  uint256 i = 0  ;  i < length  ;  i = i + 1  )
        {
            out[ i ]  =  data[ offset + i ];
        }
        return string(out);
    }
}

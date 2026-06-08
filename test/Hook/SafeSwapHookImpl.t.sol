// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ISafeSwapHookImplTests } from "@test/Hook/TestManifest.sol";
import { ChainConfigTestHelper } from "@test/helpers/ChainConfigTestHelper.t.sol";
import { SafeSwapTestHelper } from "@test/helpers/SafeSwapTestHelper.t.sol";
import "@SafeSwapCommon/Definitions.sol";
import { HookAddress } from "@SafeSwapCommon/HookAddress.sol";
import { SafeSwapCommon, RepricingFeeExceedsV4Limit } from "@SafeSwapCommon/SafeSwapCommon.sol";
import {
    SafeSwapHookImpl,
    DirectImplementationCallForbidden,
    CallerNotPoolManager,
    CallerNotRouter,
    CallerNotPositionManager,
    DeployHookFailed,
    DeployHookError
} from "@SafeSwapHook/SafeSwapHookImpl.sol";
import { ISafeSwapHook, ISafeSwapHookRegistry } from "@SafeSwapHook/ISafeSwapHook.sol";
import { Clones } from "@OpenZeppelin/proxy/Clones.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { BeforeSwapDelta } from "@UniswapV4Core/types/BeforeSwapDelta.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "@UniswapV4Core/libraries/LPFeeLibrary.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";


// ━━━━  MOCKS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockHookRouter is ISafeSwapHookRegistry {

    bool internal _should_revert;

    uint256 public register_call_count;
    address public last_hook;
    uint16 public last_base_fee_bps;
    uint8 public last_rebate_percent;

    mapping( address => bool ) public registered_hook;

    function set_should_revert( bool value )
    external
    {
        _should_revert  =  value;
    }

    function register_hook( uint16 base_fee_bps, uint8 rebate_percent )
    external
    {
        if(  _should_revert  )  revert( "router registration failed" );
        if(  registered_hook[ msg.sender ]  )  return;

        registered_hook[ msg.sender ]  =  true;
        register_call_count            =  register_call_count + 1;
        last_hook                      =  msg.sender;
        last_base_fee_bps              =  base_fee_bps;
        last_rebate_percent            =  rebate_percent;
    }
}


contract MockHookPoolManager {

    mapping( bytes32 => bytes32 ) internal _slots;

    function set_slot( bytes32 slot, bytes32 value )
    external
    {
        _slots[ slot ]  =  value;
    }

    function extsload( bytes32 slot )
    external  view returns ( bytes32 )
    {
        return _slots[ slot ];
    }
}


contract MockHookCode {
}


// ━━━━  TEST SUITE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract SafeSwapHookImplTest is ISafeSwapHookImplTests, ChainConfigTestHelper, SafeSwapTestHelper {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant _SQRT_PRICE_1_1   =  79228162514264337593543950336;
    int24 internal constant _DEFAULT_TICK       =  0;
    int24 internal constant _DEFAULT_SPACING    =  60;
    uint24 internal constant _DYNAMIC_FEE       =  LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint160 internal constant _EXTRA_PERMISSION =  uint160(1 << 5);
    address internal constant _ADDRESS_WITHOUT_CODE =  address(0xBEEF);
    address internal constant _UNAUTHORIZED_ACTOR   =  address(0xBAD);
    address internal constant _TOKEN0               =  address(0x1000);
    address internal constant _TOKEN1               =  address(0x2000);

    MockHookPoolManager internal _pool_manager;
    MockHookRouter internal _router;
    MockHookCode internal _nft;
    SafeSwapHookImpl internal _implementation;

    address internal _hook;

    function setUp( )
    public
    {
        vm.chainId( 31_337 );
        vm.warp( _DEFAULT_CONFIG_TIMESTAMP + 1 days );

        _deploy_chain_config( );

        _pool_manager  =  new MockHookPoolManager();
        _router        =  new MockHookRouter();
        _nft           =  new MockHookCode();

        _publish_hook_config( address(_pool_manager), address(_router), address(_nft) );

        _implementation  =  new SafeSwapHookImpl();
        _hook            =  _hook_address( 30, 50, HookAddress.REQUIRED_PERMISSIONS );
        _etch_hook_clone( _hook, address(_implementation) );
    }

    function test_implementation_reverts_when_called_directly( )
    external
    {
        vm.expectRevert( abi.encodeWithSelector( DirectImplementationCallForbidden.selector, address(_implementation) ) );
        _implementation.initialize_once( );
    }

    function test_constructor_reads_pool_manager_router_and_nft_from_chain_config( )
    external
    {
        assertEq( address(_implementation.PoolManager( )), address(_pool_manager), "constructor should read PoolManager from ChainConfig." );
        assertEq( _implementation.SafeSwapRouter( ), address(_router), "constructor should read router from ChainConfig." );
        assertEq( _implementation.SafeSwapNft( ), address(_nft), "constructor should read NFT from ChainConfig." );
    }

    function test_constructor_reverts_when_pool_manager_has_no_code( )
    external
    {
        _publish_hook_config( _ADDRESS_WITHOUT_CODE, address(_router), address(_nft) );

        vm.expectRevert( bytes("SafeSwapHook: Invalid pool_manager") );
        new SafeSwapHookImpl();
    }

    function test_constructor_reverts_when_router_has_no_code( )
    external
    {
        _publish_hook_config( address(_pool_manager), _ADDRESS_WITHOUT_CODE, address(_nft) );

        vm.expectRevert( bytes("SafeSwapHook: Invalid router") );
        new SafeSwapHookImpl();
    }

    function test_constructor_reverts_when_nft_has_no_code( )
    external
    {
        _publish_hook_config( address(_pool_manager), address(_router), _ADDRESS_WITHOUT_CODE );

        vm.expectRevert( bytes("SafeSwapHook: Invalid position manager") );
        new SafeSwapHookImpl();
    }

    function test_clone_getters_decode_base_fee_and_rebate_percent_from_clone_address( )
    external
    {
        ( uint16 base_fee_bps, uint8 rebate_percent )  =  ISafeSwapHook(_hook).get_hook_config( );
        assertEq( base_fee_bps, 30, "clone should decode base fee from its address." );
        assertEq( rebate_percent, 50, "clone should decode rebate percent from its address." );
    }

    function test_clone_getters_revert_when_clone_address_does_not_encode_valid_config( )
    external
    {
        address invalid_hook  =  _hook_address_with_config_nibbles( 0xE, 0, 3, 0, HookAddress.CAPTURE_MARKER, 5, HookAddress.REQUIRED_PERMISSIONS );
        _etch_hook_clone( invalid_hook, address(_implementation) );

        vm.expectRevert( abi.encodeWithSelector( HookAddress.InvalidHookConfig.selector, invalid_hook ) );
        ISafeSwapHook(invalid_hook).get_hook_config( );
    }

    function test_get_hook_config_reverts_when_called_on_implementation( )
    external
    {
        vm.expectRevert( abi.encodeWithSelector( DirectImplementationCallForbidden.selector, address(_implementation) ) );
        _implementation.get_hook_config( );
    }

    function test_clone_runtime_codehash_is_shared_across_config_instances( )
    external
    {
        address other_hook  =  _hook_address( 45, 70, HookAddress.REQUIRED_PERMISSIONS );
        _etch_hook_clone( other_hook, address(_implementation) );

        assertEq( _hook.codehash, other_hook.codehash, "clones pointing at the same implementation should share runtime codehash." );
    }

    function test_clone_runtime_codehash_changes_when_implementation_address_changes( )
    external
    {
        SafeSwapHookImpl other_implementation  =  new SafeSwapHookImpl();
        address other_hook  =  _hook_address( 45, 70, HookAddress.REQUIRED_PERMISSIONS );
        _etch_hook_clone( other_hook, address(other_implementation) );

        assertNotEq( _hook.codehash, other_hook.codehash, "clone runtime codehash should bind to the implementation address." );
    }

    function test_initialize_once_registers_clone_with_router( )
    external
    {
        ISafeSwapHook(_hook).initialize_once( );

        assertEq( _router.register_call_count( ), 1, "initialize_once should register exactly once." );
        assertEq( _router.last_hook( ), _hook, "router should see the clone as msg.sender." );
        assertTrue( _router.registered_hook( _hook ), "router should mark the clone as registered." );
    }

    function test_initialize_once_passes_decoded_base_fee_and_rebate_percent( )
    external
    {
        ISafeSwapHook(_hook).initialize_once( );

        assertEq( _router.last_base_fee_bps( ), 30, "initialize_once should pass decoded base fee." );
        assertEq( _router.last_rebate_percent( ), 50, "initialize_once should pass decoded rebate percent." );
    }

    function test_initialize_once_is_idempotent_for_same_registered_clone( )
    external
    {
        ISafeSwapHook(_hook).initialize_once( );
        ISafeSwapHook(_hook).initialize_once( );

        assertEq( _router.register_call_count( ), 1, "router idempotency should leave one registered clone entry." );
    }

    function test_initialize_once_bubbles_router_registration_revert( )
    external
    {
        _router.set_should_revert( true );

        vm.expectRevert( bytes("router registration failed") );
        ISafeSwapHook(_hook).initialize_once( );
    }

    function test_initialize_once_reverts_when_called_on_implementation( )
    external
    {
        vm.expectRevert( abi.encodeWithSelector( DirectImplementationCallForbidden.selector, address(_implementation) ) );
        _implementation.initialize_once( );
    }

    function test_clone_deploys_exact_canonical_eip1167_runtime_bytecode( )
    external
    {
        // deploy_hook deploys clones with OpenZeppelin's Clones; the registry authorizes keccak256 of the canonical
        // EIP-1167 runtime. Prove the deployed bytecode is exactly that runtime so deployed hooks pass the codehash gate.
        address clone               =  Clones.clone( address(_implementation) );
        bytes memory canonical      =  _eip1167_runtime( address(_implementation) );

        assertEq( clone.code.length, 45, "EIP-1167 runtime is exactly 45 bytes." );
        assertEq( clone.code, canonical, "clone runtime must be the canonical EIP-1167 bytecode." );
        assertEq( clone.codehash, keccak256( canonical ), "clone codehash must equal the canonical runtime hash the registry approves." );
    }

    function test_deploy_hook_reverts_when_a_contract_already_exists_at_the_salt_address( )
    external
    {
        bytes32 salt        =  bytes32( uint256(1) );
        address predicted   =  Clones.predictDeterministicAddress( address(_implementation), salt, address(_implementation) );
        _etch_hook_clone( predicted, address(_implementation) );

        vm.expectRevert( abi.encodeWithSelector( DeployHookFailed.selector, DeployHookError.ALREADY_EXISTS, predicted, uint16(30), uint8(50) ) );
        _implementation.deploy_hook( 30, 50, salt );
    }

    function test_deploy_hook_reverts_when_the_salt_address_is_not_a_valid_hook_config( )
    external
    {
        bytes32 salt        =  bytes32( uint256(1) );
        address predicted   =  Clones.predictDeterministicAddress( address(_implementation), salt, address(_implementation) );

        vm.expectRevert( abi.encodeWithSelector( HookAddress.InvalidHookConfig.selector, predicted ) );
        _implementation.deploy_hook( 30, 50, salt );
    }

    function test_deploy_hook_forwards_to_the_implementation_when_called_on_a_clone( )
    external
    {
        // A clone delegatecall must forward to the implementation, so the CREATE2 address is derived from the
        // implementation, never the clone. Etching at the implementation-derived address proves the forwarding occurred.
        bytes32 salt        =  bytes32( uint256(1) );
        address predicted   =  Clones.predictDeterministicAddress( address(_implementation), salt, address(_implementation) );
        _etch_hook_clone( predicted, address(_implementation) );

        vm.expectRevert( abi.encodeWithSelector( DeployHookFailed.selector, DeployHookError.ALREADY_EXISTS, predicted, uint16(30), uint8(50) ) );
        SafeSwapHookImpl(_hook).deploy_hook( 30, 50, salt );
    }

    function test_before_initialize_allows_only_pool_manager_call_with_nft_sender( )
    external
    {
        vm.prank( address(_pool_manager) );
        bytes4 selector  =  SafeSwapHookImpl(_hook).beforeInitialize( address(_nft), _pool_key(_hook), _SQRT_PRICE_1_1 );

        assertEq( selector, IHooks.beforeInitialize.selector, "beforeInitialize should return the v4 selector." );
    }

    function test_before_initialize_reverts_when_sender_is_not_nft( )
    external
    {
        address sender  =  _UNAUTHORIZED_ACTOR;

        vm.prank( address(_pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( CallerNotPositionManager.selector, sender, address(_nft) ) );
        SafeSwapHookImpl(_hook).beforeInitialize( sender, _pool_key(_hook), _SQRT_PRICE_1_1 );
    }

    function test_before_initialize_reverts_when_caller_is_not_pool_manager( )
    external
    {
        address caller  =  _UNAUTHORIZED_ACTOR;

        vm.prank( caller );
        vm.expectRevert( abi.encodeWithSelector( CallerNotPoolManager.selector, caller, address(_pool_manager) ) );
        SafeSwapHookImpl(_hook).beforeInitialize( address(_nft), _pool_key(_hook), _SQRT_PRICE_1_1 );
    }

    function test_before_add_liquidity_allows_only_pool_manager_call_with_nft_sender( )
    external
    {
        vm.prank( address(_pool_manager) );
        bytes4 selector  =  SafeSwapHookImpl(_hook).beforeAddLiquidity( address(_nft), _pool_key(_hook), _liquidity_params( ), "" );

        assertEq( selector, IHooks.beforeAddLiquidity.selector, "beforeAddLiquidity should return the v4 selector." );
    }

    function test_before_add_liquidity_reverts_when_sender_is_not_nft( )
    external
    {
        address sender  =  _UNAUTHORIZED_ACTOR;

        vm.prank( address(_pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( CallerNotPositionManager.selector, sender, address(_nft) ) );
        SafeSwapHookImpl(_hook).beforeAddLiquidity( sender, _pool_key(_hook), _liquidity_params( ), "" );
    }

    function test_before_add_liquidity_reverts_when_caller_is_not_pool_manager( )
    external
    {
        address caller  =  _UNAUTHORIZED_ACTOR;

        vm.prank( caller );
        vm.expectRevert( abi.encodeWithSelector( CallerNotPoolManager.selector, caller, address(_pool_manager) ) );
        SafeSwapHookImpl(_hook).beforeAddLiquidity( address(_nft), _pool_key(_hook), _liquidity_params( ), "" );
    }

    function test_before_remove_liquidity_allows_only_pool_manager_call_with_nft_sender( )
    external
    {
        vm.prank( address(_pool_manager) );
        bytes4 selector  =  SafeSwapHookImpl(_hook).beforeRemoveLiquidity( address(_nft), _pool_key(_hook), _liquidity_params( ), "" );

        assertEq( selector, IHooks.beforeRemoveLiquidity.selector, "beforeRemoveLiquidity should return the v4 selector." );
    }

    function test_before_remove_liquidity_reverts_when_sender_is_not_nft( )
    external
    {
        address sender  =  _UNAUTHORIZED_ACTOR;

        vm.prank( address(_pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( CallerNotPositionManager.selector, sender, address(_nft) ) );
        SafeSwapHookImpl(_hook).beforeRemoveLiquidity( sender, _pool_key(_hook), _liquidity_params( ), "" );
    }

    function test_before_remove_liquidity_reverts_when_caller_is_not_pool_manager( )
    external
    {
        address caller  =  _UNAUTHORIZED_ACTOR;

        vm.prank( caller );
        vm.expectRevert( abi.encodeWithSelector( CallerNotPoolManager.selector, caller, address(_pool_manager) ) );
        SafeSwapHookImpl(_hook).beforeRemoveLiquidity( address(_nft), _pool_key(_hook), _liquidity_params( ), "" );
    }

    function test_before_swap_allows_only_pool_manager_call_with_router_sender( )
    external
    {
        _seed_pool_state( _pool_key(_hook), _DEFAULT_TICK, _SQRT_PRICE_1_1, 1_000_000 ether );

        vm.prank( address(_pool_manager) );
        ( bytes4 selector, , )  =  SafeSwapHookImpl(_hook).beforeSwap( address(_router), _pool_key(_hook), _swap_params( 0 ), "" );

        assertEq( selector, IHooks.beforeSwap.selector, "beforeSwap should return the v4 selector." );
    }

    function test_before_swap_reverts_when_sender_is_not_router( )
    external
    {
        address sender  =  _UNAUTHORIZED_ACTOR;

        vm.prank( address(_pool_manager) );
        vm.expectRevert( abi.encodeWithSelector( CallerNotRouter.selector, sender, address(_router) ) );
        SafeSwapHookImpl(_hook).beforeSwap( sender, _pool_key(_hook), _swap_params( 0 ), "" );
    }

    function test_before_swap_reverts_when_caller_is_not_pool_manager( )
    external
    {
        address caller  =  _UNAUTHORIZED_ACTOR;

        vm.prank( caller );
        vm.expectRevert( abi.encodeWithSelector( CallerNotPoolManager.selector, caller, address(_pool_manager) ) );
        SafeSwapHookImpl(_hook).beforeSwap( address(_router), _pool_key(_hook), _swap_params( 0 ), "" );
    }

    function test_before_swap_returns_override_fee_with_base_fee_when_movement_is_zero( )
    external
    {
        uint24 fee  =  _before_swap_fee( _hook, 0, _DEFAULT_TICK );

        assertEq( fee, LPFeeLibrary.OVERRIDE_FEE_FLAG | SafeSwapCommon.compute_base_fee_pips( 30 ), "zero movement should return base fee with override flag." );
    }

    function test_before_swap_returns_override_fee_with_repricing_component_when_swap_moves_price( )
    external
    {
        uint24 fee  =  _before_swap_fee( _hook, -10 ether, _DEFAULT_TICK );

        assertGt( fee & LPFeeLibrary.REMOVE_OVERRIDE_MASK, SafeSwapCommon.compute_base_fee_pips( 30 ), "price movement should add a repricing component." );
    }

    function test_before_swap_returns_zero_before_swap_delta( )
    external
    {
        _seed_pool_state( _pool_key(_hook), _DEFAULT_TICK, _SQRT_PRICE_1_1, 1_000_000 ether );

        vm.prank( address(_pool_manager) );
        ( , BeforeSwapDelta delta, )  =  SafeSwapHookImpl(_hook).beforeSwap( address(_router), _pool_key(_hook), _swap_params( 0 ), "" );

        assertEq( BeforeSwapDelta.unwrap( delta ), 0, "beforeSwap should not alter swap deltas." );
    }

    function test_before_swap_returns_before_swap_selector( )
    external
    {
        _seed_pool_state( _pool_key(_hook), _DEFAULT_TICK, _SQRT_PRICE_1_1, 1_000_000 ether );

        vm.prank( address(_pool_manager) );
        ( bytes4 selector, , )  =  SafeSwapHookImpl(_hook).beforeSwap( address(_router), _pool_key(_hook), _swap_params( 0 ), "" );

        assertEq( selector, IHooks.beforeSwap.selector, "beforeSwap should identify the callback selector." );
    }

    function test_before_swap_reverts_when_repricing_fee_exceeds_v4_limit( )
    external
    {
        address expensive_hook  =  _hook_address( 999, 90, HookAddress.REQUIRED_PERMISSIONS );
        _etch_hook_clone( expensive_hook, address(_implementation) );
        PoolKey memory key  =  _pool_key( expensive_hook );
        _seed_pool_state( key, _DEFAULT_TICK, _SQRT_PRICE_1_1, 1_000 ether );

        vm.expectRevert( abi.encodeWithSelector( RepricingFeeExceedsV4Limit.selector, 7_301_610, 999_999 ) );
        vm.prank( address(_pool_manager) );
        SafeSwapHookImpl(expensive_hook).beforeSwap( address(_router), key, _swap_params( -10_000 ether ), "" );
    }

    function test_before_swap_uses_config_from_hook_address_not_hook_data( )
    external
    {
        address low_fee_hook  =  _hook_address( 5, 0, HookAddress.REQUIRED_PERMISSIONS );
        _etch_hook_clone( low_fee_hook, address(_implementation) );

        _seed_pool_state( _pool_key(low_fee_hook), _DEFAULT_TICK, _SQRT_PRICE_1_1, 1_000_000 ether );

        IPoolManager.SwapParams memory params  =  _swap_params( 0 );

        vm.prank( address(_pool_manager) );
        ( , , uint24 fee )  =  SafeSwapHookImpl(low_fee_hook).beforeSwap( address(_router), _pool_key(low_fee_hook), params, abi.encode(uint16(999), uint8(90)) );

        assertEq( fee, LPFeeLibrary.OVERRIDE_FEE_FLAG | SafeSwapCommon.compute_base_fee_pips( 5 ), "hook data should not affect decoded hook config." );
    }

    function test_before_swap_uses_pre_swap_pool_state( )
    external
    {
        uint24 fee_at_tick_zero  =  _before_swap_fee( _hook, -10 ether, 0 );
        uint24 fee_at_later_tick =  _before_swap_fee( _hook, -10 ether, 600 );

        assertNotEq( fee_at_tick_zero, fee_at_later_tick, "fee should depend on the pre-swap pool tick read from PoolManager." );
    }

    function test_required_permissions_include_initialize_add_remove_and_swap( )
    external  pure
    {
        assertTrue( HookAddress.has_required_permissions( address(HookAddress.REQUIRED_PERMISSIONS) ), "required bitmap should include all SafeSwap callbacks." );
    }

    function test_required_permissions_exclude_before_donate( )
    external  pure
    {
        address with_before_donate  =  address(uint160(HookAddress.REQUIRED_PERMISSIONS | _EXTRA_PERMISSION));

        assertFalse( HookAddress.has_required_permissions( with_before_donate ), "required bitmap should exclude beforeDonate." );
    }

    function test_hook_permission_validation_rejects_addresses_with_extra_permission_bits( )
    external  pure
    {
        address hook  =  address(uint160(HookAddress.REQUIRED_PERMISSIONS | uint160(1 << 3)));

        assertFalse( HookAddress.has_required_permissions( hook ), "permission validation should reject extra return-delta bits." );
    }

    function _publish_hook_config( address pool_manager, address router, address nft ) internal
    {
        _publish_config_address( POOL_MANAGER_KEY, pool_manager );
        _publish_config_address( SAFESWAP_ROUTER_KEY, router );
        _publish_config_address( SAFESWAP_NFT_KEY, nft );
    }

    function _etch_hook_clone( address hook, address implementation ) internal
    {
        vm.etch( hook, _eip1167_runtime( implementation ) );
    }

    function _eip1167_runtime( address implementation ) internal pure returns ( bytes memory )
    {
        return abi.encodePacked( hex"363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3" );
    }

    function _pool_key( address hook ) internal pure returns ( PoolKey memory )
    {
        return PoolKey({
            currency0: Currency.wrap( _TOKEN0 ),
            currency1: Currency.wrap( _TOKEN1 ),
            fee: _DYNAMIC_FEE,
            tickSpacing: _DEFAULT_SPACING,
            hooks: IHooks(hook)
        });
    }

    function _liquidity_params( ) internal pure returns ( IPoolManager.ModifyLiquidityParams memory )
    {
        return IPoolManager.ModifyLiquidityParams({ tickLower: -120, tickUpper: 120, liquidityDelta: 1 ether, salt: bytes32(0) });
    }

    function _swap_params( int256 amount_specified ) internal pure returns ( IPoolManager.SwapParams memory )
    {
        return IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: amount_specified, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
    }

    function _before_swap_fee( address hook, int256 amount_specified, int24 tick_before ) internal returns ( uint24 )
    {
        PoolKey memory key  =  _pool_key( hook );
        _seed_pool_state( key, tick_before, TickMath.getSqrtPriceAtTick( tick_before ), 1_000 ether );

        vm.prank( address(_pool_manager) );
        ( , , uint24 fee )  =  SafeSwapHookImpl(hook).beforeSwap( address(_router), key, _swap_params( amount_specified ), "" );

        return fee;
    }

    function _seed_pool_state( PoolKey memory key, int24 tick, uint160 sqrt_price_x96, uint128 liquidity ) internal
    {
        bytes32 state_slot  =  _pool_state_slot( key.toId( ) );

        _pool_manager.set_slot( state_slot, _slot0( sqrt_price_x96, tick ) );
        _pool_manager.set_slot( bytes32(uint256(state_slot) + 3), bytes32(uint256(liquidity)) );
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

    function _slot0( uint160 sqrt_price_x96, int24 tick ) internal pure returns ( bytes32 )
    {
        return bytes32( uint256(sqrt_price_x96) | ( uint256(uint24(tick)) << 160 ) );
    }
}

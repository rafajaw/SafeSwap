// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "@SafeSwap/SafeSwap.sol";
import "@SafeSwap/libraries/SafeSwapCommon.sol";
import "@SafeSwap/libraries/ExactInputSwapLib.sol";
import "@SafeSwap/libraries/ExactOutputSwapLib.sol";
import "@SafeSwap/libraries/AddLiquidityLib.sol";
import "@SafeSwap/libraries/RemoveLiquidityLib.sol";
import "@SafeSwap/libraries/DonateLib.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { IUnlockCallback } from "@UniswapV4Core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { StateLibrary } from "@UniswapV4Core/libraries/StateLibrary.sol";

import { MockERC20, MockBondRoute, MockChainConfig } from "./TestBase.t.sol";


// ━━━━  REAL POOL TEST HOOK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// @dev Extends SafeSwap with test entry points that bypass BondRoute_initialize but go through the real
///      PoolManager.unlock -> unlockCallback -> library execute -> real pool flow.
contract RealPoolTestHook is SafeSwap {

    constructor( address initial_collector ) SafeSwap( initial_collector ) { }

    function test_swap_exact_input( BondContext memory context, ExactInputSwapParams memory params )
    external
    {
        _set_protected_context( true );
        PoolManager.unlock( bytes.concat( abi.encode( context, params ), bytes1(uint8(UniswapHook.Action.ExactInputSwap)) ) );
        _set_protected_context( false );
    }

    function test_swap_exact_output( BondContext memory context, ExactOutputSwapParams memory params )
    external
    {
        _set_protected_context( true );
        PoolManager.unlock( bytes.concat( abi.encode( context, params ), bytes1(uint8(UniswapHook.Action.ExactOutputSwap)) ) );
        _set_protected_context( false );
    }

    function test_add_liquidity( BondContext memory context, AddLiquidityParams memory params )
    external
    {
        _set_protected_context( true );
        PoolManager.unlock( bytes.concat( abi.encode( context, params ), bytes1(uint8(UniswapHook.Action.AddLiquidity)) ) );
        _set_protected_context( false );
    }

    function test_remove_liquidity( BondContext memory context, RemoveLiquidityParams memory params )
    external
    {
        _set_protected_context( true );
        PoolManager.unlock( bytes.concat( abi.encode( context, params ), bytes1(uint8(UniswapHook.Action.RemoveLiquidity)) ) );
        _set_protected_context( false );
    }

    function test_donate( BondContext memory context, DonateParams memory params )
    external
    {
        _set_protected_context( true );
        PoolManager.unlock( bytes.concat( abi.encode( context, params ), bytes1(uint8(UniswapHook.Action.Donate)) ) );
        _set_protected_context( false );
    }

    function test_is_within_protected_context( ) external view returns ( bool )
    {
        return _is_within_protected_context( );
    }
}


// ━━━━  DIRECT SWAP ATTACKER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// @dev Attempts to swap directly through PoolManager without going through the hook's protected functions.
///      The hook's beforeSwap callback should reject this because the protected context flag is not set.
contract DirectSwapAttacker is IUnlockCallback {
    IPoolManager public immutable pool_manager;
    PoolKey public pool_key;

    constructor( IPoolManager _pm, PoolKey memory _key )
    {
        pool_manager  =  _pm;
        pool_key      =  _key;
    }

    function attack( ) external
    {
        pool_manager.unlock( "" );
    }

    function unlockCallback( bytes calldata ) external returns ( bytes memory )
    {
        pool_manager.swap(
            pool_key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: SafeSwapCommon.MIN_SQRT_PRICE_LIMIT
            }),
            ""
        );
        return "";
    }
}


// ━━━━  DIRECT DONATE ATTACKER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract DirectDonateAttacker is IUnlockCallback {
    IPoolManager public immutable pool_manager;
    PoolKey public pool_key;

    constructor( IPoolManager _pm, PoolKey memory _key )
    {
        pool_manager  =  _pm;
        pool_key      =  _key;
    }

    function attack( ) external
    {
        pool_manager.unlock( "" );
    }

    function unlockCallback( bytes calldata ) external returns ( bytes memory )
    {
        pool_manager.donate( pool_key, 1 ether, 1 ether, "" );
        return "";
    }
}


// ━━━━  TEST CONTRACT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract RealPoolIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;

    RealPoolTestHook public hook;
    IPoolManager public real_pool_manager;
    PoolKey public pool_key;

    MockERC20 public token0;
    MockERC20 public token1;

    address public collector;
    address public user;
    address public other_user;
    address public lp;

    uint24 constant POOL_FEE_030       =  3000;
    int24 constant TICK_SPACING_60     =  60;
    uint160 constant SQRT_PRICE_1_1    =  79228162514264337593543950336;
    uint256 constant INITIAL_BALANCE   =  1_000_000 ether;
    uint256 constant SEED_AMOUNT       =  10_000 ether;

    int24 constant FULL_RANGE_LOWER    =  -887220;  // Near MIN_TICK, aligned to tickSpacing 60.
    int24 constant FULL_RANGE_UPPER    =   887220;  // Near MAX_TICK, aligned to tickSpacing 60.

    address constant CHAINCONFIG_ADDRESS  =  0x5Afec0de00EB1c5323C7faA110f67499F744467b;
    bytes32 constant POOL_MANAGER_KEY     =  bytes32("v4.pool_manager.address");

    uint256 constant PROTOCOL_FEE_DIVISOR  =  10_000_000;


    function setUp( ) public
    {
        vm.roll( 1000 );
        vm.warp( 1000000 );

        collector   =  makeAddr( "collector" );
        user        =  makeAddr( "user" );
        other_user  =  makeAddr( "other_user" );
        lp          =  makeAddr( "liquidity_provider" );

        // Deploy mock infrastructure that is still needed (BondRoute, ChainConfig).
        MockChainConfig chain_config    =  new MockChainConfig( );
        MockBondRoute bond_route        =  new MockBondRoute( );

        vm.etch( CHAINCONFIG_ADDRESS, address(chain_config).code );
        vm.etch( BONDROUTE_ADDRESS, address(bond_route).code );
        MockBondRoute(payable(BONDROUTE_ADDRESS)).set_skip_actual_transfer( false );

        // Deploy the real Uniswap V4 PoolManager via a cross-version helper artifact.
        // PoolManager.sol uses `=0.8.26` which is incompatible with our `^0.8.30` sources,
        // so we deploy the helper artifact and let it instantiate PoolManager.
        {
            address deployer  =  vm.deployCode( "ForceCompileV4.sol:PoolManagerDeployer" );

            ( bool ok, bytes memory ret )  =  deployer.call( abi.encodeWithSignature( "deploy(address)", address(this) ) );
            require( ok, "PoolManager deployment failed" );
            real_pool_manager  =  IPoolManager(abi.decode( ret, (address) ));
        }

        // Store pool manager address in ChainConfig.
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( collector, POOL_MANAGER_KEY, address(real_pool_manager) );

        // Deploy hook normally (constructor reads ChainConfig, sets PoolManager immutable in bytecode).
        RealPoolTestHook deployed_hook  =  new RealPoolTestHook( collector );

        // Clone hook (code + storage) to address with correct hook permission bits.
        // BEFORE_SWAP(0x80) | BEFORE_DONATE(0x20) | BEFORE_REMOVE_LIQUIDITY(0x200) | BEFORE_ADD_LIQUIDITY(0x800) = 0x0AA0.
        address hook_target  =  address(uint160(0x0AA0));
        vm.cloneAccount( address(deployed_hook), hook_target );

        hook  =  RealPoolTestHook(payable(hook_target));

        // Deploy tokens and ensure token0 < token1 for proper Uniswap V4 ordering.
        token0  =  new MockERC20( "Token0", "TK0", 18 );
        token1  =  new MockERC20( "Token1", "TK1", 18 );
        if(  address(token0) > address(token1)  )
        {
            ( token0, token1 )  =  ( token1, token0 );
        }

        // Initialize pool in the real PoolManager.
        pool_key  =  PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: POOL_FEE_030,
            tickSpacing: TICK_SPACING_60,
            hooks: IHooks(address(hook))
        });
        real_pool_manager.initialize( pool_key, SQRT_PRICE_1_1 );

        // Mint tokens and set up approvals.
        token0.mint( user, INITIAL_BALANCE );
        token1.mint( user, INITIAL_BALANCE );
        token0.mint( other_user, INITIAL_BALANCE );
        token1.mint( other_user, INITIAL_BALANCE );
        token0.mint( lp, INITIAL_BALANCE );
        token1.mint( lp, INITIAL_BALANCE );

        // Dust to avoid 0-to-nonzero writes on fee collection.
        token0.mint( address(hook), 1 );
        token1.mint( address(hook), 1 );

        // Approve BondRoute for all users.
        _approve_bondroute( user );
        _approve_bondroute( other_user );
        _approve_bondroute( lp );

        // Seed pool with wide-range liquidity.
        BondContext memory seed_context  =  _create_two_funding_context( lp, SEED_AMOUNT, SEED_AMOUNT );
        AddLiquidityParams memory seed_params  =  AddLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: FULL_RANGE_LOWER,
            tick_upper: FULL_RANGE_UPPER,
            amount0_min: 0,
            amount1_min: 0,
            salt: bytes32(0)
        });
        hook.test_add_liquidity( seed_context, seed_params );
    }


    // ━━━━  EXACT INPUT SWAP  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_real_pool_exact_input_swap_basic( ) external
    {
        uint256 swap_amount  =  100 ether;
        BondContext memory context  =  _create_one_funding_context( user, swap_amount );

        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token1,
            minimum_amount_out: 0,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.test_swap_exact_input( context, params );

        uint256 token0_spent    =  user_token0_before - token0.balanceOf( user );
        uint256 token1_received  =  token1.balanceOf( user ) - user_token1_before;

        assertEq( token0_spent, swap_amount, "User should spend exactly the input amount." );
        assertGt( token1_received, 0, "User should receive some output tokens." );
        assertLt( token1_received, swap_amount, "Output should be less than input due to fees and price impact." );
    }

    function test_real_pool_exact_input_swap_respects_slippage( ) external
    {
        uint256 swap_amount  =  100 ether;
        BondContext memory context  =  _create_one_funding_context( user, swap_amount );

        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token1,
            minimum_amount_out: swap_amount,  // Unrealistically high - guaranteed to fail.
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        vm.expectRevert( );
        hook.test_swap_exact_input( context, params );
    }

    function test_real_pool_exact_input_swap_correct_protocol_fee( ) external
    {
        uint256 swap_amount  =  100 ether;
        BondContext memory context  =  _create_one_funding_context( user, swap_amount );

        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token1,
            minimum_amount_out: 0,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        uint256 hook_balance_before  =  token1.balanceOf( address(hook) );
        uint256 user_balance_before  =  token1.balanceOf( user );

        hook.test_swap_exact_input( context, params );

        uint256 protocol_fee  =  token1.balanceOf( address(hook) ) - hook_balance_before;
        uint256 user_received  =  token1.balanceOf( user ) - user_balance_before;
        uint256 total_output  =  protocol_fee + user_received;

        // Protocol fee = total_output * pool_fee / PROTOCOL_FEE_DIVISOR.
        uint256 expected_fee  =  total_output * POOL_FEE_030 / PROTOCOL_FEE_DIVISOR;

        assertEq( protocol_fee, expected_fee, "Protocol fee should be pool_fee / PROTOCOL_FEE_DIVISOR of total output." );
        assertGt( protocol_fee, 0, "Protocol fee should be non-zero for a meaningful swap." );
    }

    function test_real_pool_exact_input_swap_one_for_zero_direction( ) external
    {
        uint256 swap_amount  =  100 ether;

        // Fund with token1 instead of token0.
        TokenAmount[] memory fundings  =  new TokenAmount[]( 1 );
        fundings[ 0 ]  =  TokenAmount({ token: token1, amount: swap_amount });
        BondContext memory context  =  BondContext({
            user: user,
            stake: TokenAmount({ token: token1, amount: swap_amount / 100 }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });

        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token0,
            minimum_amount_out: 0,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.test_swap_exact_input( context, params );

        uint256 token1_spent    =  user_token1_before - token1.balanceOf( user );
        uint256 token0_received  =  token0.balanceOf( user ) - user_token0_before;

        assertEq( token1_spent, swap_amount, "User should spend the input token1 amount." );
        assertGt( token0_received, 0, "User should receive token0 output." );
    }


    // ━━━━  EXACT OUTPUT SWAP  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_real_pool_exact_output_swap_basic( ) external
    {
        uint256 max_input    =  100 ether;
        uint256 desired_out  =  50 ether;
        BondContext memory context  =  _create_one_funding_context( user, max_input );

        ExactOutputSwapParams memory params  =  ExactOutputSwapParams({
            token_out: token1,
            amount_out: desired_out,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.test_swap_exact_output( context, params );

        uint256 token0_spent    =  user_token0_before - token0.balanceOf( user );
        uint256 token1_received  =  token1.balanceOf( user ) - user_token1_before;

        assertGt( token0_spent, 0, "User should spend some token0." );
        assertLe( token0_spent, max_input, "User should not spend more than max input." );

        assertEq( token1_received, desired_out, "User should receive exactly the requested output amount." );
    }

    function test_real_pool_exact_output_swap_respects_slippage( ) external
    {
        uint256 max_input    =  1 ether;    // Too small for 50 ether output.
        uint256 desired_out  =  50 ether;
        BondContext memory context  =  _create_one_funding_context( user, max_input );

        ExactOutputSwapParams memory params  =  ExactOutputSwapParams({
            token_out: token1,
            amount_out: desired_out,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        vm.expectRevert( );
        hook.test_swap_exact_output( context, params );
    }

    function test_real_pool_exact_output_swap_correct_protocol_fee( ) external
    {
        uint256 max_input    =  100 ether;
        uint256 desired_out  =  50 ether;
        BondContext memory context  =  _create_one_funding_context( user, max_input );

        ExactOutputSwapParams memory params  =  ExactOutputSwapParams({
            token_out: token1,
            amount_out: desired_out,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        uint256 hook_balance_before  =  token1.balanceOf( address(hook) );

        hook.test_swap_exact_output( context, params );

        uint256 protocol_fee   =  token1.balanceOf( address(hook) ) - hook_balance_before;
        uint256 grossed_up     =  desired_out * PROTOCOL_FEE_DIVISOR / (PROTOCOL_FEE_DIVISOR - POOL_FEE_030);
        uint256 expected_fee   =  grossed_up - desired_out;

        assertEq( protocol_fee, expected_fee, "Protocol fee should be the grossed-up surplus delivered on top of the user's exact output." );
    }


    // ━━━━  ADD LIQUIDITY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_real_pool_add_liquidity_basic( ) external
    {
        uint256 amount  =  100 ether;
        BondContext memory context  =  _create_two_funding_context( user, amount, amount );

        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            amount0_min: 0,
            amount1_min: 0,
            salt: bytes32(uint256(1))
        });

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.test_add_liquidity( context, params );

        uint256 token0_spent  =  user_token0_before - token0.balanceOf( user );
        uint256 token1_spent  =  user_token1_before - token1.balanceOf( user );

        assertGt( token0_spent, 0, "Should deposit some token0." );
        assertGt( token1_spent, 0, "Should deposit some token1." );
        assertLe( token0_spent, amount, "Should not exceed funded amount for token0." );
        assertLe( token1_spent, amount, "Should not exceed funded amount for token1." );
    }

    function test_real_pool_add_liquidity_respects_slippage( ) external
    {
        uint256 amount  =  100 ether;
        BondContext memory context  =  _create_two_funding_context( user, amount, amount );

        // Use a centered range and require more than what will actually be deposited.
        // At 1:1 price with equal fundings, both tokens are used but amount deposited
        // depends on liquidity math. Requiring 101 ether ensures slippage check fires.
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            amount0_min: amount + 1 ether,  // Require more than available - guaranteed to fail.
            amount1_min: 0,
            salt: bytes32(uint256(2))
        });

        vm.expectRevert( );
        hook.test_add_liquidity( context, params );
    }

    function test_real_pool_add_liquidity_position_salt_isolation( ) external
    {
        uint256 amount  =  100 ether;
        bytes32 same_salt  =  keccak256( "shared_salt" );

        int24 tick_lower  =  -TICK_SPACING_60 * 10;
        int24 tick_upper  =  TICK_SPACING_60 * 10;

        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: tick_lower,
            tick_upper: tick_upper,
            amount0_min: 0,
            amount1_min: 0,
            salt: same_salt
        });

        // User A adds liquidity.
        BondContext memory context_a  =  _create_two_funding_context( user, amount, amount );
        hook.test_add_liquidity( context_a, params );

        uint256 user_a_token0_before  =  token0.balanceOf( user );

        // User B adds liquidity with the same salt.
        BondContext memory context_b  =  _create_two_funding_context( other_user, amount, amount );
        hook.test_add_liquidity( context_b, params );

        // User A should be unaffected by user B's add.
        assertEq(
            token0.balanceOf( user ),
            user_a_token0_before,
            "User A's balance should not change when user B adds liquidity with the same salt."
        );

        // Now user B tries to remove "user A's position" by using the same salt.
        // With salt isolation, this targets user B's own position, not user A's.
        BondContext memory remove_context_b  =  _create_zero_funding_context( other_user );
        RemoveLiquidityParams memory remove_params  =  RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: tick_lower,
            tick_upper: tick_upper,
            liquidity: 1,  // Remove minimal liquidity.
            amount0_min: 0,
            amount1_min: 0,
            salt: same_salt
        });
        hook.test_remove_liquidity( remove_context_b, remove_params );

        // User A's balance should still be unaffected.
        assertEq(
            token0.balanceOf( user ),
            user_a_token0_before,
            "User B removing liquidity with same salt should not affect user A."
        );
    }


    // ━━━━  REMOVE LIQUIDITY  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_real_pool_remove_liquidity_basic( ) external
    {
        uint256 amount  =  500 ether;
        bytes32 salt  =  bytes32(uint256(10));
        int24 tick_lower  =  -TICK_SPACING_60 * 10;
        int24 tick_upper  =  TICK_SPACING_60 * 10;

        // First add liquidity.
        BondContext memory add_context  =  _create_two_funding_context( user, amount, amount );
        AddLiquidityParams memory add_params  =  AddLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: tick_lower,
            tick_upper: tick_upper,
            amount0_min: 0,
            amount1_min: 0,
            salt: salt
        });
        hook.test_add_liquidity( add_context, add_params );

        // Read the position's liquidity from the real PoolManager.
        bytes32 effective_salt  =  SafeSwapCommon._position_salt( user, salt );
        ( uint128 position_liquidity, , )  =  StateLibrary.getPositionInfo(
            real_pool_manager,
            pool_key.toId( ),
            address(hook),
            tick_lower,
            tick_upper,
            effective_salt
        );
        assertGt( position_liquidity, 0, "Position should have liquidity after adding." );

        // Remove all of it.
        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        BondContext memory remove_context  =  _create_zero_funding_context( user );
        RemoveLiquidityParams memory remove_params  =  RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: tick_lower,
            tick_upper: tick_upper,
            liquidity: position_liquidity,
            amount0_min: 0,
            amount1_min: 0,
            salt: salt
        });
        hook.test_remove_liquidity( remove_context, remove_params );

        assertGt( token0.balanceOf( user ) - user_token0_before, 0, "User should receive token0 back." );
        assertGt( token1.balanceOf( user ) - user_token1_before, 0, "User should receive token1 back." );
    }

    function test_real_pool_remove_liquidity_respects_slippage( ) external
    {
        uint256 amount  =  500 ether;
        bytes32 salt  =  bytes32(uint256(11));
        int24 tick_lower  =  -TICK_SPACING_60 * 10;
        int24 tick_upper  =  TICK_SPACING_60 * 10;

        // Add liquidity.
        BondContext memory add_context  =  _create_two_funding_context( user, amount, amount );
        AddLiquidityParams memory add_params  =  AddLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: tick_lower,
            tick_upper: tick_upper,
            amount0_min: 0,
            amount1_min: 0,
            salt: salt
        });
        hook.test_add_liquidity( add_context, add_params );

        // Try to remove with unrealistic slippage requirement.
        BondContext memory remove_context  =  _create_zero_funding_context( user );
        RemoveLiquidityParams memory remove_params  =  RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: tick_lower,
            tick_upper: tick_upper,
            liquidity: 1,  // Tiny removal.
            amount0_min: 1000 ether,  // Impossibly high requirement.
            amount1_min: 0,
            salt: salt
        });

        vm.expectRevert( );
        hook.test_remove_liquidity( remove_context, remove_params );
    }

    function test_real_pool_remove_liquidity_correct_amounts( ) external
    {
        uint256 amount  =  500 ether;
        bytes32 salt  =  bytes32(uint256(12));
        int24 tick_lower  =  -TICK_SPACING_60 * 10;
        int24 tick_upper  =  TICK_SPACING_60 * 10;

        uint256 user_token0_before_add  =  token0.balanceOf( user );
        uint256 user_token1_before_add  =  token1.balanceOf( user );

        // Add liquidity.
        BondContext memory add_context  =  _create_two_funding_context( user, amount, amount );
        AddLiquidityParams memory add_params  =  AddLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: tick_lower,
            tick_upper: tick_upper,
            amount0_min: 0,
            amount1_min: 0,
            salt: salt
        });
        hook.test_add_liquidity( add_context, add_params );

        uint256 token0_deposited  =  user_token0_before_add - token0.balanceOf( user );
        uint256 token1_deposited  =  user_token1_before_add - token1.balanceOf( user );

        // Read position liquidity.
        bytes32 effective_salt  =  SafeSwapCommon._position_salt( user, salt );
        ( uint128 position_liquidity, , )  =  StateLibrary.getPositionInfo(
            real_pool_manager,
            pool_key.toId( ),
            address(hook),
            tick_lower,
            tick_upper,
            effective_salt
        );

        // Remove all liquidity.
        uint256 user_token0_before_remove  =  token0.balanceOf( user );
        uint256 user_token1_before_remove  =  token1.balanceOf( user );

        BondContext memory remove_context  =  _create_zero_funding_context( user );
        RemoveLiquidityParams memory remove_params  =  RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: tick_lower,
            tick_upper: tick_upper,
            liquidity: position_liquidity,
            amount0_min: 0,
            amount1_min: 0,
            salt: salt
        });
        hook.test_remove_liquidity( remove_context, remove_params );

        uint256 token0_returned  =  token0.balanceOf( user ) - user_token0_before_remove;
        uint256 token1_returned  =  token1.balanceOf( user ) - user_token1_before_remove;

        // Amounts returned should be close to amounts deposited (within rounding).
        assertApproxEqAbs( token0_returned, token0_deposited, 2, "Token0 round-trip should preserve value within rounding." );
        assertApproxEqAbs( token1_returned, token1_deposited, 2, "Token1 round-trip should preserve value within rounding." );
    }


    // ━━━━  END-TO-END MULTI-OPERATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_real_pool_swap_after_adding_more_liquidity( ) external
    {
        uint256 extra_amount  =  5000 ether;

        // Add extra liquidity in a narrow range.
        BondContext memory add_context  =  _create_two_funding_context( user, extra_amount, extra_amount );
        AddLiquidityParams memory add_params  =  AddLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: -TICK_SPACING_60 * 5,
            tick_upper: TICK_SPACING_60 * 5,
            amount0_min: 0,
            amount1_min: 0,
            salt: bytes32(uint256(20))
        });
        hook.test_add_liquidity( add_context, add_params );

        // Now swap.
        uint256 swap_amount  =  100 ether;
        BondContext memory swap_context  =  _create_one_funding_context( user, swap_amount );
        ExactInputSwapParams memory swap_params  =  ExactInputSwapParams({
            token_out: token1,
            minimum_amount_out: 0,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.test_swap_exact_input( swap_context, swap_params );

        uint256 received  =  token1.balanceOf( user ) - user_token1_before;
        assertGt( received, 0, "Swap should produce output after adding extra liquidity." );
    }

    function test_real_pool_multiple_swaps_move_price( ) external
    {
        uint256 swap_amount  =  500 ether;

        // First swap.
        BondContext memory context1  =  _create_one_funding_context( user, swap_amount );
        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token1,
            minimum_amount_out: 0,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        uint256 user_token1_before_1  =  token1.balanceOf( user );
        hook.test_swap_exact_input( context1, params );
        uint256 output_1  =  token1.balanceOf( user ) - user_token1_before_1;

        // Second swap of same size in same direction.
        BondContext memory context2  =  _create_one_funding_context( user, swap_amount );

        uint256 user_token1_before_2  =  token1.balanceOf( user );
        hook.test_swap_exact_input( context2, params );
        uint256 output_2  =  token1.balanceOf( user ) - user_token1_before_2;

        // Price impact: second swap should give less output (price moved against us).
        assertLt( output_2, output_1, "Consecutive swaps in same direction should produce diminishing output due to price impact." );
    }


    // ━━━━  DONATE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_real_pool_donate_basic( ) external
    {
        BondContext memory context  =  _create_two_funding_context( user, 100 ether, 200 ether );
        DonateParams memory params  =  DonateParams({
            token0: token0,
            token1: token1,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.test_donate( context, params );

        assertEq( user_token0_before - token0.balanceOf( user ), 100 ether, "User should donate token0." );
        assertEq( user_token1_before - token1.balanceOf( user ), 200 ether, "User should donate token1." );
    }

    function test_real_pool_donate_one_sided( ) external
    {
        BondContext memory context  =  _create_two_funding_context( user, 0, 200 ether );
        DonateParams memory params  =  DonateParams({
            token0: token0,
            token1: token1,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        uint256 user_token0_before  =  token0.balanceOf( user );
        uint256 user_token1_before  =  token1.balanceOf( user );

        hook.test_donate( context, params );

        assertEq( token0.balanceOf( user ), user_token0_before, "User should not donate token0." );
        assertEq( user_token1_before - token1.balanceOf( user ), 200 ether, "User should donate token1." );
    }

    function test_real_pool_protected_context_cleared_after_operation( ) external
    {
        uint256 swap_amount  =  10 ether;
        BondContext memory context  =  _create_one_funding_context( user, swap_amount );

        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: token1,
            minimum_amount_out: 0,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });

        hook.test_swap_exact_input( context, params );

        assertEq(
            hook.test_is_within_protected_context( ),
            false,
            "Protected context should be cleared after swap completes."
        );
    }

    function test_real_pool_hook_rejects_direct_pool_swap( ) external
    {
        DirectSwapAttacker attacker  =  new DirectSwapAttacker( real_pool_manager, pool_key );

        // Fund the attacker so the swap could theoretically succeed.
        token0.mint( address(attacker), 100 ether );

        vm.expectRevert( );
        attacker.attack( );
    }

    function test_real_pool_hook_rejects_direct_pool_donate( ) external
    {
        DirectDonateAttacker attacker  =  new DirectDonateAttacker( real_pool_manager, pool_key );

        token0.mint( address(attacker), 100 ether );
        token1.mint( address(attacker), 100 ether );

        vm.expectRevert( );
        attacker.attack( );
    }

    function test_real_pool_fee_accumulation_and_withdrawal( ) external
    {
        // Execute multiple swaps.
        for(  uint i = 0  ;  i < 5  ;  i = i + 1  )
        {
            BondContext memory context  =  _create_one_funding_context( user, 100 ether );
            ExactInputSwapParams memory params  =  ExactInputSwapParams({
                token_out: token1,
                minimum_amount_out: 0,
                pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
            });
            hook.test_swap_exact_input( context, params );
        }

        uint256 hook_token1_balance  =  token1.balanceOf( address(hook) );
        assertGt( hook_token1_balance, 1, "Hook should have accumulated protocol fees." );

        // Collector withdraws.
        address recipient  =  makeAddr( "treasury" );
        token1.mint( recipient, 1 );  // Dust to avoid 0-to-nonzero.

        uint256 recipient_before  =  token1.balanceOf( recipient );

        vm.prank( collector );
        hook.withdraw_fees( token1, recipient );

        uint256 recipient_after  =  token1.balanceOf( recipient );

        assertGt( recipient_after - recipient_before, 0, "Recipient should receive withdrawn fees." );
        assertEq( token1.balanceOf( address(hook) ), 1, "Hook should retain 1 wei after withdrawal." );
    }


    // ━━━━  STAKE QUOTATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_real_pool_quote_add_liquidity_stake_normalizes_both_sides( ) external view
    {
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info:   PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower:  -TICK_SPACING_60 * 10,
            tick_upper:  TICK_SPACING_60 * 10,
            amount0_min: 0,
            amount1_min: 0,
            salt:        bytes32(0)
        });
        bytes memory call_data  =  abi.encodeWithSelector( hook.add_liquidity.selector, params );

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[ 0 ]  =  TokenAmount({ token: IERC20(address(token0)), amount: 100 ether });
        fundings[ 1 ]  =  TokenAmount({ token: IERC20(address(token1)), amount: 200 ether });

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, IERC20(address(token0)), fundings );

        assertEq( constraints.min_stake.amount, 6 ether, "At 1:1 price, stake is 2% of (100 + 200) = 6 ether." );
        assertEq( address(constraints.min_stake.token), address(token0), "Stake is always denominated in token0." );
    }

    function test_real_pool_quote_add_liquidity_dust_input_still_yields_real_stake( ) external view
    {
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info:   PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower:  -TICK_SPACING_60 * 10,
            tick_upper:  TICK_SPACING_60 * 10,
            amount0_min: 0,
            amount1_min: 0,
            salt:        bytes32(0)
        });
        bytes memory call_data  =  abi.encodeWithSelector( hook.add_liquidity.selector, params );

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[ 0 ]  =  TokenAmount({ token: IERC20(address(token0)), amount: 1 });
        fundings[ 1 ]  =  TokenAmount({ token: IERC20(address(token1)), amount: 1 ether });

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, IERC20(address(token0)), fundings );

        assertGt( constraints.min_stake.amount, 0, "1 wei on one side must not zero the stake when real value sits on the other." );
        assertApproxEqAbs( constraints.min_stake.amount, 0.02 ether, 1, "Stake reflects the dominant side: 2% of ~1 ether." );
    }

    function test_real_pool_quote_add_liquidity_one_sided_above_yields_real_stake( ) external view
    {
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info:   PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower:  TICK_SPACING_60 * 5,
            tick_upper:  TICK_SPACING_60 * 15,
            amount0_min: 0,
            amount1_min: 0,
            salt:        bytes32(0)
        });
        bytes memory call_data  =  abi.encodeWithSelector( hook.add_liquidity.selector, params );

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[ 0 ]  =  TokenAmount({ token: IERC20(address(token0)), amount: 0 });
        fundings[ 1 ]  =  TokenAmount({ token: IERC20(address(token1)), amount: 100 ether });

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, IERC20(address(token0)), fundings );

        assertEq( constraints.min_stake.amount, 2 ether, "Stake on a one-sided (0, 100) position at 1:1 = 2% of 100 ether." );
        assertEq( address(constraints.min_stake.token), address(token0), "Stake is always denominated in token0." );
    }

    function test_real_pool_quote_add_liquidity_returns_two_fundings_and_delays( ) external view
    {
        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info:   PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower:  -TICK_SPACING_60 * 10,
            tick_upper:  TICK_SPACING_60 * 10,
            amount0_min: 0,
            amount1_min: 0,
            salt:        bytes32(0)
        });
        bytes memory call_data  =  abi.encodeWithSelector( hook.add_liquidity.selector, params );

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[ 0 ]  =  TokenAmount({ token: IERC20(address(token0)), amount: 100 ether });
        fundings[ 1 ]  =  TokenAmount({ token: IERC20(address(token1)), amount: 200 ether });

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, IERC20(address(token0)), fundings );

        assertEq( constraints.min_fundings.length, 2, "Add liquidity requires two fundings." );
        assertEq( address(constraints.min_fundings[ 0 ].token), address(token0), "First funding echoes token0." );
        assertEq( constraints.min_fundings[ 0 ].amount, 100 ether, "First funding amount echoes input." );
        assertEq( address(constraints.min_fundings[ 1 ].token), address(token1), "Second funding echoes token1." );
        assertEq( constraints.min_fundings[ 1 ].amount, 200 ether, "Second funding amount echoes input." );

        assertEq( constraints.min_execution_delay_in_blocks, 3, "Liquidity bonds require 3 blocks of delay." );
        assertEq( constraints.max_execution_delay_in_seconds, 4 hours, "Liquidity bonds have a 4-hour execution window." );
    }

    function test_real_pool_quote_remove_liquidity_stake_uses_position_amounts( ) external view
    {
        RemoveLiquidityParams memory params  =  RemoveLiquidityParams({
            token0:      IERC20(address(token0)),
            token1:      IERC20(address(token1)),
            pool_info:   PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower:  -TICK_SPACING_60 * 10,
            tick_upper:  TICK_SPACING_60 * 10,
            liquidity:   100 ether,
            amount0_min: 0,
            amount1_min: 0,
            salt:        bytes32(0)
        });
        bytes memory call_data  =  abi.encodeWithSelector( hook.remove_liquidity.selector, params );

        TokenAmount[] memory no_fundings  =  new TokenAmount[]( 0 );
        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, IERC20(address(token0)), no_fundings );

        assertGt( constraints.min_stake.amount, 0, "Stake derived from position liquidity must be non-zero." );
        assertEq( address(constraints.min_stake.token), address(token0), "Stake is always denominated in token0." );
        assertEq( constraints.min_fundings.length, 0, "Remove liquidity requires no fundings." );
        assertEq( constraints.min_execution_delay_in_blocks, 3, "Liquidity bonds require 3 blocks of delay." );
        assertEq( constraints.max_execution_delay_in_seconds, 4 hours, "Liquidity bonds have a 4-hour execution window." );
    }

    function test_real_pool_quote_remove_liquidity_stake_ignores_user_supplied_mins( ) external view
    {
        RemoveLiquidityParams memory params_zero_mins  =  RemoveLiquidityParams({
            token0:      IERC20(address(token0)),
            token1:      IERC20(address(token1)),
            pool_info:   PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower:  -TICK_SPACING_60 * 10,
            tick_upper:  TICK_SPACING_60 * 10,
            liquidity:   100 ether,
            amount0_min: 0,
            amount1_min: 0,
            salt:        bytes32(0)
        });
        RemoveLiquidityParams memory params_high_mins  =  RemoveLiquidityParams({
            token0:      IERC20(address(token0)),
            token1:      IERC20(address(token1)),
            pool_info:   PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower:  -TICK_SPACING_60 * 10,
            tick_upper:  TICK_SPACING_60 * 10,
            liquidity:   100 ether,
            amount0_min: 1_000_000 ether,
            amount1_min: 1_000_000 ether,
            salt:        bytes32(0)
        });

        TokenAmount[] memory no_fundings  =  new TokenAmount[]( 0 );

        BondConstraints memory constraints_zero  =  hook.BondRoute_quote_call(
            abi.encodeWithSelector( hook.remove_liquidity.selector, params_zero_mins ),
            IERC20(address(token0)),
            no_fundings
        );
        BondConstraints memory constraints_high  =  hook.BondRoute_quote_call(
            abi.encodeWithSelector( hook.remove_liquidity.selector, params_high_mins ),
            IERC20(address(token0)),
            no_fundings
        );

        assertEq( constraints_zero.min_stake.amount, constraints_high.min_stake.amount, "Stake must depend on real position amounts, not on user-supplied slippage bounds." );
    }

    function test_real_pool_quote_donate_stake_normalizes_both_sides( ) external view
    {
        DonateParams memory params  =  DonateParams({
            token0:    IERC20(address(token0)),
            token1:    IERC20(address(token1)),
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });
        bytes memory call_data  =  abi.encodeWithSelector( hook.donate.selector, params );

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[ 0 ]  =  TokenAmount({ token: IERC20(address(token0)), amount: 100 ether });
        fundings[ 1 ]  =  TokenAmount({ token: IERC20(address(token1)), amount: 200 ether });

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, IERC20(address(token0)), fundings );

        assertEq( constraints.min_stake.amount, 6 ether, "At 1:1 price, donate stake is 2% of (100 + 200) = 6 ether." );
        assertEq( address(constraints.min_stake.token), address(token0), "Stake is always denominated in token0." );
    }

    function test_real_pool_quote_donate_dust_input_still_yields_real_stake( ) external view
    {
        DonateParams memory params  =  DonateParams({
            token0:    IERC20(address(token0)),
            token1:    IERC20(address(token1)),
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });
        bytes memory call_data  =  abi.encodeWithSelector( hook.donate.selector, params );

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[ 0 ]  =  TokenAmount({ token: IERC20(address(token0)), amount: 1 });
        fundings[ 1 ]  =  TokenAmount({ token: IERC20(address(token1)), amount: 1 ether });

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, IERC20(address(token0)), fundings );

        assertGt( constraints.min_stake.amount, 0, "1 wei on one side must not zero the stake when real value sits on the other." );
        assertApproxEqAbs( constraints.min_stake.amount, 0.02 ether, 1, "Stake reflects the dominant side: 2% of ~1 ether." );
    }

    function test_real_pool_quote_donate_one_sided_yields_real_stake( ) external view
    {
        DonateParams memory params  =  DonateParams({
            token0:    IERC20(address(token0)),
            token1:    IERC20(address(token1)),
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });
        bytes memory call_data  =  abi.encodeWithSelector( hook.donate.selector, params );

        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[ 0 ]  =  TokenAmount({ token: IERC20(address(token0)), amount: 0 });
        fundings[ 1 ]  =  TokenAmount({ token: IERC20(address(token1)), amount: 200 ether });

        BondConstraints memory constraints  =  hook.BondRoute_quote_call( call_data, IERC20(address(token0)), fundings );

        assertEq( constraints.min_stake.amount, 4 ether, "Stake on a one-sided (0, 200) donate at 1:1 = 2% of 200 ether." );
        assertEq( address(constraints.min_stake.token), address(token0), "Stake is always denominated in token0." );
    }


    // ━━━━  HELPERS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _approve_bondroute( address account ) internal
    {
        vm.startPrank( account );
        token0.approve( BONDROUTE_ADDRESS, type(uint256).max );
        token1.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );
    }

    function _create_one_funding_context( address _user, uint256 amount )
    internal view returns ( BondContext memory )
    {
        TokenAmount[] memory fundings  =  new TokenAmount[]( 1 );
        fundings[ 0 ]  =  TokenAmount({ token: token0, amount: amount });

        return BondContext({
            user: _user,
            stake: TokenAmount({ token: token0, amount: amount / 100 }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });
    }

    function _create_two_funding_context( address _user, uint256 amount0, uint256 amount1 )
    internal view returns ( BondContext memory )
    {
        TokenAmount[] memory fundings  =  new TokenAmount[]( 2 );
        fundings[ 0 ]  =  TokenAmount({ token: token0, amount: amount0 });
        fundings[ 1 ]  =  TokenAmount({ token: token1, amount: amount1 });

        return BondContext({
            user: _user,
            stake: TokenAmount({ token: token0, amount: amount0 / 100 }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });
    }

    function _create_zero_funding_context( address _user )
    internal view returns ( BondContext memory )
    {
        TokenAmount[] memory fundings  =  new TokenAmount[]( 0 );

        return BondContext({
            user: _user,
            stake: TokenAmount({ token: token0, amount: 0 }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });
    }
}

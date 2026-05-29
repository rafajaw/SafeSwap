// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "@SafeSwap/SafeSwap.sol";
import "@SafeSwap/libraries/SafeSwapCommon.sol";
import { CHAINCONFIG_ADDRESS } from "@ChainConfig/IChainConfig.sol";
import { CONFIG_SIGNER, POOL_MANAGER_KEY, INITIAL_COLLECTOR_KEY } from "@SafeSwap/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";

import { MockBondRoute, MockChainConfig, MockERC20 } from "./TestBase.t.sol";


// ━━━━  TEST HOOK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract ReentryPoolTestHook is SafeSwap {

    constructor( ) SafeSwap( ) { }

    function harness_donate( BondContext memory context, DonateParams memory params )
    external
    {
        PoolManager.unlock( bytes.concat( bytes1(uint8(UniswapHook.Action.Donate)), abi.encode( context, params ) ) );
    }

    function harness_add_liquidity( BondContext memory context, AddLiquidityParams memory params )
    external
    {
        PoolManager.unlock( bytes.concat( bytes1(uint8(UniswapHook.Action.AddLiquidity)), abi.encode( context, params ) ) );
    }

    function harness_swap_exact_input( BondContext memory context, ExactInputSwapParams memory params )
    external
    {
        PoolManager.unlock( bytes.concat( bytes1(uint8(UniswapHook.Action.ExactInputSwap)), abi.encode( context, params ) ) );
    }
}


// ━━━━  MALICIOUS ERC20  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract ReentrantERC20 is IERC20 {
    string public name     =  "Reentrant";
    string public symbol   =  "REENT";
    uint8 public decimals  =  18;
    uint256 public totalSupply;

    mapping( address => uint256 ) public balanceOf;
    mapping( address => mapping( address => uint256 ) ) public allowance;

    IPoolManager public pool_manager;
    PoolKey public pool_key;

    bool public attack_enabled;
    bool private _is_attacking;
    bool public direct_swap_succeeded;

    uint256 public attack_amount  =  1 ether;

    function configure_attack( IPoolManager manager, PoolKey memory key ) external
    {
        pool_manager  =  manager;
        pool_key      =  key;
    }

    function set_attack_enabled( bool enabled ) external
    {
        attack_enabled  =  enabled;
    }

    function mint( address to, uint256 amount ) external
    {
        balanceOf[ to ]  =  balanceOf[ to ] + amount;
        totalSupply      =  totalSupply + amount;
        emit Transfer( address(0), to, amount );
    }

    function approve( address spender, uint256 value ) external returns ( bool )
    {
        allowance[ msg.sender ][ spender ]  =  value;
        emit Approval( msg.sender, spender, value );
        return true;
    }

    function transfer( address to, uint256 value ) external returns ( bool )
    {
        balanceOf[ msg.sender ]  =  balanceOf[ msg.sender ] - value;
        balanceOf[ to ]          =  balanceOf[ to ] + value;
        emit Transfer( msg.sender, to, value );

        if(  attack_enabled  &&  _is_attacking == false  )
        {
            _is_attacking  =  true;
            _direct_pool_swap_without_bondroute( );
            _is_attacking  =  false;
        }

        return true;
    }

    function transferFrom( address from, address to, uint256 value ) external returns ( bool )
    {
        if(  allowance[ from ][ msg.sender ] != type(uint256).max  )
        {
            allowance[ from ][ msg.sender ]  =  allowance[ from ][ msg.sender ] - value;
        }

        balanceOf[ from ]  =  balanceOf[ from ] - value;
        balanceOf[ to ]    =  balanceOf[ to ] + value;
        emit Transfer( from, to, value );

        if(  attack_enabled  &&  _is_attacking == false  )
        {
            _is_attacking  =  true;
            _direct_pool_swap_without_bondroute( );
            _is_attacking  =  false;
        }

        return true;
    }

    function _direct_pool_swap_without_bondroute( ) private
    {
        BalanceDelta delta  =  pool_manager.swap(
            pool_key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(attack_amount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        int128 amount0  =  delta.amount0( );
        int128 amount1  =  delta.amount1( );

        if(  amount0 < 0  )  _settle( pool_key.currency0, uint256(uint128(-amount0)) );
        if(  amount1 < 0  )  _settle( pool_key.currency1, uint256(uint128(-amount1)) );
        if(  amount0 > 0  )  pool_manager.take( pool_key.currency0, address(this), uint256(uint128(amount0)) );
        if(  amount1 > 0  )  pool_manager.take( pool_key.currency1, address(this), uint256(uint128(amount1)) );

        direct_swap_succeeded  =  true;
    }

    function _settle( Currency currency, uint256 amount ) private
    {
        pool_manager.sync( currency );

        address token  =  Currency.unwrap( currency );
        if(  token == address(this)  )
        {
            balanceOf[ address(this) ]        =  balanceOf[ address(this) ] - amount;
            balanceOf[ address(pool_manager) ]  =  balanceOf[ address(pool_manager) ] + amount;
            emit Transfer( address(this), address(pool_manager), amount );
        }
        else
        {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            MockERC20(token).transfer( address(pool_manager), amount );
        }

        pool_manager.settle( );
    }
}


// ━━━━  TEST CONTRACT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract ReentrantProtectedContextTest is Test {

    ReentryPoolTestHook public hook;
    IPoolManager public real_pool_manager;
    PoolKey public outer_pool_key;
    PoolKey public attack_pool_key;

    ReentrantERC20 public malicious_token;
    MockERC20 public outer_paired_token;
    MockERC20 public outer_input_token;
    MockERC20 public attack_token_a;
    MockERC20 public attack_token_b;
    MockERC20 public attack_output_token;

    address public collector;
    address public user;
    address public lp;

    uint24 constant POOL_FEE_030       =  3000;
    int24 constant TICK_SPACING_60     =  60;
    uint160 constant SQRT_PRICE_1_1    =  79228162514264337593543950336;  // = 2^96; Q96 encoding of price 1.0.
    uint256 constant INITIAL_BALANCE   =  1_000_000 ether;
    uint256 constant SEED_AMOUNT       =  10_000 ether;

    int24 constant FULL_RANGE_LOWER    =  -887220;
    int24 constant FULL_RANGE_UPPER    =   887220;

    function setUp( ) public
    {
        vm.roll( 1000 );
        vm.warp( 1000000 );

        collector  =  makeAddr( "collector" );
        user       =  makeAddr( "user" );
        lp         =  makeAddr( "lp" );

        MockChainConfig chain_config  =  new MockChainConfig( );
        MockBondRoute bond_route      =  new MockBondRoute( );

        vm.etch( CHAINCONFIG_ADDRESS, address(chain_config).code );
        vm.etch( BONDROUTE_ADDRESS, address(bond_route).code );
        MockBondRoute(payable(BONDROUTE_ADDRESS)).set_skip_actual_transfer( false );

        address deployer  =  vm.deployCode( "ForceCompileV4.sol:PoolManagerDeployer" );
        ( bool ok, bytes memory ret )  =  deployer.call( abi.encodeWithSignature( "deploy(address)", address(this) ) );
        require( ok, "PoolManager deployment failed" );
        real_pool_manager  =  IPoolManager(abi.decode( ret, (address) ));

        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, POOL_MANAGER_KEY, address(real_pool_manager) );
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, INITIAL_COLLECTOR_KEY, collector );

        address hook_target  =  address(uint160(0x0AA0));
        deployCodeTo( "ReentrantProtectedContext.t.sol:ReentryPoolTestHook", hook_target );
        hook  =  ReentryPoolTestHook(payable(hook_target));

        malicious_token  =  new ReentrantERC20( );
        outer_paired_token  =  new MockERC20( "OuterPaired", "OPAIR", 18 );
        attack_token_a      =  new MockERC20( "AttackA", "ATKA", 18 );
        attack_token_b      =  new MockERC20( "AttackB", "ATKB", 18 );

        Currency outer_currency0  =  address(malicious_token) < address(outer_paired_token)
            ? Currency.wrap( address(malicious_token) )
            : Currency.wrap( address(outer_paired_token) );
        Currency outer_currency1  =  address(malicious_token) < address(outer_paired_token)
            ? Currency.wrap( address(outer_paired_token) )
            : Currency.wrap( address(malicious_token) );

        outer_pool_key  =  PoolKey({
            currency0: outer_currency0,
            currency1: outer_currency1,
            fee: POOL_FEE_030,
            tickSpacing: TICK_SPACING_60,
            hooks: IHooks(address(hook))
        });

        outer_input_token  =  MockERC20(address(malicious_token) == Currency.unwrap( outer_pool_key.currency0 )
            ? Currency.unwrap( outer_pool_key.currency1 )
            : Currency.unwrap( outer_pool_key.currency0 ));

        Currency attack_currency0  =  address(attack_token_a) < address(attack_token_b)
            ? Currency.wrap( address(attack_token_a) )
            : Currency.wrap( address(attack_token_b) );
        Currency attack_currency1  =  address(attack_token_a) < address(attack_token_b)
            ? Currency.wrap( address(attack_token_b) )
            : Currency.wrap( address(attack_token_a) );

        attack_pool_key  =  PoolKey({
            currency0: attack_currency0,
            currency1: attack_currency1,
            fee: POOL_FEE_030,
            tickSpacing: TICK_SPACING_60,
            hooks: IHooks(address(hook))
        });

        attack_output_token  =  MockERC20(Currency.unwrap( attack_pool_key.currency1 ));

        real_pool_manager.initialize( outer_pool_key, SQRT_PRICE_1_1 );
        real_pool_manager.initialize( attack_pool_key, SQRT_PRICE_1_1 );

        malicious_token.configure_attack( real_pool_manager, attack_pool_key );

        malicious_token.mint( user, INITIAL_BALANCE );
        malicious_token.mint( lp, INITIAL_BALANCE );
        malicious_token.mint( address(malicious_token), 10 ether );

        outer_paired_token.mint( user, INITIAL_BALANCE );
        outer_paired_token.mint( lp, INITIAL_BALANCE );

        attack_token_a.mint( lp, INITIAL_BALANCE );
        attack_token_b.mint( lp, INITIAL_BALANCE );
        attack_token_a.mint( address(malicious_token), 10 ether );
        attack_token_b.mint( address(malicious_token), 10 ether );

        vm.startPrank( user );
        malicious_token.approve( BONDROUTE_ADDRESS, type(uint256).max );
        outer_paired_token.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );

        vm.startPrank( lp );
        malicious_token.approve( BONDROUTE_ADDRESS, type(uint256).max );
        outer_paired_token.approve( BONDROUTE_ADDRESS, type(uint256).max );
        attack_token_a.approve( BONDROUTE_ADDRESS, type(uint256).max );
        attack_token_b.approve( BONDROUTE_ADDRESS, type(uint256).max );
        vm.stopPrank( );

        _seed_pool( outer_pool_key );
        _seed_pool( attack_pool_key );
    }

    function test_reentrant_output_token_transfer_reverts_when_direct_swap_has_no_bondroute_context( ) external
    {
        malicious_token.set_attack_enabled( true );

        ExactInputSwapParams memory params  =  ExactInputSwapParams({
            token_out: malicious_token,
            minimum_output_amount: 0,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });
        BondContext memory context  =  _create_swap_context( user, 1 ether );

        vm.expectRevert( );
        hook.harness_swap_exact_input( context, params );

        assertFalse( malicious_token.direct_swap_succeeded( ), "Reentrant direct PoolManager swap must not pass hook gating." );
    }

    function _seed_pool( PoolKey memory key ) private
    {
        malicious_token.set_attack_enabled( false );

        AddLiquidityParams memory params  =  AddLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: FULL_RANGE_LOWER,
            tick_upper: FULL_RANGE_UPPER,
            minimum_added_a: TokenAmount({ token: IERC20(Currency.unwrap( key.currency0 )), amount: 0 }),
            minimum_added_b: TokenAmount({ token: IERC20(Currency.unwrap( key.currency1 )), amount: 0 })
        });

        hook.harness_add_liquidity( _create_liquidity_context( key, lp, SEED_AMOUNT, SEED_AMOUNT ), params );
    }

    function _create_donate_params( ) private view returns ( DonateParams memory )
    {
        return DonateParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });
    }

    function _create_donate_context( address account, uint256 amount0, uint256 amount1 ) private view returns ( BondContext memory )
    {
        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[ 0 ]  =  TokenAmount({ token: IERC20(Currency.unwrap( outer_pool_key.currency0 )), amount: amount0 });
        fundings[ 1 ]  =  TokenAmount({ token: IERC20(Currency.unwrap( outer_pool_key.currency1 )), amount: amount1 });

        return BondContext({
            user: account,
            stake: TokenAmount({ token: IERC20(Currency.unwrap( outer_pool_key.currency0 )), amount: 0 }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });
    }

    function _create_swap_context( address account, uint256 amount_in ) private view returns ( BondContext memory )
    {
        TokenAmount[] memory fundings  =  new TokenAmount[](1);
        fundings[ 0 ]  =  TokenAmount({ token: outer_input_token, amount: amount_in });

        return BondContext({
            user: account,
            stake: TokenAmount({ token: outer_input_token, amount: amount_in / 100 }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });
    }

    function _create_liquidity_context( PoolKey memory key, address account, uint256 amount0, uint256 amount1 ) private view returns ( BondContext memory )
    {
        TokenAmount[] memory fundings  =  new TokenAmount[](2);
        fundings[ 0 ]  =  TokenAmount({ token: IERC20(Currency.unwrap( key.currency0 )), amount: amount0 });
        fundings[ 1 ]  =  TokenAmount({ token: IERC20(Currency.unwrap( key.currency1 )), amount: amount1 });

        return BondContext({
            user: account,
            stake: TokenAmount({ token: IERC20(Currency.unwrap( key.currency0 )), amount: amount0 / 100 }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });
    }
}

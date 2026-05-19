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
import { CHAINCONFIG_ADDRESS } from "@SafeSwap/integrations/IChainConfig.sol";
import { CONFIG_SIGNER, POOL_MANAGER_KEY, INITIAL_COLLECTOR_KEY } from "@SafeSwap/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta, toBalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { Constants } from "@UniswapV4Core/../test/utils/Constants.sol";


// ━━━━  MOCK ERC20  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping( address => uint256 ) public balanceOf;
    mapping( address => mapping( address => uint256 ) ) public allowance;

    constructor( string memory _name, string memory _symbol, uint8 _decimals )
    {
        name      =  _name;
        symbol    =  _symbol;
        decimals  =  _decimals;
    }

    function mint( address to, uint256 amount ) external
    {
        balanceOf[ to ]  =  balanceOf[ to ] + amount;
        totalSupply      =  totalSupply + amount;
        emit Transfer( address(0), to, amount );
    }

    function burn( address from, uint256 amount ) external
    {
        balanceOf[ from ]  =  balanceOf[ from ] - amount;
        totalSupply        =  totalSupply - amount;
        emit Transfer( from, address(0), amount );
    }

    function approve( address spender, uint256 value ) external returns ( bool )
    {
        allowance[ msg.sender ][ spender ]  =  value;
        emit Approval( msg.sender, spender, value );
        return true;
    }

    function transfer( address to, uint256 value ) external virtual returns ( bool )
    {
        balanceOf[ msg.sender ]  =  balanceOf[ msg.sender ] - value;
        balanceOf[ to ]          =  balanceOf[ to ] + value;
        emit Transfer( msg.sender, to, value );
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
        return true;
    }
}


// ━━━━  MOCK CHAIN CONFIG  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockChainConfig {
    mapping( address => mapping( bytes32 => address ) ) public addresses;

    function set_address( address signer, bytes32 key, address value ) external
    {
        addresses[ signer ][ key ]  =  value;
    }

    function read_address( address signer, bytes32 key ) external view returns ( address )
    {
        return addresses[ signer ][ key ];
    }

    function read_address( address signer, string calldata key ) external view returns ( address )
    {
        return addresses[ signer ][ bytes32(bytes(key)) ];
    }
}


// ━━━━  MOCK POOL MANAGER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    address public protocolFeeController;

    int128 public mock_swap_amount0;
    int128 public mock_swap_amount1;
    int128 public mock_liquidity_amount0;
    int128 public mock_liquidity_amount1;
    int128 public mock_donate_amount0;
    int128 public mock_donate_amount1;

    bytes32 public last_modify_salt;

    event SwapExecuted( PoolId indexed pool_id, bool zero_for_one, int256 amount_specified );
    event LiquidityModified( PoolId indexed pool_id, int256 liquidity_delta );
    event UnlockCalled( address caller, bytes data );

    function set_mock_swap_amounts( int128 amount0, int128 amount1 ) external
    {
        mock_swap_amount0  =  amount0;
        mock_swap_amount1  =  amount1;
    }

    function set_mock_liquidity_amounts( int128 amount0, int128 amount1 ) external
    {
        mock_liquidity_amount0  =  amount0;
        mock_liquidity_amount1  =  amount1;
    }

    function set_mock_donate_amounts( int128 amount0, int128 amount1 ) external
    {
        mock_donate_amount0  =  amount0;
        mock_donate_amount1  =  amount1;
    }

    function unlock( bytes calldata data ) external returns ( bytes memory )
    {
        emit UnlockCalled( msg.sender, data );
        return IUnlockCallback(msg.sender).unlockCallback( data );
    }

    function swap( PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata )
    external returns ( BalanceDelta delta )
    {
        PoolId pool_id  =  key.toId( );
        emit SwapExecuted( pool_id, params.zeroForOne, params.amountSpecified );
        return toBalanceDelta( mock_swap_amount0, mock_swap_amount1 );
    }

    function modifyLiquidity( PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, bytes calldata )
    external returns ( BalanceDelta delta, BalanceDelta fees_accrued )
    {
        PoolId pool_id  =  key.toId( );
        last_modify_salt  =  params.salt;
        emit LiquidityModified( pool_id, params.liquidityDelta );
        return ( toBalanceDelta( mock_liquidity_amount0, mock_liquidity_amount1 ), toBalanceDelta( 0, 0 ) );
    }

    function donate( PoolKey memory, uint256, uint256, bytes calldata )
    external returns ( BalanceDelta delta )
    {
        return toBalanceDelta( mock_donate_amount0, mock_donate_amount1 );
    }

    function sync( Currency ) external { }

    function settle( ) external payable returns ( uint256 )
    {
        return 0;
    }

    function take( Currency currency, address to, uint256 amount ) external
    {
        address token  =  Currency.unwrap( currency );
        if(  token == address(0)  )
        {
            payable(to).transfer( amount );
        }
        else
        {
            bool success  =  MockERC20(token).transfer( to, amount );
            require( success, "Mock transfer failed" );
        }
    }

    function extsload( bytes32 ) external pure returns ( bytes32 )
    {
        // V4 slot0 packs sqrtPriceX96 in the low 160 bits;
        // returning a 1:1 price keeps stake math from div-by-zero.
        return bytes32(uint256(Constants.SQRT_PRICE_1_1));
    }

    function extsload( bytes32[] calldata slots ) external view returns ( bytes32[] memory )
    {
        return new bytes32[]( slots.length );
    }

    function supportsInterface( bytes4 interface_id ) external pure returns ( bool )
    {
        return interface_id == 0x01ffc9a7 || interface_id == 0x0f632fb3;
    }

    receive( ) external payable { }
}


// ━━━━  MOCK BONDROUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockBondRoute {
    event ProtocolAnnounced( string name, string description );

    bool public skip_actual_transfer;

    function announce_protocol( string calldata name, string calldata description ) external payable
    {
        emit ProtocolAnnounced( name, description );
    }

    function set_skip_actual_transfer( bool skip ) external
    {
        skip_actual_transfer  =  skip;
    }

    function transfer_funding( address to, IERC20 token, uint256 amount, BondContext memory context )
    external returns ( uint256 updated_index, uint256 new_available_amount )
    {
        // Find the funding index for this token.
        for(  uint i = 0  ;  i < context.fundings.length  ;  i = i + 1  )
        {
            if(  address(context.fundings[ i ].token) == address(token)  )
            {
                uint256 available  =  context.fundings[ i ].amount;
                require( available >= amount, "Insufficient funding" );

                // Skip actual transfer in test mode - just track the accounting.
                if(  skip_actual_transfer == false  )
                {
                    if(  address(token) == address(0)  )
                    {
                        payable(to).transfer( amount );
                    }
                    else
                    {
                        bool success  =  token.transferFrom( context.user, to, amount );
                        require( success, "Mock funding transfer failed" );
                    }
                }

                return ( i, available - amount );
            }
        }
        revert( "Token not in fundings" );
    }

    receive( ) external payable { }
}


// ━━━━  FAILING ERC20 (for testing transfer failures)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract FailingERC20 is MockERC20 {
    bool public should_fail_transfer;

    constructor( ) MockERC20( "Failing", "FAIL", 18 ) { }

    function set_should_fail( bool _should_fail ) external
    {
        should_fail_transfer  =  _should_fail;
    }

    function transfer( address to, uint256 value ) external override returns ( bool )
    {
        if(  should_fail_transfer  )  return false;
        balanceOf[ msg.sender ]  =  balanceOf[ msg.sender ] - value;
        balanceOf[ to ]          =  balanceOf[ to ] + value;
        emit Transfer( msg.sender, to, value );
        return true;
    }
}


// ━━━━  REJECTING RECIPIENT (for testing native transfer failures)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract RejectingRecipient {
    receive( ) external payable
    {
        revert( "I reject ETH" );
    }
}


// ━━━━  TESTABLE SAFESWAPHOOK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// @dev Wrapper that exposes internal SafeSwap hooks for direct testing without going through BondRoute.
contract TestableSafeSwap is SafeSwap {

    constructor( ) SafeSwap( ) { }

    function harness_allow_hook_callback( ) external
    {
        _is_hook_callback_allowed  =  true;
    }

    function harness_revoke_hook_callback_permission( ) external
    {
        _is_hook_callback_allowed  =  false;
    }

    function harness_hook_callback_allowed( ) external view returns ( bool )
    {
        return _is_hook_callback_allowed;
    }

    function harness_execute_exact_input_swap( BondContext memory context, ExactInputSwapParams memory params ) external
    {
        _is_hook_callback_allowed  =  true;
        ExactInputSwapLib.execute( context, params, PoolManager, address(this) );
        _is_hook_callback_allowed  =  false;
    }

    function harness_execute_exact_output_swap( BondContext memory context, ExactOutputSwapParams memory params ) external
    {
        _is_hook_callback_allowed  =  true;
        ExactOutputSwapLib.execute( context, params, PoolManager, address(this) );
        _is_hook_callback_allowed  =  false;
    }

    function harness_execute_add_liquidity( BondContext memory context, AddLiquidityParams memory params ) external
    {
        _is_hook_callback_allowed  =  true;
        AddLiquidityLib.execute( context, params, PoolManager, address(this) );
        _is_hook_callback_allowed  =  false;
    }

    function harness_execute_remove_liquidity( BondContext memory context, RemoveLiquidityParams memory params ) external
    {
        _is_hook_callback_allowed  =  true;
        RemoveLiquidityLib.execute( context, params, PoolManager, address(this) );
        _is_hook_callback_allowed  =  false;
    }

    function harness_execute_donate( BondContext memory context, DonateParams memory params ) external
    {
        _is_hook_callback_allowed  =  true;
        DonateLib.execute( context, params, PoolManager, address(this) );
        _is_hook_callback_allowed  =  false;
    }

    function harness_build_pool_key( IERC20 token_in, IERC20 token_out, uint24 fee, int24 tick_spacing )
    external view returns ( PoolKey memory )
    {
        return SafeSwapCommon.build_pool_key( token_in, token_out, fee, tick_spacing, address(this) );
    }

    function harness_calculate_swap_stake( TokenAmount memory funding )
    external pure returns ( TokenAmount memory )
    {
        return SafeSwapCommon.calculate_swap_stake( funding );
    }
}


// ━━━━  TEST BASE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

abstract contract SafeSwapTestBase is Test {

    // Contracts.
    TestableSafeSwap public hook;
    MockPoolManager public pool_manager;
    MockBondRoute public bond_route;
    MockChainConfig public chain_config;

    // Tokens.
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public token2;
    FailingERC20 public failing_token;

    // Addresses.
    address public collector;
    address public user;
    address public other_user;
    address public treasury;

    // Constants.
    uint24 constant POOL_FEE_030       =  3000;    // 0.30%.
    uint24 constant POOL_FEE_005       =  500;     // 0.05%.
    uint24 constant POOL_FEE_001       =  100;     // 0.01%.
    uint24 constant POOL_FEE_100       =  10000;   // 1.00%.
    int24 constant TICK_SPACING_60     =  60;
    int24 constant TICK_SPACING_10     =  10;
    uint160 constant SQRT_PRICE_1_1    =  Constants.SQRT_PRICE_1_1;
    uint256 constant INITIAL_BALANCE   =  1_000_000 ether;

    address constant HOOK_TARGET          =  address(uint160(0x0AA0));

    function setUp( ) public virtual
    {
        // Set block number and timestamp to sensible values.
        vm.roll( 1000 );
        vm.warp( 1000000 );

        // Create addresses.
        collector   =  makeAddr( "collector" );
        user        =  makeAddr( "user" );
        other_user  =  makeAddr( "other_user" );
        treasury    =  makeAddr( "treasury" );

        // Deploy mocks.
        chain_config   =  new MockChainConfig( );
        pool_manager   =  new MockPoolManager( );
        bond_route     =  new MockBondRoute( );

        // Deploy mock code at expected addresses.
        vm.etch( CHAINCONFIG_ADDRESS, address(chain_config).code );
        vm.etch( BONDROUTE_ADDRESS, address(bond_route).code );

        // Set deployment config in ChainConfig under the hardcoded CONFIG_SIGNER keyspace.
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, POOL_MANAGER_KEY, address(pool_manager) );
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, INITIAL_COLLECTOR_KEY, collector );

        // Set skip_actual_transfer to true on the etched BondRoute.
        MockBondRoute(payable(BONDROUTE_ADDRESS)).set_skip_actual_transfer( true );

        // Deploy tokens - ensure token0 < token1 for proper ordering.
        token0         =  new MockERC20( "Token0", "TK0", 18 );
        token1         =  new MockERC20( "Token1", "TK1", 18 );
        token2         =  new MockERC20( "Token2", "TK2", 18 );
        failing_token  =  new FailingERC20( );

        // Ensure token0 < token1.
        if(  address(token0) > address(token1)  )
        {
            ( token0, token1 )  =  ( token1, token0 );
        }

        // Deploy hook at the address carrying SafeSwap's Uniswap V4 permission flags.
        deployCodeTo( "TestBase.t.sol:TestableSafeSwap", HOOK_TARGET );
        hook  =  TestableSafeSwap(payable(HOOK_TARGET));

        // Mint tokens to users.
        token0.mint( user, INITIAL_BALANCE );
        token1.mint( user, INITIAL_BALANCE );
        token0.mint( other_user, INITIAL_BALANCE );
        token1.mint( other_user, INITIAL_BALANCE );
        token0.mint( address(pool_manager), INITIAL_BALANCE );
        token1.mint( address(pool_manager), INITIAL_BALANCE );

        // Mint dust to addresses that start at 0 to avoid 0→nonzero SSTORE costs.
        token0.mint( address(hook), 1 );
        token1.mint( address(hook), 1 );
        token0.mint( treasury, 1 );
        token1.mint( treasury, 1 );

        // Approve hook to spend tokens.
        vm.startPrank( user );
        token0.approve( address(hook), type(uint256).max );
        token1.approve( address(hook), type(uint256).max );
        token0.approve( address(bond_route), type(uint256).max );
        token1.approve( address(bond_route), type(uint256).max );
        vm.stopPrank( );
    }

    function _create_bond_context( address _user, uint256 amount ) internal view returns ( BondContext memory )
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

    function _create_bond_context_two_fundings( address _user, uint256 amount0, uint256 amount1 )
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

    function _create_exact_input_params( uint256 min_out )
    internal view returns ( ExactInputSwapParams memory )
    {
        return ExactInputSwapParams({
            token_out: token1,
            minimum_amount_out: min_out,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });
    }

    function _create_exact_output_params( uint256 amount_out )
    internal view returns ( ExactOutputSwapParams memory )
    {
        return ExactOutputSwapParams({
            token_out: token1,
            amount_out: amount_out,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });
    }

    function _create_add_liquidity_params( )
    internal view returns ( AddLiquidityParams memory )
    {
        return AddLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            min_a: TokenAmount({ token: token0, amount: 0 }),
            min_b: TokenAmount({ token: token1, amount: 0 })
        });
    }

    function _create_remove_liquidity_params( uint128 liquidity )
    internal view returns ( RemoveLiquidityParams memory )
    {
        return RemoveLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            liquidity: liquidity,
            min_a: TokenAmount({ token: token0, amount: 0 }),
            min_b: TokenAmount({ token: token1, amount: 0 })
        });
    }

    function _create_donate_params( )
    internal view returns ( DonateParams memory )
    {
        return DonateParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });
    }

    function _create_swap_fundings( uint256 amount_in )
    internal view returns ( TokenAmount[] memory fundings )
    {
        fundings       =  new TokenAmount[](1);
        fundings[ 0 ]  =  TokenAmount({ token: token0, amount: amount_in });
    }

    function _create_liquidity_fundings( uint256 amount0, uint256 amount1 )
    internal view returns ( TokenAmount[] memory fundings )
    {
        fundings       =  new TokenAmount[](2);
        fundings[ 0 ]  =  TokenAmount({ token: token0, amount: amount0 });
        fundings[ 1 ]  =  TokenAmount({ token: token1, amount: amount1 });
    }

    function _default_pool_info( )
    internal pure returns ( PoolInfo memory )
    {
        return PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 });
    }

    function _encode_exact_input_calldata( ExactInputSwapParams memory params )
    internal view returns ( bytes memory )
    {
        return abi.encodeWithSelector( hook.swap_exact_input.selector, params );
    }

    function _encode_exact_output_calldata( ExactOutputSwapParams memory params )
    internal view returns ( bytes memory )
    {
        return abi.encodeWithSelector( hook.swap_exact_output.selector, params );
    }

    function _encode_add_liquidity_calldata( AddLiquidityParams memory params )
    internal view returns ( bytes memory )
    {
        return abi.encodeWithSelector( hook.add_liquidity.selector, params );
    }

    function _encode_remove_liquidity_calldata( RemoveLiquidityParams memory params )
    internal view returns ( bytes memory )
    {
        return abi.encodeWithSelector( hook.remove_liquidity.selector, params );
    }

    function _encode_donate_calldata( DonateParams memory params )
    internal view returns ( bytes memory )
    {
        return abi.encodeWithSelector( hook.donate.selector, params );
    }
}
